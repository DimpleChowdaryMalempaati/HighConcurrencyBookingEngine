-- =====================================================================
-- High-Concurrency Booking Engine (BookMyShow-style) - P1 Schema
-- Target: MySQL 8.0.16+ (InnoDB, utf8mb4, CHECK constraints enforced)
-- =====================================================================

DROP DATABASE IF EXISTS booking_engine;
CREATE DATABASE booking_engine CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci;
USE booking_engine;

-- ---------------------------------------------------------------------
-- Location & venue
-- ---------------------------------------------------------------------

CREATE TABLE city (
    city_id     INT UNSIGNED  NOT NULL AUTO_INCREMENT,
    name        VARCHAR(100)  NOT NULL,
    state       VARCHAR(100)  NOT NULL,
    PRIMARY KEY (city_id),
    UNIQUE KEY uq_city_name_state (name, state)
) ENGINE = InnoDB;

CREATE TABLE theatre (
    theatre_id  INT UNSIGNED  NOT NULL AUTO_INCREMENT,
    city_id     INT UNSIGNED  NOT NULL,
    name        VARCHAR(150)  NOT NULL,
    address     VARCHAR(255)  NOT NULL,
    pincode     CHAR(6)       NOT NULL,
    PRIMARY KEY (theatre_id),
    UNIQUE KEY uq_theatre_city_name (city_id, name),
    CONSTRAINT fk_theatre_city FOREIGN KEY (city_id) REFERENCES city (city_id)
) ENGINE = InnoDB;

CREATE TABLE screen (
    screen_id   INT UNSIGNED  NOT NULL AUTO_INCREMENT,
    theatre_id  INT UNSIGNED  NOT NULL,
    name        VARCHAR(50)   NOT NULL,
    PRIMARY KEY (screen_id),
    UNIQUE KEY uq_screen_theatre_name (theatre_id, name),
    CONSTRAINT fk_screen_theatre FOREIGN KEY (theatre_id) REFERENCES theatre (theatre_id)
) ENGINE = InnoDB;

CREATE TABLE seat_category (
    category_id TINYINT UNSIGNED NOT NULL AUTO_INCREMENT,
    name        VARCHAR(30)      NOT NULL,
    PRIMARY KEY (category_id),
    UNIQUE KEY uq_seat_category_name (name)
) ENGINE = InnoDB;

-- Physical seat layout of a screen (independent of any show).
CREATE TABLE seat (
    seat_id     INT UNSIGNED     NOT NULL AUTO_INCREMENT,
    screen_id   INT UNSIGNED     NOT NULL,
    row_label   VARCHAR(3)       NOT NULL,
    seat_number SMALLINT UNSIGNED NOT NULL,
    category_id TINYINT UNSIGNED NOT NULL,
    PRIMARY KEY (seat_id),
    UNIQUE KEY uq_seat_position (screen_id, row_label, seat_number),
    CONSTRAINT fk_seat_screen   FOREIGN KEY (screen_id)   REFERENCES screen (screen_id),
    CONSTRAINT fk_seat_category FOREIGN KEY (category_id) REFERENCES seat_category (category_id)
) ENGINE = InnoDB;

-- ---------------------------------------------------------------------
-- Catalogue
-- ---------------------------------------------------------------------

CREATE TABLE movie (
    movie_id      INT UNSIGNED      NOT NULL AUTO_INCREMENT,
    title         VARCHAR(200)      NOT NULL,
    duration_min  SMALLINT UNSIGNED NOT NULL,
    certification ENUM('U','UA','UA7+','UA13+','UA16+','A','S') NOT NULL,
    release_date  DATE              NOT NULL,
    PRIMARY KEY (movie_id),
    UNIQUE KEY uq_movie_title_release (title, release_date),
    CONSTRAINT chk_movie_duration CHECK (duration_min > 0)
) ENGINE = InnoDB;

CREATE TABLE genre (
    genre_id    SMALLINT UNSIGNED NOT NULL AUTO_INCREMENT,
    name        VARCHAR(50)       NOT NULL,
    PRIMARY KEY (genre_id),
    UNIQUE KEY uq_genre_name (name)
) ENGINE = InnoDB;

-- Many-to-many: a movie has many genres (kept out of `movie` for 1NF).
CREATE TABLE movie_genre (
    movie_id    INT UNSIGNED      NOT NULL,
    genre_id    SMALLINT UNSIGNED NOT NULL,
    PRIMARY KEY (movie_id, genre_id),
    KEY idx_movie_genre_genre (genre_id),
    CONSTRAINT fk_mg_movie FOREIGN KEY (movie_id) REFERENCES movie (movie_id),
    CONSTRAINT fk_mg_genre FOREIGN KEY (genre_id) REFERENCES genre (genre_id)
) ENGINE = InnoDB;

