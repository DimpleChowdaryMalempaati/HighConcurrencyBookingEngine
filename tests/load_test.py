"""
Load and concurrency test for the booking engine.

Creates a fresh 500-seat screen and one show, then runs a burst of virtual
users against the stored procedures in sql/04_booking_flow.sql:

  * 70% of users fight over the same "hot" block of centre seats;
  * users retry with other seats when theirs are taken;
  * some clients re-send the same hold request (network retry);
  * after a hold, users pay (success), pay (failure), or abandon;
  * the gateway re-delivers some success webhooks concurrently;
  * some payments arrive after the hold has expired;
  * reader threads run the P2 listing query throughout.

At the end it checks the correctness invariants and exits non-zero if any
of them is violated.

Usage:
  pip install mysql-connector-python
  python tests/load_test.py --host 127.0.0.1 --port 3306 --users 2000 --workers 100
"""

import argparse
import json
import random
import statistics
import string
import sys
import threading
import time
import uuid
from collections import Counter, defaultdict
from concurrent.futures import ThreadPoolExecutor

import mysql.connector

ROWS = [c for c in string.ascii_uppercase[:20]]  # A..T
SEATS_PER_ROW = 25
HOT_ROWS = ROWS[7:13]                             # H..M
HOT_COLS = range(8, 19)                           # 8..18


class Stats:
    def __init__(self):
        self.lock = threading.Lock()
        self.latency = defaultdict(list)
        self.outcomes = Counter()

    def record(self, op, seconds, outcome):
        with self.lock:
            self.latency[op].append(seconds)
            self.outcomes[f"{op}:{outcome}"] += 1


class Tracker:
    """Client-side facts used to cross-check the database afterwards."""

    def __init__(self):
        self.lock = threading.Lock()
        self.confirmed_results = 0
        self.on_time_payments = []    # (booking_id, webhook_result)
        self.late_payments = []       # (booking_id, webhook_result)
        self.retry_mismatches = 0
        self.deadlocks = 0
        self.errors = []


def connect(args):
    return mysql.connector.connect(
        host=args.host, port=args.port, user=args.user,
        password=args.password, database="booking_engine", autocommit=True,
    )


def setup(args):
    """Create an isolated screen, show, prices, inventory and users."""
    run = uuid.uuid4().hex[:8]
    cn = connect(args)
    cur = cn.cursor()

    cur.execute("INSERT INTO screen (theatre_id, name) VALUES (1, %s)", (f"LoadTest {run}",))
    screen_id = cur.lastrowid

    values = []
    for r_idx, row in enumerate(ROWS):
        category = 1 if r_idx < 8 else (2 if r_idx < 16 else 3)
        for n in range(1, SEATS_PER_ROW + 1):
            values.append((screen_id, row, n, category))
    cur.executemany(
        "INSERT INTO seat (screen_id, row_label, seat_number, category_id) VALUES (%s, %s, %s, %s)",
        values,
    )

    cur.execute(
        """INSERT INTO movie_show (screen_id, movie_id, language_id, format_id, start_time, end_time)
           VALUES (%s, 1, 1, 1, NOW() + INTERVAL 1 DAY, NOW() + INTERVAL 1 DAY + INTERVAL 195 MINUTE)""",
        (screen_id,),
    )
    show_id = cur.lastrowid
    cur.execute(
        """INSERT INTO show_price (show_id, category_id, price)
           VALUES (%s, 1, 180.00), (%s, 2, 250.00), (%s, 3, 450.00)""",
        (show_id, show_id, show_id),
    )
    cur.execute(
        "INSERT INTO show_seat (show_id, seat_id) SELECT %s, seat_id FROM seat WHERE screen_id = %s",
        (show_id, screen_id),
    )

    cur.executemany(
        "INSERT INTO app_user (name, email, phone) VALUES (%s, %s, %s)",
        [(f"Load User {i}", f"load_{run}_{i}@example.com", f"{run[:4]}{i:07d}"[-15:])
         for i in range(args.users)],
    )
    cur.execute("SELECT user_id FROM app_user WHERE email LIKE %s ORDER BY user_id", (f"load_{run}_%",))
    user_ids = [r[0] for r in cur.fetchall()]

    cur.execute(
        "SELECT seat_id, row_label, seat_number FROM seat WHERE screen_id = %s",
        (screen_id,),
    )
    seat_map = {(row, num): seat_id for seat_id, row, num in cur.fetchall()}
    cur.close()
    cn.close()
    return run, show_id, user_ids, seat_map


