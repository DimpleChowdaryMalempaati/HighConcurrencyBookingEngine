-- =====================================================================
-- Sample data. Shows are generated for the next 7 days relative to
-- CURDATE(), so the P2 query returns rows whenever this script is run.
-- =====================================================================

USE booking_engine;

INSERT INTO city (city_id, name, state) VALUES
    (1, 'Bengaluru', 'Karnataka'),
    (2, 'Mumbai',    'Maharashtra');

INSERT INTO theatre (theatre_id, city_id, name, address, pincode) VALUES
    (1, 1, 'PVR Orion Mall',        'Dr Rajkumar Rd, Rajajinagar',   '560055'),
    (2, 1, 'INOX Garuda Mall',      'Magrath Rd, Ashok Nagar',       '560025'),
    (3, 2, 'Cinepolis Andheri West','Fun Republic Mall, Andheri W',  '400053');

INSERT INTO screen (screen_id, theatre_id, name) VALUES
    (1, 1, 'Audi 1'),
    (2, 1, 'Audi 2'),
    (3, 2, 'Screen 1'),
    (4, 3, 'Screen 1');

INSERT INTO seat_category (category_id, name) VALUES
    (1, 'SILVER'),
    (2, 'GOLD'),
    (3, 'RECLINER');

-- Small layout per screen: rows A-E, 10 seats each.
-- A-B = SILVER, C-D = GOLD, E = RECLINER.
INSERT INTO seat (screen_id, row_label, seat_number, category_id)
WITH RECURSIVE n AS (SELECT 1 AS num UNION ALL SELECT num + 1 FROM n WHERE num < 10),
rows_ AS (
    SELECT 'A' AS row_label, 1 AS category_id UNION ALL
    SELECT 'B', 1 UNION ALL
    SELECT 'C', 2 UNION ALL
    SELECT 'D', 2 UNION ALL
    SELECT 'E', 3
)
SELECT s.screen_id, r.row_label, n.num, r.category_id
FROM screen s CROSS JOIN rows_ r CROSS JOIN n
ORDER BY s.screen_id, r.row_label, n.num;

INSERT INTO movie (movie_id, title, duration_min, certification, release_date) VALUES
    (1, 'Kantara: Chapter 1', 168, 'UA13+', '2025-10-02'),
    (2, 'Dune: Part Two',     166, 'UA',    '2024-03-01'),
    (3, 'Inside Out 2',        96, 'U',     '2024-06-14'),
    (4, 'Oppenheimer',        180, 'UA16+', '2023-07-21');

INSERT INTO genre (genre_id, name) VALUES
    (1, 'Action'), (2, 'Drama'), (3, 'Sci-Fi'), (4, 'Animation'), (5, 'Thriller'), (6, 'History');

INSERT INTO movie_genre (movie_id, genre_id) VALUES
    (1, 1), (1, 5),
    (2, 1), (2, 3),
    (3, 4),
    (4, 2), (4, 6);

INSERT INTO language (language_id, name) VALUES
    (1, 'Kannada'), (2, 'Hindi'), (3, 'English'), (4, 'Tamil');

INSERT INTO show_format (format_id, name) VALUES
    (1, '2D'), (2, '3D'), (3, 'IMAX 2D');

-- Daily schedule template, expanded over the next 7 days.
-- (screen, movie, language, format, start time, slot length in minutes)
INSERT INTO movie_show (screen_id, movie_id, language_id, format_id, start_time, end_time)
WITH RECURSIVE d AS (SELECT 0 AS day_offset UNION ALL SELECT day_offset + 1 FROM d WHERE day_offset < 6),
tmpl AS (
    SELECT 1 AS screen_id, 1 AS movie_id, 1 AS language_id, 1 AS format_id, '09:30:00' AS t, 195 AS slot UNION ALL
    SELECT 1, 1, 1, 1, '13:15:00', 195 UNION ALL
    SELECT 1, 2, 3, 3, '17:00:00', 195 UNION ALL
    SELECT 1, 1, 1, 1, '21:00:00', 195 UNION ALL
    SELECT 2, 3, 3, 2, '10:00:00', 120 UNION ALL
    SELECT 2, 3, 3, 1, '12:30:00', 120 UNION ALL
    SELECT 2, 4, 3, 1, '15:00:00', 210 UNION ALL
    SELECT 2, 1, 2, 1, '19:00:00', 195 UNION ALL
    SELECT 2, 1, 2, 1, '22:30:00', 195 UNION ALL
    SELECT 3, 2, 3, 1, '11:00:00', 195 UNION ALL
    SELECT 3, 1, 1, 1, '15:00:00', 195 UNION ALL
    SELECT 4, 4, 2, 1, '12:00:00', 210 UNION ALL
    SELECT 4, 2, 2, 1, '18:30:00', 195
)
SELECT t.screen_id, t.movie_id, t.language_id, t.format_id,
       TIMESTAMP(CURDATE() + INTERVAL d.day_offset DAY, t.t),
       TIMESTAMP(CURDATE() + INTERVAL d.day_offset DAY, t.t) + INTERVAL t.slot MINUTE
FROM d CROSS JOIN tmpl t;

