#!/usr/bin/env bash
# Database failover test (MariaDB primary/replica + keepalived virtual IP 10.10.20.35 = db.dc.lab).
#
#   ./scripts/db-failover.sh status    -> who is primary (owns the VIP), replication health
#   ./scripts/db-failover.sh           -> crash MariaDB on the primary, measure the outage
#   ./scripts/db-failover.sh server    -> the primary server goes offline (network link down)
#   ./scripts/db-failover.sh restore   -> rebuild the failed node as the new replica (roles swapped)
#
# How the outage is measured: app01 writes one row through the VIP every 0.2 s (new connection
# each time, 1 s connect timeout). The outage is the time between the failure and the first
# successful write on the new primary. Writes need a *writable* primary, so this includes the
# promotion of the replica, not just the VIP move.
P=${P:-clab-mini-dc}
VIP=10.10.20.35
. "$(dirname "$0")/../lab.env"          # passwords (scripts/gen-secrets.sh)
APP="-u app -p$DB_APP_PASS"
REPL_PASS=$DB_REPL_PASS
declare -A IP=([db01]=10.10.20.30 [db02]=10.10.20.31)

sql()   { docker exec "$P-$1" mariadb -N -e "$2" 2>/dev/null; }
owner() { for n in db01 db02; do docker exec "$P-$n" ip -4 addr show dev eth1 up 2>/dev/null | grep -q "$VIP/" && echo "$n"; done; }
other() { [ "$1" = db01 ] && echo db02 || echo db01; }
repl()  { docker exec "$P-$1" mariadb -e 'SHOW SLAVE STATUS\G' 2>/dev/null |
          awk '/Master_Host|Slave_IO_Running:|Slave_SQL_Running:|Seconds_Behind_Master/ {printf "%s %s  ", $1, $2}'; }

status() {
  local m; m=$(owner)
  echo "== Database HA status"
  echo "  VIP $VIP (db.dc.lab) owned by: ${m:-NOBODY}"
  for n in db01 db02; do
    local ro; ro=$(sql $n "select @@read_only")
    printf '  %-5s %-12s read_only=%-2s %s\n' "$n" "${IP[$n]}" "${ro:-?}" "$(repl $n)"
  done
}

case "${1:-crash}" in
status) status; exit 0 ;;

restore)
  M=$(owner); [ -z "$M" ] && { echo "Nobody owns the VIP - redeploy the lab."; exit 1; }
  F=$(other "$M")
  echo "== Rebuilding $F as replica of the current primary $M"
  docker exec "$P-$F" pkill keepalived; sleep 1                       # never let it fight for the VIP
  docker exec "$P-$F" ip link set eth1 up
  if ! docker exec "$P-$F" mariadb -e 'select 1' >/dev/null 2>&1; then
    # the killed mariadbd stays a zombie (the container's PID 1 never reaps it) and its pid file makes
    # mysqld_safe believe it still runs -> remove the stale pid file and socket first
    docker exec -d "$P-$F" sh -c 'rm -f /run/mysqld/mysqld.pid /run/mysqld/mysqld.sock; mkdir -p /run/mysqld && chown mysql:mysql /run/mysqld; mysqld_safe --bind-address=0.0.0.0 </dev/null >/var/log/mysqld_safe.log 2>&1'
    for _ in $(seq 1 30); do docker exec "$P-$F" mariadb -e 'select 1' >/dev/null 2>&1 && break; sleep 1; done
  fi
  docker exec "$P-$F" mariadb --force -e "STOP SLAVE; RESET SLAVE ALL; SET GLOBAL read_only=ON; RESET MASTER; DROP DATABASE IF EXISTS shop;" 2>/dev/null
  docker exec "$P-$F" sh -c "mariadb-dump -h ${IP[$M]} -u repl -p$REPL_PASS --single-transaction --gtid --master-data=1 --databases shop > /tmp/seed.sql && { echo 'SET sql_log_bin=0;'; cat /tmp/seed.sql; } | mariadb"
  docker exec "$P-$F" mariadb -e "CHANGE MASTER TO MASTER_HOST='${IP[$M]}', MASTER_USER='repl', MASTER_PASSWORD='$REPL_PASS', MASTER_USE_GTID=slave_pos, MASTER_CONNECT_RETRY=1, MASTER_SSL=1; START SLAVE;"
  for _ in $(seq 1 30); do [[ "$(repl "$F")" == *"Slave_IO_Running: Yes"* ]] && break; sleep 1; done
  docker exec -d "$P-$F" sh -c 'keepalived -f /etc/keepalived/keepalived.conf </dev/null >/dev/null 2>&1'
  sleep 3; status
  echo "Done: $M stays primary, $F is its replica again. Run the test again to fail over the other way."
  exit 0 ;;