def pick_seats(seat_map):
    count = random.choice([1, 2, 2, 2, 3, 4])
    if random.random() < 0.7:
        row = random.choice(HOT_ROWS)
        start = random.randint(HOT_COLS.start, HOT_COLS.stop - count)
    else:
        row = random.choice(ROWS)
        start = random.randint(1, SEATS_PER_ROW - count + 1)
    return [seat_map[(row, start + i)] for i in range(count)]


def call_hold(cur, user_id, show_id, seat_ids, key, hold_seconds):
    res = cur.callproc("sp_hold_seats", (user_id, show_id, json.dumps(seat_ids), key, hold_seconds, 0, ""))
    return res[5], res[6]


def call_webhook(cur, event_id, order_id, event_type):
    res = cur.callproc(
        "sp_process_payment_webhook",
        ("LOADGW", event_id, order_id, event_type, json.dumps({"event": event_type}), ""),
    )
    return res[5]


def timed(stats, op, fn, *a):
    t0 = time.perf_counter()
    result = fn(*a)
    outcome = result[1] if isinstance(result, tuple) else result
    stats.record(op, time.perf_counter() - t0, outcome)
    return result


def with_deadlock_retry(tracker, fn, *a):
    for attempt in range(3):
        try:
            return fn(*a)
        except mysql.connector.Error as e:
            if e.errno in (1213, 1205) and attempt < 2:   # deadlock / lock wait timeout
                with tracker.lock:
                    tracker.deadlocks += 1
                time.sleep(0.01 * (attempt + 1))
                continue
            raise


def journey(args, user_id, show_id, seat_map, stats, tracker, dup_pool, local):
    if not hasattr(local, "cn"):
        local.cn = connect(args)
    cur = local.cn.cursor()
    try:
        booking_id = None
        for _ in range(3):
            seats = pick_seats(seat_map)
            key = str(uuid.uuid4())
            t_request = time.monotonic()
            booking_id, result = with_deadlock_retry(
                tracker, timed, stats, "hold", call_hold, cur, user_id, show_id, seats, key, args.hold_seconds)

            if random.random() < 0.10:
                retry_id, retry_result = timed(stats, "hold_retry", call_hold,
                                               cur, user_id, show_id, seats, key, args.hold_seconds)
                if booking_id is not None and (retry_result != "DUPLICATE_REQUEST" or retry_id != booking_id):
                    with tracker.lock:
                        tracker.retry_mismatches += 1

            if result == "HELD":
                break
            booking_id = None
            time.sleep(random.uniform(0, args.think))

        if booking_id is None:
            return

        roll = random.random()
        if roll < 0.20:
            return  # abandon cart; hold must expire on its own

        order_id = f"order_{booking_id}"
        cur.execute(
            """INSERT INTO payment (booking_id, gateway, gateway_order_id, amount)
               SELECT %s, 'LOADGW', %s, SUM(price_paid) FROM booking_seat WHERE booking_id = %s""",
            (booking_id, order_id, booking_id),
        )

        late = roll >= 0.95
        if late:
            time.sleep(args.hold_seconds + 2)
        else:
            time.sleep(random.uniform(0, args.think))

        event_type = "payment.failed" if 0.20 <= roll < 0.30 else "payment.captured"
        event_id = f"evt_{booking_id}"
        on_time = (time.monotonic() - t_request) < args.hold_seconds - 1.5

        dup_future = None
        if event_type == "payment.captured" and random.random() < 0.30:
            dup_future = dup_pool.submit(duplicate_delivery, args, stats, tracker, event_id, order_id)

        result = with_deadlock_retry(tracker, timed, stats, "webhook", call_webhook,
                                     cur, event_id, order_id, event_type)
        dup_result = dup_future.result() if dup_future else None

        with tracker.lock:
            tracker.confirmed_results += [result, dup_result].count("CONFIRMED")
            if event_type == "payment.captured":
                (tracker.on_time_payments if on_time and not late else tracker.late_payments).append(
                    (booking_id, result if result != "DUPLICATE_EVENT" else dup_result))
    except Exception as e:  # noqa: BLE001
        with tracker.lock:
            tracker.errors.append(repr(e))
    finally:
        cur.close()


dup_local = threading.local()


def duplicate_delivery(args, stats, tracker, event_id, order_id):
    if not hasattr(dup_local, "cn"):
        dup_local.cn = connect(args)
    cur = dup_local.cn.cursor()
    try:
        return with_deadlock_retry(tracker, timed, stats, "webhook_dup", call_webhook,
                                   cur, event_id, order_id, "payment.captured")
    finally:
        cur.close()


