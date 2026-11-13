#!/usr/bin/env bash
# Runs every test of the lab and prints a short, readable report. The full output of each suite is kept
# in logs/tests-<date>/ for details.
#
#   ./scripts/test-all.sh              quick check, nothing is broken on purpose (~3 min):
#                                      lab health, 50 functional tests, backup restore test, database replication
#   ./scripts/test-all.sh full         everything (~15 min): quick check + core load sharing, failover drills
#                                      (ISP, core, firewall, website, intranet, DNS), database failover
#                                      (crash + server down, restored automatically), alarm demo, attack demo
#   ./scripts/test-all.sh <suite>...   chosen suites: health functional backup database loadshare
#                                      failover db-failover monitoring attack
#
# Exit code 0 when every suite passed.
cd "$(dirname "$0")/.." || exit 1
P=clab-mini-dc

QUICK=(health functional backup database)
FULL=(health functional backup database loadshare failover db-failover monitoring attack)
case "${1:-}" in
  ""|quick) SUITES=("${QUICK[@]}") ;;
  full)     SUITES=("${FULL[@]}") ;;
  -h|--help) sed -n '2,13p' "$0"; exit 0 ;;
  *)        SUITES=("$@") ;;
esac

LOG=logs/tests-$(date +%Y%m%d-%H%M%S); mkdir -p "$LOG"
if [ -t 1 ]; then G=$'\e[32m'; R=$'\e[31m'; Y=$'\e[33m'; B=$'\e[1m'; D=$'\e[2m'; N=$'\e[0m'; else G= R= Y= B= D= N=; fi
RESULTS=()          # "name|PASS/FAIL|detail|seconds"

line()  { printf "    %-34s %s\n" "$1" "$2"; }
ok()    { printf "%s✔%s" "$G" "$N"; }
ko()    { printf "%s✘%s" "$R" "$N"; }
mark()  { [ "$1" = 1 ] && ok || ko; }
dur()   { local s=$1; [ "$s" -ge 60 ] && printf "%dm%02ds" $((s / 60)) $((s % 60)) || printf "%ds" "$s"; }
loss()  { awk 'match($0, /([0-9]+) packets transmitted, ([0-9]+) received/, m) {print m[1] - m[2]; exit}' <<< "$1"; }

# run <log name> <command...> : runs quietly, shows a timer, keeps the output in the log
run() {
  local f="$LOG/$1.log"; shift
  "$@" > "$f" 2>&1 &
  local pid=$! t=0
  while kill -0 $pid 2>/dev/null; do
    [ -t 1 ] && printf "\r    %srunning… %s%s " "$D" "$(dur $t)" "$N"
    sleep 1; t=$((t + 1))
  done
  [ -t 1 ] && printf "\r\033[K"
  wait $pid
}

suite() {  # suite <title> <function>
  printf "\n%s▶ %s%s\n" "$B" "$1" "$N"
  local t0=$SECONDS
  STATUS=PASS; DETAIL=""
  "$2"
  local dt=$((SECONDS - t0))
  [ "$STATUS" = PASS ] && printf "    %s→ PASS%s  %s  %s(%s)%s\n" "$G" "$N" "$DETAIL" "$D" "$(dur $dt)" "$N" \
                       || printf "    %s→ FAIL%s  %s  %s(%s, see %s)%s\n" "$R" "$N" "$DETAIL" "$D" "$(dur $dt)" "$LOG" "$N"
  RESULTS+=("$1|$STATUS|$DETAIL|$dt")
}
fail() { STATUS=FAIL; }

# ---------------------------------------------------------------------------------------------- suites
t_health() {
  local name total up
  name=$(docker info --format '{{.Name}}' 2>/dev/null)
  if [ -z "$name" ]; then line "Docker" "$(ko) not reachable"; fail; DETAIL="Docker is not running"; return; fi
  [ "$name" = docker-desktop ] && { line "Docker engine" "$(ko) Docker Desktop took the socket (see troubleshooting)"; fail; }
  total=$(docker ps -a --filter "name=^$P-" --format '{{.Names}}' | wc -l)
  up=$(docker ps --filter "name=^$P-" --filter status=running --format '{{.Names}}' | wc -l)
  if [ "$total" -eq 0 ]; then line "Lab" "$(ko) not deployed - run ./deploy.sh"; fail; DETAIL="lab not deployed"; return; fi
  line "Containers running" "$(mark $([ "$up" -eq "$total" ] && echo 1)) $up / $total"
  [ "$up" -eq "$total" ] || fail
  local stopped; stopped=$(docker ps -a --filter "name=^$P-" --filter status=exited --format '{{.Names}}' | sed "s/^$P-//" | tr '\n' ' ')
  [ -n "$stopped" ] && line "Stopped" "$stopped"
  line "Secrets (lab.env)" "$(mark $([ -f lab.env ] && echo 1)) $([ -f lab.env ] && echo present || echo missing)"
  [ -f lab.env ] || fail
  DETAIL="$up/$total containers"
}

