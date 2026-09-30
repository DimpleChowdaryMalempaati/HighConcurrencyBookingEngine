-- =====================================================================
-- P2: All shows at a given theatre on a given date, with show timings.
-- =====================================================================

USE booking_engine;

SET @theatre_id := 1;
SET @show_date  := CURDATE();   -- e.g. '2026-09-30'

-- ---------------------------------------------------------------------
-- P2 (a) - One row per movie/language/format with all its timings,
-- matching the reference UI ("Kantara: Chapter 1 | UA13+ | Kannada 2D |
-- 09:30 AM, 01:15 PM, 09:00 PM").
--
-- The date filter is a half-open range on start_time instead of
-- DATE(start_time) = @show_date, so it can use uq_show_screen_start
-- (screen_id, start_time) as a range scan.
-- ---------------------------------------------------------------------
SELECT
    m.movie_id,
    m.title,
    m.certification,
    l.name AS language,
    f.name AS format,
    GROUP_CONCAT(DATE_FORMAT(ms.start_time, '%h:%i %p')
                 ORDER BY ms.start_time SEPARATOR ', ') AS show_timings,
    COUNT(*) AS show_count
FROM screen      sc
JOIN movie_show  ms ON ms.screen_id  = sc.screen_id
JOIN movie       m  ON m.movie_id    = ms.movie_id
JOIN language    l  ON l.language_id = ms.language_id
JOIN show_format f  ON f.format_id   = ms.format_id
WHERE sc.theatre_id = @theatre_id
  AND ms.start_time >= @show_date
  AND ms.start_time <  @show_date + INTERVAL 1 DAY
  AND ms.status = 'SCHEDULED'
GROUP BY m.movie_id, m.title, m.certification, l.name, f.name
ORDER BY m.title, l.name, f.name;

-- ---------------------------------------------------------------------
-- P2 (b) - Flat version: one row per show (what an API would return so
-- the client can link each timing to its show_id for seat selection).
-- ---------------------------------------------------------------------
SELECT
    ms.show_id,
    m.title,
    m.certification,
    l.name  AS language,
    f.name  AS format,
    sc.name AS screen,
    TIME_FORMAT(ms.start_time, '%h:%i %p') AS start_time,
    TIME_FORMAT(ms.end_time,   '%h:%i %p') AS end_time
FROM screen      sc
JOIN movie_show  ms ON ms.screen_id  = sc.screen_id
JOIN movie       m  ON m.movie_id    = ms.movie_id
JOIN language    l  ON l.language_id = ms.language_id
JOIN show_format f  ON f.format_id   = ms.format_id
WHERE sc.theatre_id = @theatre_id
  AND ms.start_time >= @show_date
  AND ms.start_time <  @show_date + INTERVAL 1 DAY
  AND ms.status = 'SCHEDULED'
ORDER BY m.title, ms.start_time;

-- ---------------------------------------------------------------------
-- Bonus: the date strip (next 7 dates that have at least one show).
-- ---------------------------------------------------------------------
SELECT DISTINCT DATE(ms.start_time) AS show_date
FROM screen     sc
JOIN movie_show ms ON ms.screen_id = sc.screen_id
WHERE sc.theatre_id = @theatre_id
  AND ms.start_time >= CURDATE()
  AND ms.start_time <  CURDATE() + INTERVAL 7 DAY
  AND ms.status = 'SCHEDULED'
ORDER BY show_date;

-- Index check: expect `sc` via uq_screen_theatre_name and `ms` as a range
-- scan on uq_show_screen_start.
EXPLAIN
SELECT ms.show_id
FROM screen     sc
JOIN movie_show ms ON ms.screen_id = sc.screen_id
WHERE sc.theatre_id = @theatre_id
  AND ms.start_time >= @show_date
  AND ms.start_time <  @show_date + INTERVAL 1 DAY
  AND ms.status = 'SCHEDULED';