P2_SQL = """
SELECT m.title, l.name, f.name,
       GROUP_CONCAT(DATE_FORMAT(ms.start_time, '%h:%i %p') ORDER BY ms.start_time SEPARATOR ', ')
FROM screen sc
JOIN movie_show ms ON ms.screen_id = sc.screen_id
JOIN movie m ON m.movie_id = ms.movie_id
JOIN language l ON l.language_id = ms.language_id
JOIN show_format f ON f.format_id = ms.format_id
WHERE sc.theatre_id = 1
  AND ms.start_time >= CURDATE() AND ms.start_time < CURDATE() + INTERVAL 1 DAY
  AND ms.status = 'SCHEDULED'
GROUP BY m.movie_id, m.title, l.name, f.name
"""


def reader(args, stats, stop):
    cn = connect(args)
    cur = cn.cursor()
    while not stop.is_set():
        t0 = time.perf_counter()
        cur.execute(P2_SQL)
        cur.fetchall()
        stats.record("p2_listing", time.perf_counter() - t0, "OK")
    cur.close()
    cn.close()


def check_invariants(args, show_id, tracker):
    cn = connect(args)
    cur = cn.cursor()
    checks = []

    def check(name, sql, params, expect=0):
        cur.execute(sql, params)
        value = cur.fetchone()[0] or 0
        checks.append((name, value, expect, value == expect))

    check("No seat belongs to more than one CONFIRMED booking",
          """SELECT COUNT(*) FROM (
               SELECT bs.seat_id FROM booking_seat bs JOIN booking b ON b.booking_id = bs.booking_id
               WHERE b.show_id = %s AND b.status = 'CONFIRMED'
               GROUP BY bs.seat_id HAVING COUNT(*) > 1) x""", (show_id,))

    check("Every CONFIRMED booking still owns all of its seats",
          """SELECT COUNT(*) FROM booking b JOIN booking_seat bs ON bs.booking_id = b.booking_id
             JOIN show_seat ss ON ss.show_id = b.show_id AND ss.seat_id = bs.seat_id
             WHERE b.show_id = %s AND b.status = 'CONFIRMED' AND NOT (ss.booking_id <=> b.booking_id)""",
          (show_id,))

    check("Every CONFIRMED booking has exactly one SUCCESS payment for the right amount",
          """SELECT COUNT(*) FROM booking b
             WHERE b.show_id = %s AND b.status = 'CONFIRMED'
               AND (SELECT COUNT(*) FROM payment p
                    WHERE p.booking_id = b.booking_id AND p.status = 'SUCCESS'
                      AND p.amount = (SELECT SUM(price_paid) FROM booking_seat WHERE booking_id = b.booking_id)
                   ) <> 1""",
          (show_id,))

    check("No seat is owned by a FAILED / CANCELLED booking",
          """SELECT COUNT(*) FROM show_seat ss JOIN booking b ON b.booking_id = ss.booking_id
             WHERE ss.show_id = %s AND b.status IN ('FAILED', 'CANCELLED')""", (show_id,))

    check("No SUCCESS payment attached to a non-CONFIRMED booking",
          """SELECT COUNT(*) FROM payment p JOIN booking b ON b.booking_id = p.booking_id
             WHERE b.show_id = %s AND p.status = 'SUCCESS' AND b.status <> 'CONFIRMED'""", (show_id,))

    cur.execute("SELECT COUNT(*) FROM booking WHERE show_id = %s AND status = 'CONFIRMED'", (show_id,))
    db_confirmed = cur.fetchone()[0]
    checks.append(("Webhook CONFIRMED responses == CONFIRMED bookings (no double confirm)",
                   tracker.confirmed_results, db_confirmed, tracker.confirmed_results == db_confirmed))

    lost = [b for b, r in tracker.on_time_payments if r != "CONFIRMED"]
    checks.append(("No lost holds: every on-time payment was CONFIRMED", len(lost), 0, not lost))

    checks.append(("Idempotent hold retries returned the same booking",
                   tracker.retry_mismatches, 0, tracker.retry_mismatches == 0))

    # Let every remaining hold expire, run the sweeper, then check nothing is stuck.
    time.sleep(args.hold_seconds + 1)
    cur.execute("UPDATE booking b JOIN payment p ON p.booking_id = b.booking_id "
                "SET b.hold_expires_at = b.hold_expires_at - INTERVAL 10 MINUTE "
                "WHERE b.show_id = %s AND b.status = 'PENDING'", (show_id,))  # skip the 5-min payment grace
    cur.callproc("sp_expire_holds", (100000, 0))
    check("After expiry + sweep, no seat is held by a PENDING booking",
          """SELECT COUNT(*) FROM show_seat ss JOIN booking b ON b.booking_id = ss.booking_id
             WHERE ss.show_id = %s AND b.status = 'PENDING'""", (show_id,))

    check("Sold seats + free seats == total seats",
          """SELECT (SELECT COUNT(*) FROM show_seat WHERE show_id = %s)
                  - (SELECT COUNT(*) FROM show_seat ss JOIN booking b ON b.booking_id = ss.booking_id
                     WHERE ss.show_id = %s AND b.status = 'CONFIRMED')
                  - (SELECT COUNT(*) FROM show_seat WHERE show_id = %s AND booking_id IS NULL)""",
          (show_id, show_id, show_id))

    cur.execute(
        """SELECT b.status, COUNT(*) FROM booking b WHERE b.show_id = %s GROUP BY b.status""", (show_id,))
    booking_status = dict(cur.fetchall())
    cur.execute(
        """SELECT COUNT(*) FROM show_seat ss JOIN booking b ON b.booking_id = ss.booking_id
           WHERE ss.show_id = %s AND b.status = 'CONFIRMED'""", (show_id,))
    seats_sold = cur.fetchone()[0]
    cur.execute("SELECT COUNT(*) FROM payment_webhook_event e JOIN payment p ON p.payment_id = e.payment_id "
                "JOIN booking b ON b.booking_id = p.booking_id WHERE b.show_id = %s", (show_id,))
    webhook_rows = cur.fetchone()[0]
    cur.close()
    cn.close()
    return checks, booking_status, seats_sold, webhook_rows


