#!/bin/sh
# Fires N concurrent sessions that all try to hold the same two seats of one
# show. Exactly one must win; the rest must get SEATS_UNAVAILABLE.
# Usage (inside the MySQL container): sh race_same_seats.sh [N]
N=${1:-50}
MYSQL="mysql -uroot -proot -N -B booking_engine"

SHOW_ID=$($MYSQL -e "SELECT show_id FROM movie_show WHERE screen_id = 1 AND start_time > NOW() AND status = 'SCHEDULED' ORDER BY start_time DESC LIMIT 1" 2>/dev/null)
SEATS=$($MYSQL -e "SELECT JSON_ARRAYAGG(seat_id) FROM seat WHERE screen_id = 1 AND row_label = 'C' AND seat_number IN (5, 6)" 2>/dev/null)
echo "show_id=$SHOW_ID seats=$SEATS sessions=$N"

OUT=$(mktemp -d)
i=1
while [ "$i" -le "$N" ]; do
  USER_ID=$(( (i % 3) + 1 ))
  KEY=$(cat /proc/sys/kernel/random/uuid)
  $MYSQL -e "CALL sp_hold_seats($USER_ID, $SHOW_ID, '$SEATS', '$KEY', 600, @b, @r); SELECT @r;" \
    > "$OUT/$i" 2>&1 &
  i=$((i + 1))
done
wait

echo "--- results"
cat "$OUT"/* | grep -v "Using a password" | sort | uniq -c
echo "--- owners of the contested seats (must be exactly one booking)"
$MYSQL -e "SELECT COUNT(DISTINCT ss.booking_id) AS distinct_owners, COUNT(*) AS seats FROM show_seat ss JOIN JSON_TABLE('$SEATS', '\$[*]' COLUMNS (seat_id INT PATH '\$')) j ON j.seat_id = ss.seat_id WHERE ss.show_id = $SHOW_ID" 2>/dev/null
rm -rf "$OUT"
