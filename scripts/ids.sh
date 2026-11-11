#!/bin/sh
# Intrusion detection and automatic blocking at the Internet edge, run by init-router.sh on edge-r1 / edge-r2.
#   Suricata watches the WAN link (eth1), where the attacker's real address is still visible (behind the edges,
#   port-forwarded traffic is source-NATed). Every alert goes to syslog -> both NOC collectors.
#   Priority 1-2 alerts from an outside address put that address in the nftables set "blocklist" for 10 min:
#   the edge drops its packets before the port-forward (configs/nft/edge-r*.nft).
#   Zabbix reads /run/dc-ips/alerts (total alerts) and /run/dc-ips/blocked (addresses blocked now).
R=/var/lib/suricata/rules
mkdir -p $R /var/log/suricata /run/dc-ips
cat /etc/suricata/rules/et-selected.rules /lab/configs/suricata/dc-lab.rules > $R/dc.rules
echo 0 > /run/dc-ips/alerts; echo 0 > /run/dc-ips/blocked
: > /var/log/suricata/fast.log
suricata -D --af-packet=eth1 -l /var/log/suricata -S $R/dc.rules \
  --set "vars.address-groups.HOME_NET=[10.0.0.1,10.0.0.5,10.10.0.0/16]" </dev/null >/dev/null 2>&1

count_blocked() { nft list set inet edge blocklist 2>/dev/null | grep -oE '([0-9]+\.){3}[0-9]+' | wc -l > /run/dc-ips/blocked; }

( while sleep 10; do count_blocked; done ) </dev/null >/dev/null 2>&1 &

( tail -n0 -F /var/log/suricata/fast.log 2>/dev/null | while read -r line; do
    echo $(( $(cat /run/dc-ips/alerts) + 1 )) > /run/dc-ips/alerts
    logger -t suricata "$line"
    prio=$(echo "$line" | sed -n 's/.*\[Priority: \([0-9]*\)\].*/\1/p')
    src=$(echo "$line" | sed -n 's/.*} \([0-9][0-9.]*\)[: ].*->.*/\1/p')
    case "$src" in ""|10.*|127.*) continue ;; esac            # never block the lab's or the ISPs' own addresses
    [ "${prio:-3}" -le 2 ] || continue
    if ! nft get element inet edge blocklist "{ $src }" >/dev/null 2>&1; then
      nft add element inet edge blocklist "{ $src timeout 10m }"
      logger -t dc-ips "IPS: $src blocked for 10 min - $(echo "$line" | sed 's/.*\[\*\*\] \[[0-9:]*\] \(.*\) \[\*\*\].*/\1/')"
      count_blocked
    fi
  done ) </dev/null >/dev/null 2>&1 &
echo "[ids] $(hostname): Suricata on eth1 ($(wc -l < $R/dc.rules) rules), automatic blocking on"