t_functional() {
  run functional ./scripts/tests.sh
  local f="$LOG/functional.log"
  # one line per section: "Connectivity 10/10", failed checks listed under it
  awk -v G="$G" -v R="$R" -v N="$N" '
    function flush() { if (sec != "" && tot > 0) printf "    %-34s %s %d / %d\n", sec, (pass == tot ? G "✔" N : R "✘" N), pass, tot
                       for (i = 1; i <= nf; i++) printf "        %s✘ %s%s\n", R, fails[i], N
                       tot = pass = nf = 0 }
    /^== / { flush(); sec = substr($0, 4); next }
    /^  \[OK\]/   { tot++; pass++ }
    /^  \[FAIL\]/ { tot++; sub(/^  \[FAIL\] +/, ""); fails[++nf] = $0 }
    END { flush() }' "$f"
  local res; res=$(grep -o 'Result: [0-9]* passed, [0-9]* failed' "$f")
  local p k; p=$(awk '{print $2}' <<< "$res"); k=$(awk '{print $4}' <<< "$res")
  [ -z "$res" ] && { fail; DETAIL="did not finish"; return; }
  [ "$k" -eq 0 ] || fail
  DETAIL="$p / $((p + k)) checks passed"
}

t_backup() {
  run backup ./scripts/backup.sh restore-test
  local f="$LOG/backup.log"
  local files san rows
  files=$(grep -o 'all [0-9]* files intact' "$f")
  san=$(grep -o 'SAN copy holds [0-9]* database restore points' "$f")
  rows=$(grep -c 'rows (as at backup time)' "$f")
  line "Checksums of stored files" "$(mark $([ -n "$files" ] && echo 1)) ${files:-failed}"
  line "Restore from backup01's disk" "$(mark $([ "$rows" -ge 1 ] && echo 1)) tables restored with the right row counts"
  line "Copy on the TrueNAS LUN" "$(mark $([ -n "$san" ] && echo 1)) ${san:-not found (TrueNAS booted? backup run?)}"
  grep -q 'Restore test PASSED' "$f" || { fail; grep -q 'No backup yet' "$f" && DETAIL="no backup yet: ./scripts/backup.sh run"; return; }
  DETAIL="last backup restored from disk and from the SAN"
}

t_database() {
  run database ./scripts/db-failover.sh status
  local f="$LOG/database.log" owner
  owner=$(sed -n 's/.*owned by: //p' "$f")
  line "Virtual IP 10.10.20.35 owner" "$(mark $([ -n "$owner" ] && [ "$owner" != NOBODY ] && echo 1)) ${owner:-none}"
  local replica_ok=0
  grep -q 'Slave_IO_Running: Yes.*Slave_SQL_Running: Yes' "$f" && replica_ok=1
  line "Replication to the replica" "$(mark $replica_ok) $([ $replica_ok = 1 ] && echo running || echo 'NOT running - ./scripts/db-failover.sh restore')"
  [ -n "$owner" ] && [ "$owner" != NOBODY ] && [ $replica_ok = 1 ] || fail
  DETAIL="primary $owner, replica in sync"
}

t_loadshare() {
  run loadshare ./scripts/tests.sh loadshare
  local f="$LOG/loadshare.log" w p l
  w=$(grep -E '^ +web01 +\(' "$f"); p=$(grep -E '^ +pc-01 +\(' "$f")
  read -r w1 w2 < <(sed -E 's/.*core-01 received +([0-9]+).*core-02 received +([0-9]+).*/\1 \2/' <<< "$w")
  read -r p1 p2 < <(sed -E 's/.*core-01 received +([0-9]+).*core-02 received +([0-9]+).*/\1 \2/' <<< "$p")
  local a=0 b=0
  [ "${w1:-0}" -gt "${w2:-0}" ] && a=1; [ "${p2:-0}" -gt "${p1:-0}" ] && b=1
  line "Servers (VLAN 20) routed by" "$(mark $a) core-01  ($w1 / $w2 packets)"
  line "Users (VLAN 50) routed by" "$(mark $b) core-02  ($p2 / $p1 packets)"
  l=$(loss "$(grep 'ping summary' "$f")")
  line "core-02 down: users' gateway" "$(mark $([ -n "$l" ] && [ "$l" -lt 25 ] && echo 1)) interruption ≈ $(awk -v n="${l:-0}" 'BEGIN{printf "%.1f", n*0.2}') s"
  [ $a = 1 ] && [ $b = 1 ] && [ -n "$l" ] && [ "$l" -lt 25 ] || fail
  DETAIL="each core routes half of the VLANs"
}

