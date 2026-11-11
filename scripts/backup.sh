#!/bin/bash
# Backup job of the data center, runs on backup01 (from WSL it re-runs itself inside backup01).
#   ./scripts/backup.sh run           back up now: database + switch configs -> local disk + SAN copy
#   ./scripts/backup.sh list          what is stored on backup01
#   ./scripts/backup.sh restore-test  prove the last backup can be restored (local copy and SAN copy)
#   ./scripts/backup.sh status        age of the last backup + checksum check (used by tests.sh)
# backup01 starts "schedule" at deploy: first run after 6 minutes, then every night at 02:00.
#
# 3-2-1 rule: production data (db01/db02) + backup01's disk + the TrueNAS backup LUN (iSCSI, ZFS mirror,
# daily ZFS snapshots kept 14 days) = 3 copies on 2 kinds of storage. The off-site copy (tapes) is
# physical only, see the design report.
[ "$(hostname)" != backup01 ] && exec docker exec clab-mini-dc-backup01 bash /lab/scripts/backup.sh "$@"
[ -f /lab/lab.env ] && . /lab/lab.env

DIR=/srv/backup
KEEP=7                                    # restore points kept per kind
DB_HOSTS="10.10.20.31 10.10.20.30"        # dump from the replica (db02) to spare the primary
SWITCHES="core-01:10.10.10.11 core-02:10.10.10.12 tor-01:10.10.10.21 tor-02:10.10.10.22"
LUN="iscsi://10.10.30.10/iqn.2026-09.lab.dc:storage01.backup/1"
SAN_READ_MB=64                            # how much of the LUN restore-test reads back
DB="mariadb -u backup -p$DB_BACKUP_PASS --connect-timeout=3"

log() { echo "$*"; echo "$(date '+%F %T') $*" >> /var/log/dc-backup.log; }
notify() { logger -n 10.10.70.20 -P 514 -d -t dc-backup "$*" 2>/dev/null; }   # NOC syslog
sum() { (cd "$(dirname "$1")" && sha256sum "$(basename "$1")" > "$(basename "$1").sha256"); }
prune() { ls -1t "$1"/$2 2>/dev/null | tail -n +$((KEEP + 1)) | while read -r f; do rm -f "$f" "$f.sha256" "${f%.sql.gz}.meta"; done; }

