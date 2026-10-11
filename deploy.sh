#!/usr/bin/env bash
# Deploys the lab. Same as `containerlab deploy -t mini-dc.clab.yml`, plus a watcher:
# on WSL a cEOS switch sometimes boots into systemd "rescue mode" and never starts EOS.
# The watcher detects it and continues the boot (systemctl default) automatically.
cd "$(dirname "$0")"
P=clab-mini-dc
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
kill "$WATCHER" 2>/dev/null
echo
echo "Deployed. Wait ~30 s for OSPF/STP to settle, then run: ./scripts/tests.sh"