def pct(values, p):
    if not values:
        return 0.0
    values = sorted(values)
    k = max(0, min(len(values) - 1, int(round(p / 100 * len(values))) - 1))
    return values[k] * 1000


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=3306)
    ap.add_argument("--user", default="root")
    ap.add_argument("--password", default="root")
    ap.add_argument("--users", type=int, default=2000)
    ap.add_argument("--workers", type=int, default=100)
    ap.add_argument("--readers", type=int, default=5)
    ap.add_argument("--hold-seconds", type=int, default=8)
    ap.add_argument("--think", type=float, default=0.3, help="max think time between steps (s)")
    args = ap.parse_args()

    run, show_id, user_ids, seat_map = setup(args)
    print(f"run={run} show_id={show_id} seats={len(seat_map)} users={len(user_ids)} "
          f"workers={args.workers} hold={args.hold_seconds}s")

    stats, tracker = Stats(), Tracker()
    stop = threading.Event()
    readers = [threading.Thread(target=reader, args=(args, stats, stop)) for _ in range(args.readers)]
    for t in readers:
        t.start()

    local = threading.local()
    t0 = time.perf_counter()
    with ThreadPoolExecutor(max_workers=20) as dup_pool, ThreadPoolExecutor(max_workers=args.workers) as pool:
        futures = [pool.submit(journey, args, uid, show_id, seat_map, stats, tracker, dup_pool, local)
                   for uid in user_ids]
        for f in futures:
            f.result()
    elapsed = time.perf_counter() - t0
    stop.set()
    for t in readers:
        t.join()

    checks, booking_status, seats_sold, webhook_rows = check_invariants(args, show_id, tracker)

    print(f"\n== Load profile\nduration: {elapsed:.1f}s   virtual users: {len(user_ids)}   "
          f"deadlock/lock-timeout retries: {tracker.deadlocks}   unexpected errors: {len(tracker.errors)}")
    for e in tracker.errors[:5]:
        print("  error:", e)

    print("\n== Latency per operation")
    print(f"{'operation':<14}{'count':>8}{'ops/s':>9}{'p50 ms':>9}{'p95 ms':>9}{'p99 ms':>9}{'max ms':>9}")
    for op in ("hold", "hold_retry", "webhook", "webhook_dup", "p2_listing"):
        v = stats.latency.get(op, [])
        if v:
            print(f"{op:<14}{len(v):>8}{len(v) / elapsed:>9.1f}{pct(v, 50):>9.1f}{pct(v, 95):>9.1f}"
                  f"{pct(v, 99):>9.1f}{max(v) * 1000:>9.1f}")

    print("\n== Outcomes")
    for k, v in sorted(stats.outcomes.items()):
        if not k.startswith("p2_listing"):
            print(f"  {k:<36}{v:>7}")
    print(f"  final booking states: {booking_status}")
    print(f"  seats sold: {seats_sold}/{len(seat_map)}   webhook events stored: {webhook_rows}")

    print("\n== Invariants")
    ok = not tracker.errors
    for name, value, expect, passed in checks:
        ok &= passed
        print(f"  [{'PASS' if passed else 'FAIL'}] {name} (got {value}, expected {expect})")
    print("\nRESULT:", "ALL INVARIANTS HOLD" if ok else "FAILURES DETECTED")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