t_failover() {
  run failover ./scripts/tests.sh failover
  local f="$LOG/failover.log" worst=0 n=0
  # ping summaries appear in this order: ISP, core, firewall, website, intranet
  local names=("ISP A cut" "Core gateway (core-01 down)" "Firewall fw-01 isolated" "Website server cut" "Intranet server cut")
  mapfile -t sums < <(grep 'ping summary' "$f")
  for i in 0 1 2 3 4; do
    local l; l=$(loss "${sums[$i]:-}")
    if [ -z "$l" ]; then line "${names[$i]}" "$(ko) no measurement"; fail; continue; fi
    local s; s=$(awk -v n="$l" 'BEGIN{printf "%.1f", n*0.2}')
    line "${names[$i]}" "$(mark $([ "$l" -lt 25 ] && echo 1)) interruption ≈ $s s"
    [ "$l" -lt 25 ] || fail; [ "$l" -gt "$worst" ] && worst=$l; n=$((n + 1))
  done
  if grep -q 'survived the failover' "$f"; then line "TCP download through the firewall" "$(ok) kept open (connection sync)"
  else line "TCP download through the firewall" "$(ko) broken"; fail; fi
  local dns; dns=$(grep -oE 'db01.dc.lab -> [0-9.]+ in [0-9]+ ms' "$f")
  if [ -n "$dns" ]; then line "Primary DNS stopped" "$(ok) answered by ad01 in ${dns##* in }"
  else line "Primary DNS stopped" "$(ko) no answer"; fail; fi
  DETAIL="$n failovers, worst ≈ $(awk -v n=$worst 'BEGIN{printf "%.1f", n*0.2}') s"
}

t_dbfailover() {
  local worst=0
  for mode in crash server; do
    run "db-failover-$mode" ./scripts/db-failover.sh "$mode"
    local f="$LOG/db-failover-$mode.log" t lost
    t=$(sed -nE 's/.*database unavailable: +([0-9.]+|never[^ ]*) s.*/\1/p' "$f")
    lost=$(grep -q 'no data lost' "$f" && echo 0 || echo 1)
    local label; [ $mode = crash ] && label="MariaDB crash on the primary" || label="Primary server offline"
    if [[ "$t" =~ ^[0-9.]+$ ]] && [ "$lost" = 0 ]; then
      line "$label" "$(ok) unavailable $t s, no data lost"
      awk -v a="$t" -v b="$worst" 'BEGIN{exit !(a>b)}' && worst=$t
    else
      line "$label" "$(ko) ${t:-no result}$([ "$lost" = 1 ] && echo ', DATA LOST?')"; fail
    fi
    run "db-restore-$mode" ./scripts/db-failover.sh restore
    if grep -q '^Done:' "$LOG/db-restore-$mode.log"; then line "  rebuilt as replica" "$(ok) redundant again"
    else line "  rebuilt as replica" "$(ko) restore failed"; fail; fi
  done
  DETAIL="worst ${worst} s, no data lost"
}