backup_db() {
  local src ts=$1 f
  for h in $DB_HOSTS; do $DB -h "$h" -e 'select 1' >/dev/null 2>&1 && { src=$h; break; }; done
  [ -z "$src" ] && { log "  DB      FAILED - no database server reachable"; return 1; }
  f=$DIR/db/shop-$ts.sql.gz
  if ! mariadb-dump -h "$src" -u backup -p"$DB_BACKUP_PASS" --single-transaction --routines --events \
       --triggers --databases shop 2>>/var/log/dc-backup.log | gzip > "$f" || [ ! -s "$f" ]; then
    rm -f "$f"; log "  DB      FAILED - dump from $src"; return 1
  fi
  # row count of every table at backup time: restore-test compares against it
  $DB -h "$src" -N -e "select table_name, table_rows from information_schema.tables where table_schema='shop'" \
    | while read -r t _; do echo "$t $($DB -h "$src" -N -e "select count(*) from shop.\`$t\`")"; done > "${f%.sql.gz}.meta"
  sum "$f"
  log "  DB      shop -> $(basename "$f") ($(du -h "$f" | cut -f1), from $src, $(wc -l < "${f%.sql.gz}.meta") tables)"
}

backup_configs() {
  local ts=$1 ok=0 out name ip
  mkdir -p "$DIR/configs/$ts"
  for s in $SWITCHES; do
    name=${s%%:*} ip=${s#*:}
    out=$(curl -sk -m 10 -u "$SWITCH_USER:$SWITCH_PASS" "https://$ip/command-api" \
          -d '{"jsonrpc":"2.0","method":"runCmds","params":{"version":1,"cmds":["enable","show running-config"],"format":"text"},"id":1}' \
          | python3 -c 'import json,sys; print(json.load(sys.stdin)["result"][1]["output"], end="")' 2>/dev/null)
    [ -n "$out" ] && { echo "$out" > "$DIR/configs/$ts/$name.cfg"; ok=$((ok + 1)); }
  done
  tar -C "$DIR/configs" -czf "$DIR/configs/switches-$ts.tar.gz" "$ts" && rm -rf "${DIR:?}/configs/$ts"
  sum "$DIR/configs/switches-$ts.tar.gz"
  log "  CONFIGS $ok/4 switch running-configs -> switches-$ts.tar.gz"
  [ "$ok" -eq 4 ]
}

copy_to_san() {
  local t=/tmp/san-backup.tar
  tar -C "$DIR" -cf "$t" db configs
  if timeout 120 qemu-img convert -n -f raw -O raw "$t" "$LUN" 2>>/var/log/dc-backup.log; then
    log "  SAN     $(du -h "$t" | cut -f1) written to the TrueNAS backup LUN (storage01.backup)"
    rm -f "$t"
  else
    log "  SAN     FAILED - TrueNAS LUN not reachable (VM still booting?), local copy kept"
    rm -f "$t"; return 1
  fi
}

run() {
  local ts rc=0
  ts=$(date +%Y%m%d-%H%M%S)
  mkdir -p "$DIR/db" "$DIR/configs"
  log "== Backup $ts"
  backup_db "$ts" || rc=1
  backup_configs "$ts" || rc=1
  prune "$DIR/db" "shop-*.sql.gz"; prune "$DIR/configs" "switches-*.tar.gz"
  copy_to_san || rc=1
  [ $rc -eq 0 ] && { log "== Backup OK"; notify "backup $ts OK"; } \
                || { log "== Backup finished WITH ERRORS (see above)"; notify "backup $ts FAILED"; }
  return $rc
}

# Restores a dump into a throw-away MariaDB instance on backup01 and compares the row counts.
check_dump() {  # $1 = dump file (.sql.gz), $2 = meta file
  local d=/tmp/restore-test rc=0
  rm -rf $d; mkdir -p $d/data; chown -R mysql:mysql $d
  mariadb-install-db --user=mysql --datadir=$d/data --auth-root-authentication-method=normal >/dev/null 2>&1
  mariadbd --user=mysql --datadir=$d/data --socket=$d/sock --skip-networking --pid-file=$d/pid \
    --log-error=$d/err.log </dev/null >/dev/null 2>&1 &
  for _ in $(seq 1 30); do mariadb -S $d/sock -e 'select 1' >/dev/null 2>&1 && break; sleep 1; done
  zcat "$1" | mariadb -S $d/sock || rc=1
  while read -r t n; do
    got=$(mariadb -S $d/sock -N -e "select count(*) from shop.\`$t\`" 2>/dev/null)
    if [ "$got" = "$n" ]; then echo "      shop.$t: $got rows (as at backup time)"; else echo "      shop.$t: $got rows, expected $n"; rc=1; fi
  done < "$2"
  mariadb-admin -S $d/sock shutdown >/dev/null 2>&1; sleep 1; rm -rf $d
  return $rc
}

restore_test() {
  local f rc=0 n
  f=$(ls -1t $DIR/db/shop-*.sql.gz 2>/dev/null | head -1)
  [ -z "$f" ] && { echo "No backup yet - run: ./scripts/backup.sh run"; return 1; }
  echo "== Restore test of $(basename "$f")"
  echo "  1. checksums of every stored file"
  for s in $DIR/db/*.sha256 $DIR/configs/*.sha256; do (cd "$(dirname "$s")" && sha256sum -c --quiet "$(basename "$s")") || rc=1; done
  [ $rc -eq 0 ] && echo "      all $(ls $DIR/db/*.sha256 $DIR/configs/*.sha256 | wc -l) files intact"
  echo "  2. restore from backup01's disk into a scratch MariaDB"
  check_dump "$f" "${f%.sql.gz}.meta" || rc=1
  echo "  3. read the copy back from the TrueNAS LUN (iSCSI) and restore it too"
  rm -rf /tmp/san-restore; mkdir -p /tmp/san-restore
  if timeout 120 qemu-img dd -f raw -O raw if="$LUN" of=/tmp/san-restore.img bs=1M count=$SAN_READ_MB 2>>/var/log/dc-backup.log \
     && tar -C /tmp/san-restore -xf /tmp/san-restore.img 2>/dev/null \
     && [ -f "/tmp/san-restore/db/$(basename "$f")" ]; then
    n=$(ls /tmp/san-restore/db/*.sql.gz | wc -l)
    (cd /tmp/san-restore/db && sha256sum -c --quiet "$(basename "$f").sha256") && echo "      SAN copy holds $n database restore points, checksum OK" || rc=1
    check_dump "/tmp/san-restore/db/$(basename "$f")" "/tmp/san-restore/db/$(basename "${f%.sql.gz}").meta" || rc=1
  else
    echo "      FAILED - the latest backup is not on the SAN (TrueNAS down, or run a backup first)"; rc=1
  fi
  rm -rf /tmp/san-restore /tmp/san-restore.img
  [ $rc -eq 0 ] && echo "== Restore test PASSED" || echo "== Restore test FAILED"
  return $rc
}

status() {  # exit 0 if the last database backup is < 26 h old and its checksum is valid
  local f age
  f=$(ls -1t $DIR/db/shop-*.sql.gz 2>/dev/null | head -1)
  [ -z "$f" ] && { echo "no backup yet"; return 1; }
  age=$(( $(date +%s) - $(stat -c %Y "$f") ))
  (cd $DIR/db && sha256sum -c --quiet "$(basename "$f").sha256") || return 1
  echo "last backup $(basename "$f"), $((age / 60)) min ago, checksum OK"
  [ $age -lt 93600 ]
}

list() {
  echo "== Database dumps (newest first, $KEEP kept)"; ls -1sht $DIR/db/*.sql.gz 2>/dev/null | sed 's|/srv/backup/db/||'
  echo "== Switch configurations"; ls -1sht $DIR/configs/*.tar.gz 2>/dev/null | sed 's|/srv/backup/configs/||'
  echo "== Log (last 10 lines)"; tail -10 /var/log/dc-backup.log 2>/dev/null
}

schedule() {  # first backup 6 min after deploy (TrueNAS boot), then every day at 02:00
  sleep 360; run >/dev/null 2>&1
  while true; do
    next=$(date -d 'tomorrow 02:00' +%s); [ "$(date +%H)" -lt 2 ] && next=$(date -d 'today 02:00' +%s)
    sleep $(( next - $(date +%s) )); run >/dev/null 2>&1
  done
}

case "$1" in
  run|list|status|schedule) "$1" ;;
  restore-test) restore_test ;;
  *) sed -n '2,6p' "$0"; exit 1 ;;
esac
