-- =====================================================================
-- Concurrency-safe booking flow (supports P1's locking requirements)
--   sp_hold_seats              - all-or-nothing timed hold on N seats
--   sp_process_payment_webhook - idempotent webhook handler
--   sp_expire_holds            - background cleanup of expired holds
-- Run with the mysql CLI or MySQL Workbench (uses DELIMITER).
-- =====================================================================

USE booking_engine;

DROP PROCEDURE IF EXISTS sp_hold_seats;
DROP PROCEDURE IF EXISTS sp_process_payment_webhook;
DROP PROCEDURE IF EXISTS sp_expire_holds;
DROP EVENT IF EXISTS ev_expire_holds;

DELIMITER $$

-- ---------------------------------------------------------------------
-- Hold seats for a user. A seat is claimable when nobody owns it, or its
-- owner booking is dead (EXPIRED/CANCELLED/FAILED), or its owner is a
-- PENDING hold whose timer has run out. Expiry is therefore enforced at
-- claim time and never depends on the cleanup job having run.
-- ---------------------------------------------------------------------
CREATE PROCEDURE sp_hold_seats(
    IN  p_user_id         BIGINT UNSIGNED,
    IN  p_show_id         BIGINT UNSIGNED,
    IN  p_seat_ids        JSON,           -- e.g. '[12, 13]'
    IN  p_idempotency_key CHAR(36),
    IN  p_hold_seconds    INT,            -- typically 600 (10 minutes)
    OUT p_booking_id      BIGINT UNSIGNED,
    OUT p_result          VARCHAR(30)
)
proc: BEGIN
    DECLARE v_requested INT;
    DECLARE v_claimed   INT;
    DECLARE v_valid     INT;

    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        RESIGNAL;
    END;

    SET p_booking_id = NULL;

    -- Client retry with the same idempotency key: return the original booking.
    SELECT booking_id INTO p_booking_id
    FROM booking
    WHERE user_id = p_user_id AND idempotency_key = p_idempotency_key;
    IF p_booking_id IS NOT NULL THEN
        SET p_result = 'DUPLICATE_REQUEST';
        LEAVE proc;
    END IF;

    SELECT COUNT(DISTINCT j.seat_id) INTO v_requested
    FROM JSON_TABLE(p_seat_ids, '$[*]' COLUMNS (seat_id INT UNSIGNED PATH '$')) j;

    IF v_requested = 0 OR v_requested <> JSON_LENGTH(p_seat_ids) THEN
        SET p_result = 'INVALID_SEATS';
        LEAVE proc;
    END IF;

    START TRANSACTION;

    -- Show must be bookable, and every seat must belong to it.
    SELECT COUNT(*) INTO v_valid
    FROM movie_show ms
    JOIN show_seat ss ON ss.show_id = ms.show_id
    JOIN JSON_TABLE(p_seat_ids, '$[*]' COLUMNS (seat_id INT UNSIGNED PATH '$')) j
         ON j.seat_id = ss.seat_id
    WHERE ms.show_id = p_show_id
      AND ms.status = 'SCHEDULED'
      AND ms.start_time > NOW();

    IF v_valid <> v_requested THEN
        ROLLBACK;
        SET p_result = 'INVALID_SEATS';
        LEAVE proc;
    END IF;

    INSERT INTO booking (user_id, show_id, status, hold_expires_at, idempotency_key)
    VALUES (p_user_id, p_show_id, 'PENDING', NOW() + INTERVAL p_hold_seconds SECOND, p_idempotency_key);
    SET p_booking_id = LAST_INSERT_ID();

    -- Pessimistic lock on the requested inventory rows, always in seat_id
    -- order so two overlapping requests cannot deadlock each other.
    SELECT COUNT(*) INTO v_valid FROM (
        SELECT ss.seat_id
        FROM show_seat ss
        JOIN JSON_TABLE(p_seat_ids, '$[*]' COLUMNS (seat_id INT UNSIGNED PATH '$')) j
             ON j.seat_id = ss.seat_id
        WHERE ss.show_id = p_show_id
        ORDER BY ss.seat_id
        FOR UPDATE OF ss
    ) locked;

    -- Claim only the seats that are actually free right now.
    UPDATE show_seat ss
    JOIN JSON_TABLE(p_seat_ids, '$[*]' COLUMNS (seat_id INT UNSIGNED PATH '$')) j
         ON j.seat_id = ss.seat_id
    LEFT JOIN booking b ON b.booking_id = ss.booking_id
    SET ss.booking_id = p_booking_id,
        ss.version    = ss.version + 1
    WHERE ss.show_id = p_show_id
      AND (   ss.booking_id IS NULL
           OR b.status IN ('EXPIRED', 'CANCELLED', 'FAILED')
           OR (b.status = 'PENDING' AND b.hold_expires_at <= NOW()));
    SET v_claimed = ROW_COUNT();

    -- All-or-nothing: if any seat was taken, undo everything.
    IF v_claimed <> v_requested THEN
        ROLLBACK;
        SET p_booking_id = NULL;
        SET p_result = 'SEATS_UNAVAILABLE';
        LEAVE proc;
    END IF;

    INSERT INTO booking_seat (booking_id, seat_id, price_paid)
    SELECT p_booking_id, s.seat_id, sp.price
    FROM JSON_TABLE(p_seat_ids, '$[*]' COLUMNS (seat_id INT UNSIGNED PATH '$')) j
    JOIN seat s        ON s.seat_id = j.seat_id
    JOIN show_price sp ON sp.show_id = p_show_id AND sp.category_id = s.category_id;

    COMMIT;
    SET p_result = 'HELD';
END proc$$

-- ---------------------------------------------------------------------
-- Payment webhook. Safe to call any number of times for the same event:
--   * UNIQUE (gateway, gateway_event_id) rejects repeat deliveries;
--   * the payment row is locked FOR UPDATE, serialising concurrent
--     deliveries for the same payment;
--   * state transitions only happen from INITIATED / PENDING.
-- The booking is confirmed only if it still owns every one of its seats.
-- A late payment whose seats were already re-sold is marked for refund.
-- ---------------------------------------------------------------------
CREATE PROCEDURE sp_process_payment_webhook(
    IN  p_gateway          VARCHAR(30),
    IN  p_gateway_event_id VARCHAR(100),
    IN  p_gateway_order_id VARCHAR(100),
    IN  p_event_type       VARCHAR(50),
    IN  p_payload          JSON,
    OUT p_result           VARCHAR(30)
)
proc: BEGIN
    DECLARE v_payment_id     BIGINT UNSIGNED;
    DECLARE v_booking_id     BIGINT UNSIGNED;
    DECLARE v_payment_status VARCHAR(20);
    DECLARE v_booking_status VARCHAR(20);
    DECLARE v_total_seats    INT;
    DECLARE v_owned_seats    INT;
    DECLARE v_show_id        BIGINT UNSIGNED;
    DECLARE v_duplicate      TINYINT DEFAULT 0;

    DECLARE CONTINUE HANDLER FOR 1062 SET v_duplicate = 1;
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        RESIGNAL;
    END;

    START TRANSACTION;

    SELECT payment_id, booking_id, status
      INTO v_payment_id, v_booking_id, v_payment_status
    FROM payment
    WHERE gateway = p_gateway AND gateway_order_id = p_gateway_order_id
    FOR UPDATE;

    IF v_payment_id IS NULL THEN
        ROLLBACK;
        SET p_result = 'UNKNOWN_PAYMENT';
        LEAVE proc;
    END IF;

    INSERT INTO payment_webhook_event (gateway, gateway_event_id, payment_id, event_type, payload)
    VALUES (p_gateway, p_gateway_event_id, v_payment_id, p_event_type, p_payload);

    IF v_duplicate = 1 THEN
        ROLLBACK;
        SET p_result = 'DUPLICATE_EVENT';
        LEAVE proc;
    END IF;

    IF v_payment_status <> 'INITIATED' THEN
        -- Different event id but payment already settled (e.g. a late
        -- payment.failed after payment.captured). Record, don't act.
        UPDATE payment_webhook_event SET processed_at = NOW()
        WHERE gateway = p_gateway AND gateway_event_id = p_gateway_event_id;
        COMMIT;
        SET p_result = 'ALREADY_SETTLED';
        LEAVE proc;
    END IF;

    -- Lock order everywhere is show_seat rows (by seat_id) before booking
    -- rows, matching sp_hold_seats, so the two can never deadlock.
    SELECT show_id INTO v_show_id FROM booking WHERE booking_id = v_booking_id;

    SELECT COUNT(*), SUM(ss.booking_id <=> v_booking_id)
      INTO v_total_seats, v_owned_seats
    FROM (
        SELECT ss.booking_id
        FROM booking_seat bs
        JOIN show_seat ss ON ss.show_id = v_show_id AND ss.seat_id = bs.seat_id
        WHERE bs.booking_id = v_booking_id
        ORDER BY ss.seat_id
        FOR UPDATE OF ss
    ) ss;

    SELECT status INTO v_booking_status
    FROM booking WHERE booking_id = v_booking_id
    FOR UPDATE;

    IF p_event_type = 'payment.captured' THEN
        IF v_booking_status = 'PENDING' AND v_total_seats > 0 AND v_owned_seats = v_total_seats THEN
            UPDATE booking SET status = 'CONFIRMED' WHERE booking_id = v_booking_id;
            UPDATE payment SET status = 'SUCCESS'   WHERE payment_id = v_payment_id;
            SET p_result = 'CONFIRMED';
        ELSE
            UPDATE booking   SET status = 'FAILED'  WHERE booking_id = v_booking_id AND status = 'PENDING';
            UPDATE show_seat SET booking_id = NULL, version = version + 1
            WHERE show_id = v_show_id AND booking_id = v_booking_id;
            UPDATE payment SET status = 'REFUND_PENDING' WHERE payment_id = v_payment_id;
            SET p_result = 'REFUND_REQUIRED';
        END IF;
    ELSEIF p_event_type = 'payment.failed' THEN
        UPDATE booking   SET status = 'FAILED' WHERE booking_id = v_booking_id AND status = 'PENDING';
        UPDATE show_seat SET booking_id = NULL, version = version + 1
        WHERE show_id = v_show_id AND booking_id = v_booking_id;
        UPDATE payment SET status = 'FAILED' WHERE payment_id = v_payment_id;
        SET p_result = 'PAYMENT_FAILED';
    ELSE
        SET p_result = 'IGNORED_EVENT_TYPE';
    END IF;

    UPDATE payment_webhook_event SET processed_at = NOW()
    WHERE gateway = p_gateway AND gateway_event_id = p_gateway_event_id;

    COMMIT;
END proc$$

-- ---------------------------------------------------------------------
-- Housekeeping: mark expired holds and detach them from inventory in
-- small batches (keeps lock time short). Correctness does not depend on
-- this running - sp_hold_seats already treats expired holds as free.
-- Skips holds whose payment is still INITIATED within a grace window,
-- so an in-flight payment is not raced by the sweeper.
-- ---------------------------------------------------------------------
CREATE PROCEDURE sp_expire_holds(IN p_batch_size INT, OUT p_expired INT)
BEGIN
    DECLARE v_locked INT;

    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        RESIGNAL;
    END;

    DROP TEMPORARY TABLE IF EXISTS tmp_expired;
    CREATE TEMPORARY TABLE tmp_expired (booking_id BIGINT UNSIGNED PRIMARY KEY);

    -- READ COMMITTED: candidate selection takes no locks on booking, so
    -- seats can be locked before bookings (same order as sp_hold_seats).
    SET TRANSACTION ISOLATION LEVEL READ COMMITTED;
    START TRANSACTION;

    INSERT INTO tmp_expired (booking_id)
    SELECT b.booking_id
    FROM booking b
    WHERE b.status = 'PENDING'
      AND b.hold_expires_at <= NOW()
      AND NOT EXISTS (
          SELECT 1 FROM payment p
          WHERE p.booking_id = b.booking_id
            AND p.status = 'INITIATED'
            AND b.hold_expires_at > NOW() - INTERVAL 5 MINUTE
      )
    ORDER BY b.hold_expires_at
    LIMIT p_batch_size;

    SELECT COUNT(*) INTO v_locked FROM (
        SELECT ss.seat_id
        FROM show_seat ss
        JOIN tmp_expired t ON t.booking_id = ss.booking_id
        ORDER BY ss.show_id, ss.seat_id
        FOR UPDATE OF ss
    ) locked;

    -- Re-check: a webhook may have confirmed the booking meanwhile.
    UPDATE booking b JOIN tmp_expired t ON t.booking_id = b.booking_id
    SET b.status = 'EXPIRED'
    WHERE b.status = 'PENDING' AND b.hold_expires_at <= NOW();
    SET p_expired = ROW_COUNT();

    UPDATE show_seat ss
    JOIN tmp_expired t ON t.booking_id = ss.booking_id
    JOIN booking b     ON b.booking_id = ss.booking_id
    SET ss.booking_id = NULL, ss.version = ss.version + 1
    WHERE b.status = 'EXPIRED';

    COMMIT;
    DROP TEMPORARY TABLE IF EXISTS tmp_expired;
END$$

DELIMITER ;

-- Runs every 30s if event_scheduler=ON (default in MySQL 8).
CREATE EVENT ev_expire_holds
    ON SCHEDULE EVERY 30 SECOND
    DO CALL sp_expire_holds(1000, @ev_expired);


-- =====================================================================
-- Demo against the sample data (today's 09:30 show at PVR Orion, Audi 1)
-- =====================================================================
SET @show_id := (SELECT show_id FROM movie_show
                 WHERE screen_id = 1 AND start_time = TIMESTAMP(CURDATE(), '09:30:00'));
-- If it's already past 09:30 today, use tomorrow's 09:30 show instead
-- (sp_hold_seats refuses shows that have started).
SET @show_id := IF((SELECT start_time FROM movie_show WHERE show_id = @show_id) > NOW(), @show_id,
                   (SELECT show_id FROM movie_show
                    WHERE screen_id = 1 AND start_time = TIMESTAMP(CURDATE() + INTERVAL 1 DAY, '09:30:00')));

SET @a1 := (SELECT seat_id FROM seat WHERE screen_id = 1 AND row_label = 'A' AND seat_number = 1);
SET @a2 := (SELECT seat_id FROM seat WHERE screen_id = 1 AND row_label = 'A' AND seat_number = 2);
SET @b1 := (SELECT seat_id FROM seat WHERE screen_id = 1 AND row_label = 'B' AND seat_number = 1);

-- 1. User 1 holds A2 + B1 -> HELD
CALL sp_hold_seats(1, @show_id, JSON_ARRAY(@a2, @b1), '11111111-0000-4000-8000-000000000001', 600, @bk1, @r1);
-- 2. User 2 tries A2 (overlaps user 1's live hold) -> SEATS_UNAVAILABLE, nothing held
CALL sp_hold_seats(2, @show_id, JSON_ARRAY(@a1, @a2), '22222222-0000-4000-8000-000000000002', 600, @bk2, @r2);
-- 3. User 1 retries request #1 (network retry) -> DUPLICATE_REQUEST, same booking id
CALL sp_hold_seats(1, @show_id, JSON_ARRAY(@a2, @b1), '11111111-0000-4000-8000-000000000001', 600, @bk3, @r3);
SELECT @r1, @bk1, @r2, @bk2, @r3, @bk3;

-- 4. Payment for user 1's hold; gateway delivers the success webhook twice.
INSERT INTO payment (booking_id, gateway, gateway_order_id, amount)
SELECT @bk1, 'RAZORPAY', CONCAT('order_demo_', @bk1), SUM(price_paid)
FROM booking_seat WHERE booking_id = @bk1;

CALL sp_process_payment_webhook('RAZORPAY', CONCAT('evt_demo_', @bk1), CONCAT('order_demo_', @bk1),
                                'payment.captured', JSON_OBJECT('status', 'captured'), @w1);
CALL sp_process_payment_webhook('RAZORPAY', CONCAT('evt_demo_', @bk1), CONCAT('order_demo_', @bk1),
                                'payment.captured', JSON_OBJECT('status', 'captured'), @w2);
SELECT @w1 AS first_delivery, @w2 AS redelivery;   -- CONFIRMED, DUPLICATE_EVENT

-- 5. Run the sweeper manually.
CALL sp_expire_holds(1000, @expired);
SELECT @expired AS holds_expired;

-- Seat map for the show: AVAILABLE / HELD / BOOKED is derived, not stored.
SELECT s.row_label, s.seat_number, sc.name AS category,
       CASE
           WHEN b.status = 'CONFIRMED' THEN 'BOOKED'
           WHEN b.status = 'PENDING' AND b.hold_expires_at > NOW() THEN 'HELD'
           ELSE 'AVAILABLE'
       END AS seat_state
FROM show_seat ss
JOIN seat s           ON s.seat_id = ss.seat_id
JOIN seat_category sc ON sc.category_id = s.category_id
LEFT JOIN booking b   ON b.booking_id = ss.booking_id
WHERE ss.show_id = @show_id
ORDER BY s.row_label, s.seat_number;