t_monitoring() {
  run monitoring ./scripts/tests.sh monitoring
  local f="$LOG/monitoring.log"
  # each "-- Zabbix now" block ends with "N active problem(s)"
  mapfile -t counts < <(grep -oE '[0-9]+ active problem' "$f" | awk '{print $1}')
  local maxt; maxt=$(grep -oE 'hall A: [0-9.]+' "$f" | awk '{print $3}' | sort -n | tail -1)
  local minb; minb=$(grep -oE 'battery: [0-9.]+' "$f" | awk '{print $2}' | sort -n | head -1)
  local c1=${counts[1]:-0} c2=${counts[2]:-0} last=${counts[${#counts[@]}-1]:-?}
  line "Cooling failure in hall A" "$(mark $([ "$c1" -gt 0 ] && echo 1)) up to ${maxt:-?} °C, $c1 alarm(s) raised"
  line "Power failure, generator A fails" "$(mark $([ "$c2" -gt 0 ] && echo 1)) UPS A down to ${minb:-?} %, $c2 alarm(s), path B carries the IT"
  local drop=0; grep -q 'syslog01: .*FW DROP' "$f" && drop=1
  line "Blocked DMZ -> intranet attempt" "$(mark $drop) $([ $drop = 1 ] && echo 'logged on the NOC collector' || echo 'not logged')"
  local rec; rec=$(awk '/Waiting 60 s/{f=1} f && /AVERAGE|HIGH|DISASTER/{n++} END{print n+0}' "$f")
  line "After recovery" "$(mark $([ "$rec" -eq 0 ] && echo 1)) $last active problem(s), $rec serious"
  [ "$c1" -gt 0 ] && [ "$c2" -gt 0 ] && [ $drop = 1 ] && [ "$rec" -eq 0 ] || fail
  DETAIL="alarms raised and cleared"
}

t_attack() {
  run attack ./scripts/tests.sh attack
  local f="$LOG/attack.log" names=("Web attack (SQLi, traversal, nikto)" "Port scan (nmap)" "SSH brute force (hydra)")
  # status lines only ("== website from the attacker: ..."), not the "blocklists cleared" line printed after each unblock
  mapfile -t st < <(grep -oE '^== website from the attacker: [A-Za-z]+' "$f" | awk '{print $NF}')
  local i blocked=0
  for i in 0 1 2; do
    local s=${st[$i]:-?}
    line "${names[$i]}" "$(mark $([ "$s" = BLOCKED ] && echo 1)) $([ "$s" = BLOCKED ] && echo 'detected, attacker blocked' || echo "attacker NOT blocked ($s)")"
    [ "$s" = BLOCKED ] && blocked=$((blocked + 1))
  done
  local z; z=$(grep -c 'IDS: attack detected' "$f")
  line "Zabbix alarm" "$(mark $([ "$z" -gt 0 ] && echo 1)) $([ "$z" -gt 0 ] && echo 'raised' || echo 'missing')"
  [ $blocked = 3 ] && [ "$z" -gt 0 ] || fail
  DETAIL="$blocked / 3 attacks blocked"
}

# ---------------------------------------------------------------------------------------------- main
declare -A TITLE=([health]="Lab health" [functional]="Functional tests" [backup]="Backup restore test"
  [database]="Database replication" [loadshare]="Core load sharing" [failover]="Failover drills"
  [db-failover]="Database failover" [monitoring]="Alarm demo (BMS + Zabbix)" [attack]="Attack demo (IDS)")
declare -A FUNC=([health]=t_health [functional]=t_functional [backup]=t_backup [database]=t_database
  [loadshare]=t_loadshare [failover]=t_failover [db-failover]=t_dbfailover [monitoring]=t_monitoring [attack]=t_attack)
for s in "${SUITES[@]}"; do [ -n "${FUNC[$s]:-}" ] || { echo "unknown suite: $s (try --help)"; exit 2; }; done

printf "%sRAM+ Data Center - test run %s%s   %s(full logs: %s)%s\n" "$B" "$(date '+%F %H:%M')" "$N" "$D" "$LOG" "$N"
T0=$SECONDS
for s in "${SUITES[@]}"; do
  suite "${TITLE[$s]}" "${FUNC[$s]}"
  if [ "$s" = health ] && [ "$STATUS" = FAIL ] && grep -qE 'not deployed|not running|not reachable' <<< "$DETAIL"; then
    printf "\n%sStopping: the lab is not up.%s\n" "$R" "$N"; break
  fi
done

printf "\n%s%-30s %-6s %-8s %s%s\n" "$B" "Summary" "Result" "Time" "Details" "$N"
fails=0
for r in "${RESULTS[@]}"; do
  IFS='|' read -r name st det t <<< "$r"
  [ "$st" = PASS ] && c=$G || { c=$R; fails=$((fails + 1)); }
  printf "%-30s %s%-6s%s %-8s %s\n" "$name" "$c" "$st" "$N" "$(dur "$t")" "$det"
done
echo
if [ $fails -eq 0 ]; then printf "%s✔ All %d suites passed%s in %s\n" "$G" "${#RESULTS[@]}" "$N" "$(dur $((SECONDS - T0)))"
else printf "%s✘ %d of %d suites failed%s in %s - details in %s\n" "$R" $fails "${#RESULTS[@]}" "$N" "$(dur $((SECONDS - T0)))" "$LOG"; fi
exit $((fails > 0))
