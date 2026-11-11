#!/bin/bash
# Building management system (BMS) simulator for the physical part of the data center, which containers
# cannot emulate: utility feeds, UPS, generators, cooling and the two server halls. Runs on bms01; Zabbix
# reads every sensor through the agent (bms.sensor[<name>]) and raises alarms. From WSL:
#   ./scripts/facility.sh status              current sensor values
#   ./scripts/facility.sh cooling-failure     hall A loses its 3 CRAH units: temperature climbs
#   ./scripts/facility.sh power-failure       utility feed A lost: UPS A on battery, generator A starts after 10 s
#   ./scripts/facility.sh generator-failure   feed A lost AND generator A fails: battery A runs out, path A goes down
#   ./scripts/facility.sh restore             back to normal
# Values follow the design report (chapter 3): 2 x 120 kVA UPS (2N), 2 x 250 kVA generators, ~25 kW IT load.
[ "$(hostname)" != bms01 ] && exec docker exec clab-mini-dc-bms01 bash /lab/scripts/facility.sh "$@"
D=/var/lib/bms
mkdir -p $D
set_val() { echo "$2" > "$D/$1"; }
get() { cat "$D/$1" 2>/dev/null || echo "$2"; }
noise() { awk -v b="$1" -v r="$2" -v s="$RANDOM" 'BEGIN {srand(s); printf "%.1f", b + (rand() * 2 - 1) * r}'; }
event() { logger -t bms "$*"; echo "$*"; }   # to syslog -> both NOC collectors

step() {   # one 5-second simulation step
  local sc t temp_a batt_a
  sc=$(get scenario normal); t=$(( $(get scenario_t 0) + 5 )); set_val scenario_t $t
  set_val it_power_kw "$(noise 25 0.6)"
  set_val hall_b_temp "$(noise 22.4 0.3)"; set_val hall_b_rh "$(noise 45 1.5)"
  set_val ups_b_load_pct "$(noise 11.6 0.4)"; set_val ups_b_on_battery 0; set_val ups_b_batt_pct 100; set_val ups_b_output 1
  set_val utility_b_ok 1; set_val gen_b_running 0; set_val crah_hall_b_running 3; set_val chiller_b_on 1; set_val chiller_a_on 1

  # hall A cooling
  temp_a=$(get hall_a_temp 22)
  if [ "$sc" = cooling-failure ]; then
    set_val crah_hall_a_running 0
    temp_a=$(awk -v x="$temp_a" 'BEGIN {x += 1.0; if (x > 38) x = 38; printf "%.1f", x}')
  else
    set_val crah_hall_a_running 3
    temp_a=$(awk -v x="$temp_a" -v n="$(noise 22 0.3)" 'BEGIN {x = (x > 23) ? x - 1.0 : n; printf "%.1f", x}')
  fi
  set_val hall_a_temp "$temp_a"; set_val hall_a_rh "$(noise 45 1.5)"

  # power path A
  batt_a=$(get ups_a_batt_pct 100)
  case "$sc" in
    power-failure|generator-failure)
      set_val utility_a_ok 0
      if [ "$sc" = power-failure ] && [ $t -ge 10 ]; then          # generator up after 10 s, UPS back on mains input
        set_val gen_a_running 1; set_val ups_a_on_battery 0; set_val ups_a_output 1
        batt_a=$(awk -v x="$batt_a" 'BEGIN {x += 1; if (x > 100) x = 100; printf "%.0f", x}')
      else                                                           # no generator: battery drains (10 min sped up to ~1 min)
        set_val gen_a_running 0; set_val ups_a_on_battery 1
        batt_a=$(awk -v x="$batt_a" 'BEGIN {x -= 8; if (x < 0) x = 0; printf "%.0f", x}')
        if [ "$batt_a" = 0 ]; then set_val ups_a_output 0; else set_val ups_a_output 1; fi
      fi ;;
    *)
      set_val utility_a_ok 1; set_val gen_a_running 0; set_val ups_a_on_battery 0; set_val ups_a_output 1
      batt_a=$(awk -v x="$batt_a" 'BEGIN {x += 10; if (x > 100) x = 100; printf "%.0f", x}') ;;   # recharge (sped up)
  esac
  set_val ups_a_batt_pct "$batt_a"
  # 2N: when path A is down, path B carries the whole IT load
  if [ "$(get ups_a_output 1)" = 0 ]; then set_val ups_a_load_pct 0; set_val ups_b_load_pct "$(noise 23.2 0.6)"
  else set_val ups_a_load_pct "$(noise 11.6 0.4)"; fi
  set_val pue "$(noise 1.6 0.03)"
}

run() {   # daemon started by init-host.sh on bms01
  set_val scenario normal; set_val scenario_t 0
  while true; do step; sleep 5; done
}

scenario() {
  set_val scenario "$1"; set_val scenario_t 0
  event "BMS: scenario $1 started"
}

status() {
  printf '%-22s %s\n' scenario "$(get scenario normal)"
  for s in utility_a_ok utility_b_ok ups_a_on_battery ups_a_batt_pct ups_a_output ups_a_load_pct ups_b_load_pct \
           gen_a_running crah_hall_a_running hall_a_temp hall_b_temp hall_a_rh it_power_kw pue; do
    printf '%-22s %s\n' "$s" "$(get $s -)"
  done
}

case "$1" in
  run) run ;;
  status) status ;;
  cooling-failure|power-failure|generator-failure) scenario "$1" ;;
  restore) scenario normal ;;
  *) sed -n '2,11p' "$0"; exit 1 ;;
esac