crash|server) MODE=${1:-crash} ;;
*) sed -n '2,8p' "$0"; exit 1 ;;
esac

# ------------------------------------------------------------------ failover test
M=$(owner); S=$(other "$M")
status
[ -z "$M" ] && { echo "Nobody owns the VIP - redeploy the lab."; exit 1; }
[[ "$(repl "$S")" != *"Slave_IO_Running: Yes"*"Slave_SQL_Running: Yes"* ]] &&
  { echo "$S is not replicating - run: ./scripts/db-failover.sh restore"; exit 1; }

docker exec "$P-app01" mariadb $APP -h $VIP shop -e \
  "CREATE TABLE IF NOT EXISTS ha_probe (id INT AUTO_INCREMENT PRIMARY KEY, ts DATETIME(6), node VARCHAR(8))" || exit 1

DUR=25
echo; echo "== Writing to db.dc.lab ($VIP) every 0.2 s from app01 for ${DUR} s"
docker exec "$P-app01" rm -f /tmp/probe.log
docker exec -d "$P-app01" bash -c "end=\$((\$(date +%s)+$DUR)); while [ \$(date +%s) -lt \$end ]; do
  t=\$(date +%s.%3N)
  r=\$(mariadb --connect-timeout=1 $APP -h $VIP shop -N -e \"INSERT INTO ha_probe(ts,node) VALUES(NOW(6),@@hostname); SELECT CONCAT(LAST_INSERT_ID(),' ',@@hostname)\" 2>/dev/null) \
    && echo \"\$t OK \$r\" >> /tmp/probe.log || echo \"\$t FAIL\" >> /tmp/probe.log
  sleep 0.2; done"
sleep 5

if [ "$MODE" = server ]; then
  T0=$(date +%s.%3N); docker exec "$P-$M" ip link set eth1 down
  echo "  $(date +%T) $M is OFFLINE (network link cut)"
else
  T0=$(date +%s.%3N); docker exec "$P-$M" sh -c 'pkill -9 -x mysqld_safe; pkill -9 -x mariadbd'
  echo "  $(date +%T) MariaDB on $M CRASHED (process killed)"
fi
sleep $((DUR - 4))

docker exec "$P-app01" cat /tmp/probe.log > /tmp/probe.log
LAST_OK_ID=$(awk -v t=$T0 '$1<t && $2=="OK" {id=$3} END {print id}' /tmp/probe.log)
read -r OUT FIRST_OK FIRST_NODE FAILS TOTAL < <(awk -v t=$T0 '
  {n++} $2=="FAIL" && $1>=t {f++}
  $1>=t && $2=="OK" && !done {first=$1; node=$4; done=1}
  END {if (done) printf "%.1f %s %s %d %d\n", first-t, first, node, f, n; else printf "never(>%ds) 0 none %d %d\n", 20, f, n}' /tmp/probe.log)
LOST=$(sql "$S" "select count(*) from shop.ha_probe where id=${LAST_OK_ID:-0}")

echo; status
echo; echo "== Result ($MODE)"
printf '  failure of %-6s at          %s\n' "$M" "$(date -d @"$T0" +%T.%3N)"
printf '  first write OK on %-6s at   %s\n' "$FIRST_NODE" "$(date -d @"$FIRST_OK" +%T.%3N 2>/dev/null)"
printf '  >> database unavailable:     %s s  (%s of %s writes failed)\n' "$OUT" "$FAILS" "$TOTAL"
printf '  last write acknowledged before the failure (id %s) present on %s: %s\n' \
  "$LAST_OK_ID" "$S" "$([ "$LOST" = 1 ] && echo yes - no data lost || echo NO - lost)"
docker exec "$P-$S" tail -1 /var/log/db-promote.log 2>/dev/null | sed 's/^/  keepalived: /'
echo; echo "Back to a redundant state: ./scripts/db-failover.sh restore"