CREATE TABLE language (
    language_id SMALLINT UNSIGNED NOT NULL AUTO_INCREMENT,
    name        VARCHAR(50)       NOT NULL,
    PRIMARY KEY (language_id),
    UNIQUE KEY uq_language_name (name)
) ENGINE = InnoDB;

CREATE TABLE show_format (
    format_id   TINYINT UNSIGNED NOT NULL AUTO_INCREMENT,
    name        VARCHAR(30)      NOT NULL,   -- 2D, 3D, IMAX 2D, 4DX ...
    PRIMARY KEY (format_id),
    UNIQUE KEY uq_show_format_name (name)
) ENGINE = InnoDB;

-- ---------------------------------------------------------------------
-- Shows & pricing
-- (`show` is a reserved word in MySQL, hence `movie_show`)
-- ---------------------------------------------------------------------

CREATE TABLE movie_show (
    show_id     BIGINT UNSIGNED   NOT NULL AUTO_INCREMENT,
    screen_id   INT UNSIGNED      NOT NULL,
    movie_id    INT UNSIGNED      NOT NULL,
    language_id SMALLINT UNSIGNED NOT NULL,
    format_id   TINYINT UNSIGNED  NOT NULL,
    start_time  DATETIME          NOT NULL,  -- theatre-local time
    end_time    DATETIME          NOT NULL,  -- scheduled slot end (movie + ads + interval + cleaning)
    status      ENUM('SCHEDULED','CANCELLED') NOT NULL DEFAULT 'SCHEDULED',
    PRIMARY KEY (show_id),
    -- One show per screen per start time; also the access path for the P2 query.
    UNIQUE KEY uq_show_screen_start (screen_id, start_time),
    KEY idx_show_movie_start (movie_id, start_time),
    CONSTRAINT fk_show_screen   FOREIGN KEY (screen_id)   REFERENCES screen (screen_id),
    CONSTRAINT fk_show_movie    FOREIGN KEY (movie_id)    REFERENCES movie (movie_id),
    CONSTRAINT fk_show_language FOREIGN KEY (language_id) REFERENCES language (language_id),
    CONSTRAINT fk_show_format   FOREIGN KEY (format_id)   REFERENCES show_format (format_id),
    CONSTRAINT chk_show_times CHECK (end_time > start_time)
) ENGINE = InnoDB;

-- Price of each seat category for a given show.
CREATE TABLE show_price (
    show_id     BIGINT UNSIGNED  NOT NULL,
    category_id TINYINT UNSIGNED NOT NULL,
    price       DECIMAL(10,2)    NOT NULL,
    PRIMARY KEY (show_id, category_id),
    CONSTRAINT fk_price_show     FOREIGN KEY (show_id)     REFERENCES movie_show (show_id),
    CONSTRAINT fk_price_category FOREIGN KEY (category_id) REFERENCES seat_category (category_id),
    CONSTRAINT chk_price_positive CHECK (price >= 0)
) ENGINE = InnoDB;

-- ---------------------------------------------------------------------
-- Users, bookings, seat inventory
-- ---------------------------------------------------------------------

CREATE TABLE app_user (
    user_id     BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    name        VARCHAR(100)    NOT NULL,
    email       VARCHAR(255)    NOT NULL,
    phone       VARCHAR(15)     NOT NULL,
    created_at  DATETIME        NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (user_id),
    UNIQUE KEY uq_user_email (email),
    UNIQUE KEY uq_user_phone (phone)
) ENGINE = InnoDB;

-- A booking starts life as a PENDING hold with an expiry and becomes
-- CONFIRMED only when a successful payment webhook is processed.
CREATE TABLE booking (
    booking_id      BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    user_id         BIGINT UNSIGNED NOT NULL,
    show_id         BIGINT UNSIGNED NOT NULL,
    status          ENUM('PENDING','CONFIRMED','EXPIRED','CANCELLED','FAILED') NOT NULL DEFAULT 'PENDING',
    hold_expires_at DATETIME        NOT NULL,
    idempotency_key CHAR(36)        NOT NULL,  -- client-generated UUID; retries return the same booking
    created_at      DATETIME        NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at      DATETIME        NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    PRIMARY KEY (booking_id),
    UNIQUE KEY uq_booking_idempotency (user_id, idempotency_key),
    KEY idx_booking_show (show_id),
    KEY idx_booking_status_expiry (status, hold_expires_at),  -- expiry sweeper
    CONSTRAINT fk_booking_user FOREIGN KEY (user_id) REFERENCES app_user (user_id),
    CONSTRAINT fk_booking_show FOREIGN KEY (show_id) REFERENCES movie_show (show_id)
) ENGINE = InnoDB;