-- One cancelled show, to prove P2 filters it out.
UPDATE movie_show
SET status = 'CANCELLED'
WHERE screen_id = 2 AND start_time = TIMESTAMP(CURDATE(), '22:30:00');

INSERT INTO show_price (show_id, category_id, price)
SELECT ms.show_id, sc.category_id,
       CASE sc.name WHEN 'SILVER' THEN 180.00 WHEN 'GOLD' THEN 250.00 ELSE 450.00 END
       + CASE WHEN ms.format_id = 3 THEN 200.00 ELSE 0 END
FROM movie_show ms CROSS JOIN seat_category sc;

-- Seat inventory: one row per (show, seat) of that show's screen.
INSERT INTO show_seat (show_id, seat_id)
SELECT ms.show_id, s.seat_id
FROM movie_show ms
JOIN seat s ON s.screen_id = ms.screen_id;

INSERT INTO app_user (user_id, name, email, phone) VALUES
    (1, 'Aarav Sharma', 'aarav@example.com', '9876500001'),
    (2, 'Diya Patel',   'diya@example.com',  '9876500002'),
    (3, 'Rohan Iyer',   'rohan@example.com', '9876500003');

-- ---------------------------------------------------------------------
-- A confirmed booking (user 1, today's 09:30 show at PVR Orion, D5 + D6)
-- ---------------------------------------------------------------------
SET @show_id := (SELECT show_id FROM movie_show
                 WHERE screen_id = 1 AND start_time = TIMESTAMP(CURDATE(), '09:30:00'));

INSERT INTO booking (booking_id, user_id, show_id, status, hold_expires_at, idempotency_key)
VALUES (1, 1, @show_id, 'CONFIRMED', NOW() + INTERVAL 10 MINUTE, '6f1c2b7e-0d3a-4f55-9a61-2d7c1e9b0a01');

INSERT INTO booking_seat (booking_id, seat_id, price_paid)
SELECT 1, s.seat_id, sp.price
FROM seat s
JOIN show_price sp ON sp.show_id = @show_id AND sp.category_id = s.category_id
WHERE s.screen_id = 1 AND s.row_label = 'D' AND s.seat_number IN (5, 6);

UPDATE show_seat ss
JOIN booking_seat bs ON bs.seat_id = ss.seat_id AND bs.booking_id = 1
SET ss.booking_id = 1, ss.version = ss.version + 1
WHERE ss.show_id = @show_id;

INSERT INTO payment (payment_id, booking_id, gateway, gateway_order_id, amount, status)
VALUES (1, 1, 'RAZORPAY', 'order_Q1a2b3c4d5', 500.00, 'SUCCESS');

INSERT INTO payment_webhook_event (gateway, gateway_event_id, payment_id, event_type, payload, processed_at)
VALUES ('RAZORPAY', 'evt_Q1a2b3c4d5e6', 1, 'payment.captured',
        JSON_OBJECT('order_id', 'order_Q1a2b3c4d5', 'amount', 50000, 'currency', 'INR'), NOW());

-- ---------------------------------------------------------------------
-- A live hold (user 2, same show, E1 + E2, expires in 10 minutes)
-- ---------------------------------------------------------------------
INSERT INTO booking (booking_id, user_id, show_id, status, hold_expires_at, idempotency_key)
VALUES (2, 2, @show_id, 'PENDING', NOW() + INTERVAL 10 MINUTE, 'a9d8e7f6-1b2c-4d3e-8f90-112233445566');

INSERT INTO booking_seat (booking_id, seat_id, price_paid)
SELECT 2, s.seat_id, sp.price
FROM seat s
JOIN show_price sp ON sp.show_id = @show_id AND sp.category_id = s.category_id
WHERE s.screen_id = 1 AND s.row_label = 'E' AND s.seat_number IN (1, 2);

UPDATE show_seat ss
JOIN booking_seat bs ON bs.seat_id = ss.seat_id AND bs.booking_id = 2
SET ss.booking_id = 2, ss.version = ss.version + 1
WHERE ss.show_id = @show_id;

INSERT INTO payment (payment_id, booking_id, gateway, gateway_order_id, amount, status)
VALUES (2, 2, 'RAZORPAY', 'order_Q9z8y7x6w5', 900.00, 'INITIATED');

-- ---------------------------------------------------------------------
-- An abandoned hold (user 3, A1, expired 5 minutes ago) - the seat is
-- still pointed at booking 3 but is free to be taken by anyone.
-- ---------------------------------------------------------------------
INSERT INTO booking (booking_id, user_id, show_id, status, hold_expires_at, idempotency_key)
VALUES (3, 3, @show_id, 'PENDING', NOW() - INTERVAL 5 MINUTE, 'c0ffee00-1234-4abc-9def-000000000003');

INSERT INTO booking_seat (booking_id, seat_id, price_paid)
SELECT 3, s.seat_id, sp.price
FROM seat s
JOIN show_price sp ON sp.show_id = @show_id AND sp.category_id = s.category_id
WHERE s.screen_id = 1 AND s.row_label = 'A' AND s.seat_number = 1;

UPDATE show_seat ss
JOIN booking_seat bs ON bs.seat_id = ss.seat_id AND bs.booking_id = 3
SET ss.booking_id = 3, ss.version = ss.version + 1
WHERE ss.show_id = @show_id;
