#!/usr/bin/env bash
# Deploys the lab. Same as `containerlab deploy -t mini-dc.clab.yml`, plus a watcher:
# on WSL a cEOS switch sometimes boots into systemd "rescue mode" and never starts EOS.
# The watcher detects it and continues the boot (systemctl default) automatically.
cd "$(dirname "$0")"
P=clab-mini-dc

# An old copy of the lab (e.g. Docker restarted it after a reboot) cannot be reused: its cables are gone.
if [ -n "$(docker ps -aq --filter "name=^$P-")" ]; then
  echo "[deploy.sh] An old copy of the lab exists ($(docker ps -q --filter "name=^$P-" | wc -l) of" \
       "$(docker ps -aq --filter "name=^$P-" | wc -l) containers running) - it must be destroyed first."
  read -r -p "[deploy.sh] Destroy it and deploy a fresh lab? [y/N] " ans
  case "$ans" in
    [yY]*) containerlab destroy -t mini-dc.clab.yml --cleanup || exit 1 ;;
    *) echo "Nothing done. To remove it yourself: containerlab destroy -t mini-dc.clab.yml --cleanup"; exit 1 ;;
  esac
fi

# Per-machine secrets (random passwords + TLS certificates), created on the first deploy, never committed.
bash scripts/gen-secrets.sh || exit 1
set -a; . ./lab.env; set +a                     # the topology reads ${ZBX_DB_PASS} etc.

(
  declare -A fixed
  for _ in $(seq 1 120); do                       # watch for up to 20 minutes
    for n in core-01 core-02 tor-01 tor-02; do
      [ -n "${fixed[$n]}" ] && continue
      if docker logs --tail 30 "$P-$n" 2>/dev/null | grep -q "You are in rescue mode"; then
        echo "[deploy.sh] $n booted into rescue mode -> continuing the boot"
        docker exec "$P-$n" systemctl default --no-block >/dev/null 2>&1
        fixed[$n]=1
      fi
    done
    sleep 10
  done
) &
WATCHER=$!
containerlab deploy -t mini-dc.clab.yml "$@" 2>&1 | tee deploy.log
rc=${PIPESTATUS[0]}
kill "$WATCHER" 2>/dev/null
echo
if [ "$rc" -ne 0 ]; then
  echo "[deploy.sh] Deploy FAILED (containerlab exit code $rc) - see the ERROR above and deploy.log."
  exit "$rc"
fi
echo "Deployed. Configuring Zabbix (hosts, checks, alarms, dashboard)..."
python3 scripts/zabbix-setup.py || echo "[deploy.sh] Zabbix setup failed - run python3 scripts/zabbix-setup.py again"
echo "Ready. Wait ~30 s for OSPF/STP to settle, then run: ./scripts/tests.sh"