-- Seat inventory: exactly one row per (show, seat), created when the show
-- is published. The PRIMARY KEY makes it structurally impossible for a seat
-- to belong to two bookings at once; `booking_id` is the current owner
-- (NULL = never taken or released). Whether that owner still has a valid
-- claim is decided by booking.status / booking.hold_expires_at.
CREATE TABLE show_seat (
    show_id     BIGINT UNSIGNED NOT NULL,
    seat_id     INT UNSIGNED    NOT NULL,
    booking_id  BIGINT UNSIGNED NULL,
    version     INT UNSIGNED    NOT NULL DEFAULT 0,  -- optimistic-locking counter
    PRIMARY KEY (show_id, seat_id),
    KEY idx_show_seat_booking (booking_id),
    CONSTRAINT fk_ss_show    FOREIGN KEY (show_id)    REFERENCES movie_show (show_id),
    CONSTRAINT fk_ss_seat    FOREIGN KEY (seat_id)    REFERENCES seat (seat_id),
    CONSTRAINT fk_ss_booking FOREIGN KEY (booking_id) REFERENCES booking (booking_id)
) ENGINE = InnoDB;

-- Immutable record of which seats a booking covered and what was charged.
-- price_paid is a historical snapshot: show_price may change later.
CREATE TABLE booking_seat (
    booking_id  BIGINT UNSIGNED NOT NULL,
    seat_id     INT UNSIGNED    NOT NULL,
    price_paid  DECIMAL(10,2)   NOT NULL,
    PRIMARY KEY (booking_id, seat_id),
    KEY idx_booking_seat_seat (seat_id),
    CONSTRAINT fk_bs_booking FOREIGN KEY (booking_id) REFERENCES booking (booking_id),
    CONSTRAINT fk_bs_seat    FOREIGN KEY (seat_id)    REFERENCES seat (seat_id)
) ENGINE = InnoDB;

-- ---------------------------------------------------------------------
-- Payments & idempotent webhooks
-- ---------------------------------------------------------------------

CREATE TABLE payment (
    payment_id         BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    booking_id         BIGINT UNSIGNED NOT NULL,
    gateway            VARCHAR(30)     NOT NULL,   -- RAZORPAY, STRIPE ...
    gateway_order_id   VARCHAR(100)    NOT NULL,
    amount             DECIMAL(10,2)   NOT NULL,
    status             ENUM('INITIATED','SUCCESS','FAILED','REFUND_PENDING','REFUNDED') NOT NULL DEFAULT 'INITIATED',
    created_at         DATETIME        NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at         DATETIME        NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    PRIMARY KEY (payment_id),
    UNIQUE KEY uq_payment_gateway_order (gateway, gateway_order_id),
    KEY idx_payment_booking (booking_id),
    CONSTRAINT fk_payment_booking FOREIGN KEY (booking_id) REFERENCES booking (booking_id),
    CONSTRAINT chk_payment_amount CHECK (amount >= 0)
) ENGINE = InnoDB;

-- Every webhook delivery is recorded once. Gateways retry deliveries, so
-- the UNIQUE (gateway, gateway_event_id) key is the idempotency guard:
-- a duplicate INSERT fails and the handler simply returns 200.
CREATE TABLE payment_webhook_event (
    event_id          BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    gateway           VARCHAR(30)     NOT NULL,
    gateway_event_id  VARCHAR(100)    NOT NULL,
    payment_id        BIGINT UNSIGNED NOT NULL,
    event_type        VARCHAR(50)     NOT NULL,   -- payment.captured, payment.failed ...
    payload           JSON            NOT NULL,
    received_at       DATETIME        NOT NULL DEFAULT CURRENT_TIMESTAMP,
    processed_at      DATETIME        NULL,
    PRIMARY KEY (event_id),
    UNIQUE KEY uq_webhook_gateway_event (gateway, gateway_event_id),
    KEY idx_webhook_payment (payment_id),
    CONSTRAINT fk_webhook_payment FOREIGN KEY (payment_id) REFERENCES payment (payment_id)
) ENGINE = InnoDB;
