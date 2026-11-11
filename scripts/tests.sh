#!/usr/bin/env bash
# Demo / verification script. Run from the lab folder after deploy:
#   ./scripts/tests.sh            -> all functional tests
#   ./scripts/tests.sh failover   -> ISP, core, firewall, website, intranet and DNS failover demo
#   ./scripts/tests.sh loadshare  -> core load sharing demo (which core routes which VLAN)
#   ./scripts/tests.sh monitoring -> Zabbix alarms demo: cooling failure, power failure, firewall drop log
cd "$(dirname "$0")/.."
P=clab-mini-dc
[ -f lab.env ] && . ./lab.env          # passwords (scripts/gen-secrets.sh)
WWW="--cacert /lab/pki/ca.crt --resolve www.dc.lab:443"   # + :<public IP of an edge>
x()   { timeout 15 docker exec "$P-$1" "${@:2}"; }
eos() { docker exec "$P-$1" Cli -p 15 -c "$2"; }
ok=0; ko=0
check() {  # check "description" expected(pass|block) command...
  local d="$1" want="$2"; shift 2
  if "$@" >/dev/null 2>&1; then got=pass; else got=block; fi
  if [ "$got" = "$want" ]; then echo "  [OK]   $d"; ok=$((ok+1)); else echo "  [FAIL] $d (got $got, wanted $want)"; ko=$((ko+1)); fi
}

functional() {
  echo "== Core layer"
  eos core-01 "show vrrp brief"
  eos core-01 "show port-channel dense"
  eos core-01 "show spanning-tree root" | head -8
  eos core-01 "show ip ospf neighbor"
  eos core-01 "show ip route 0.0.0.0/0"
  echo "-- firewalls: OSPF neighbors fw-01 / fw-02, DMZ gateway owner"
  echo "   fw-01: $(x fw-01 vtysh -c 'show ip ospf neighbor' | grep -c Full) Full · fw-02: $(x fw-02 vtysh -c 'show ip ospf neighbor' | grep -c Full) Full"
  echo "   10.10.60.1 on: $(for f in fw-01 fw-02; do x $f ip -4 addr show eth5 | grep -q '10.10.60.1/' && echo $f; done)" \
       "· BFD sessions up on fw-01: $(x fw-01 vtysh -c 'show bfd peers brief' | grep -ci ' up ')"

  echo; echo "== Connectivity"
  check "web01 -> its gateway (VRRP VIP)"            pass x web01 ping -c1 -W1 10.10.20.1
  check "web01 -> db01 (same VLAN, other rack)"      pass x web01 ping -c1 -W1 10.10.20.30
  check "pc-01 -> web01 intranet (HTTP allowed)"     pass x pc-01 curl -sf -m3 http://10.10.20.10
  check "pc-01 -> intranet.dc.lab (virtual IP)"       pass x pc-01 curl -sf -m3 http://intranet.dc.lab
  check "pc-01 -> app.dc.lab:8080 (virtual IP)"       pass x pc-01 curl -sf -m3 http://app.dc.lab:8080/index.json
  check "pc-01 -> db01:3306 (blocked, host firewall)" block x pc-01 nc -z -w2 10.10.20.30 3306
  check "pc-01 -> db02:3306 (blocked, host firewall)" block x pc-01 nc -z -w2 10.10.20.31 3306
  check "backup01 -> app01:8080 (blocked, host firewall)" block x backup01 nc -z -w2 10.10.20.20 8080
  check "noc-ws -> fw-01 (routed through core)"      pass x noc-ws ping -c1 -W1 10.10.99.1
  check "web01 -> Internet (via FW, edge, ISP)"      pass x web01 curl -sf -m5 -o /dev/null https://example.com

  echo; echo "== DNS"
  check "dns01 resolves db01.dc.lab"                 pass x web01 sh -c 'dig +short db01.dc.lab | grep -q 10.10.20.30'
  check "dns01 forwards Internet names"              pass x web01 sh -c 'dig +short example.com | grep -q .'
  check "ad01 (secondary DNS) holds the dc.lab zone" pass x web01 sh -c 'dig +short @10.10.20.50 db01.dc.lab | grep -q 10.10.20.30'

  echo; echo "== DMZ & firewall"
  check "Internet -> ISP A -> https://www.dc.lab (valid TLS)" pass x isp-a curl -sf -m5 $WWW:10.0.0.1 https://www.dc.lab
  check "Internet -> ISP B -> https://www.dc.lab (valid TLS)" pass x isp-b curl -sf -m5 $WWW:10.0.0.5 https://www.dc.lab
  check "HTTP is redirected to HTTPS (301)"          pass x isp-a sh -c "curl -s -o /dev/null -w '%{http_code}' -m3 http://10.0.0.1 | grep -q 301"
  check "Load balancer uses both DMZ web servers"    pass x isp-a sh -c "for i in 1 2 3 4 5 6; do curl -s -m3 $WWW:10.0.0.1 https://www.dc.lab; done | grep -o 'served by web-dmz0[12]' | sort -u | wc -l | grep -q 2"
  check "Internet cannot reach internal IPs"         block x isp-a curl -sf -m3 http://10.10.20.10
  check "DMZ web -> MariaDB via db VIP (allowed)"    pass x web-dmz01 mariadb -h 10.10.20.35 -u web -p"$DB_WEB_PASS" shop -e 'select 1'
  check "DMZ web -> web01:80 (pivot blocked)"        block x web-dmz01 curl -sf -m3 http://10.10.20.10
  check "DMZ web -> storage01 (blocked)"             block x web-dmz01 ping -c1 -W1 10.10.30.10

  echo; echo "== SAN (iSCSI)"
  check "db01 sees its iSCSI target"                 pass x db01 sh -c 'iscsi-ls -s iscsi://10.10.30.10 | grep -q storage01.db'
  check "db01 reads LUN capacity"                    pass x db01 iscsi-readcapacity16 iscsi://10.10.30.10/iqn.2026-09.lab.dc:storage01.db/1
  check "db01 -> backup LUN (ACL denies)"            block x db01 iscsi-readcapacity16 iscsi://10.10.30.10/iqn.2026-09.lab.dc:storage01.backup/1
  check "backup01 reads its backup LUN"              pass x backup01 iscsi-readcapacity16 iscsi://10.10.30.10/iqn.2026-09.lab.dc:storage01.backup/1
  check "storage VLAN not routed (web01 -> SAN)"     block x web01 ping -c1 -W1 10.10.30.10

  echo; echo "== Backup"
  check "backup01 has a fresh backup, checksum valid" pass x backup01 bash /lab/scripts/backup.sh status

  echo; echo "== Firewall pair"
  check "fw-02 standby: OSPF Full with 2 edges + 2 cores" pass x fw-02 sh -c "vtysh -c 'show ip ospf neighbor' | grep -c Full | grep -qx 4"
  check "fw-01 owns the DMZ gateway 10.10.60.1"      pass x fw-01 sh -c "ip -4 addr show eth5 | grep -q '10.10.60.1/'"
  check "BFD up on fw-01 (2 edges + 2 cores)"        pass x fw-01 sh -c "vtysh -c 'show bfd peers brief' | grep -ci ' up ' | grep -qx 4"
  check "fw-02 holds fw-01's connections (conntrackd)" pass x fw-02 sh -c "conntrack -L 2>/dev/null | grep -q 'dport=3306'"

  echo; echo "== NOC & monitoring"
  check "syslog01 receives logs from the switches"   pass x syslog01 sh -c 'ls /var/log/remote/ | grep -qi core'
  check "noc-ws (2nd collector) receives them too"   pass x noc-ws sh -c 'ls /var/log/remote/ | grep -qi core'
  check "firewall drops logged on both collectors"   pass x syslog01 sh -c 'grep -q "FW DROP" /var/log/remote/fw-01.log'
  check "servers' logs reach the collectors (db01)"  pass x noc-ws sh -c 'ls /var/log/remote/ | grep -q db01'
  check "web01 clock synchronised to dns01/ad01 (NTP)" pass x web01 sh -c "chronyc -c tracking | grep -q ',Normal$'"
  check "Zabbix agents answer over OOB (web01, fw-01)" pass x monitor01 sh -c 'zabbix_get -s 10.10.10.101 -k agent.ping | grep -qx 1 && zabbix_get -s 10.10.10.40 -k dc.ospf.full | grep -qx 4'
  check "Zabbix reads the BMS sensors (hall A)"      pass x monitor01 sh -c "zabbix_get -s 10.10.10.117 -k 'bms.sensor[hall_a_temp]' | grep -Eq '^[0-9]'"
  check "Zabbix: no active problem"                  pass python3 scripts/zabbix-setup.py problems

  echo; echo "Result: $ok passed, $ko failed"
}

failover() {
  echo "== ISP failover: cut ISP A while web01 pings the Internet side (10.0.0.2 / 10.0.0.6)"
  docker exec $P-web01 sh -c 'ping -i 0.2 -c 100 -W 1 1.1.1.1 > /tmp/isp.log 2>&1' &
  sleep 3
  x edge-r1 ip link set eth1 down; echo "   ISP A link cut at $(date +%T)"
  sleep 5
  x fw-01 vtysh -c "show ip route 0.0.0.0/0" 2>/dev/null | grep -E "via"
  x web01 traceroute -n -w1 -q1 -m5 1.1.1.1 | tail -3
  x edge-r1 ip link set eth1 up; sleep 6
  echo "   restored -> $(x fw-01 vtysh -c 'show ip route 0.0.0.0/0' 2>/dev/null | grep via)"
  wait
  echo "   web01 ping summary: $(x web01 grep 'packet loss' /tmp/isp.log)"

  echo; echo "== Core failover: shut CORE-01 Vlan20 (VRRP master) while web01 pings its gateway"
  docker exec $P-web01 sh -c 'ping -i 0.2 -c 75 -W 1 10.10.20.1 > /tmp/vrrp.log 2>&1' &
  sleep 3
  eos core-01 "configure
interface Vlan20
shutdown" >/dev/null; echo "   core-01 Vlan20 shut at $(date +%T)"
  sleep 5; eos core-02 "show vrrp brief" | grep -E "Interface|Vl20"
  eos core-01 "configure
interface Vlan20
no shutdown" >/dev/null; echo "   core-01 Vlan20 restored (preempts back to MASTER)"
  wait
  echo "   web01 ping summary: $(x web01 grep 'packet loss' /tmp/vrrp.log)"
  echo "   (a few lost pings = the failover time, then traffic continues through core-02)"

  echo; echo "== Firewall failover: cut all of FW-01's cables while web01 pings the Internet and downloads from ISP A"
  x isp-a sh -c 'pkill -x iperf3; iperf3 -s -D'
  docker exec $P-web01 sh -c 'ping -i 0.2 -c 100 -W 1 1.1.1.1 > /tmp/fw.log 2>&1' &
  docker exec $P-web01 sh -c 'iperf3 -c 10.0.0.2 -R -t 15 -b 20M -i 1 > /tmp/iperf.log 2>&1' &
  sleep 3
  for i in 1 2 3 4 5; do x fw-01 ip link set eth$i down; done; echo "   fw-01 isolated at $(date +%T)"
  sleep 6
  echo "   default route on core-01: $(eos core-01 'show ip route 0.0.0.0/0' | grep -o 'via 10.10.99.[0-9]*' | head -1) (10.10.99.13 = fw-02)"
  echo "   DMZ gateway now on: $(x fw-02 ip -4 addr show eth5 | grep -q '10.10.60.1/' && echo fw-02)"
  echo "   website during the outage: $(x isp-a curl -s -o /dev/null -w '%{http_code}' -m5 $WWW:10.0.0.1 https://www.dc.lab)"
  # graceful return: fw-01 advertises maximum cost until its 4 adjacencies are up, then takes the traffic back
  x fw-01 vtysh -c 'configure terminal' -c 'router ospf' -c 'max-metric router-lsa administrative' >/dev/null
  for i in 1 2 3 4 5; do x fw-01 ip link set eth$i up; done
  x fw-01 sh -c 'ip link set eth3 mtu 1500; ip link set eth4 mtu 1500'
  for i in $(seq 30); do [ "$(x fw-01 vtysh -c 'show ip ospf neighbor' | grep -c Full)" -ge 4 ] && break; sleep 1; done
  sleep 2
  x fw-01 vtysh -c 'configure terminal' -c 'router ospf' -c 'no max-metric router-lsa administrative' >/dev/null
  echo "   fw-01 restored gracefully (high OSPF cost until its 4 neighbors were Full, then it took the traffic back)"
  wait
  echo "   web01 ping summary: $(x web01 grep 'packet loss' /tmp/fw.log)"
  if x web01 grep -q 'iperf Done' /tmp/iperf.log; then
    echo "   TCP download through the firewalls: survived the failover (conntrackd)," \
         "$(x web01 grep -c ' 0.00 bits/sec' /tmp/iperf.log) s without data"
  else
    echo "   TCP download through the firewalls: BROKEN ($(x web01 tail -1 /tmp/iperf.log))"
  fi

  echo; echo "== Website failover: cut web-dmz01 (owner of www.dc.lab) while web01 pings the site's virtual IP"
  docker exec $P-web01 sh -c 'ping -i 0.2 -c 60 -W 1 10.10.60.20 > /tmp/www.log 2>&1' &
  sleep 3
  x web-dmz01 ip link set eth1 down; echo "   web-dmz01 cut at $(date +%T)"
  sleep 5
  echo "   www.dc.lab (10.10.60.20) now on: $(x web-dmz02 ip -4 addr show eth1 | grep -q '10.10.60.20/' && echo web-dmz02)"
  echo "   from the Internet meanwhile: HTTP $(x isp-a curl -s -o /dev/null -w '%{http_code}' -m5 $WWW:10.0.0.1 https://www.dc.lab)," \
       "$(x isp-a curl -s -m5 $WWW:10.0.0.1 https://www.dc.lab | grep -o 'served by web-dmz0[12]')"
  # link down deletes the default route; a real server would re-run its network setup when it comes back
  x web-dmz01 sh -c 'ip link set eth1 up; ip route replace default via 10.10.60.1'
  echo "   web-dmz01 restored (takes the virtual IP back)"
  wait
  echo "   web01 ping summary: $(x web01 grep 'packet loss' /tmp/www.log)"

  echo; echo "== Intranet failover: cut web01 (rack A) while pc-01 pings intranet.dc.lab (10.10.20.12)"
  docker exec $P-pc-01 sh -c 'ping -i 0.2 -c 50 -W 1 10.10.20.12 > /tmp/intra.log 2>&1' &
  sleep 3
  x web01 ip link set eth1 down; echo "   web01 cut at $(date +%T)"
  sleep 3
  echo "   intranet now served by: $(x pc-01 curl -s -m3 http://intranet.dc.lab | grep -o '<h1[^>]*>[^<]*' | sed 's/.*>//')"
  x web01 sh -c 'ip link set eth1 up; ip route replace default via 10.10.20.1'
  echo "   web01 restored (takes the virtual IP back)"
  wait
  echo "   pc-01 ping summary: $(x pc-01 grep 'packet loss' /tmp/intra.log)"

  echo; echo "== DNS failover: stop the primary DNS (dns01) and resolve a name from web01"
  x dns01 pkill -x named; sleep 1
  t0=$(date +%s%N); ans=$(x web01 getent hosts db01.dc.lab | awk '{print $1}'); t1=$(date +%s%N)
  echo "   db01.dc.lab -> ${ans:-NO ANSWER} in $(( (t1 - t0) / 1000000 )) ms (answered by ad01, the secondary)"
  x dns01 named -u bind -4; echo "   dns01 restarted"
}

# Unicast packets a core received on some ports (cEOS does not answer traceroute, so we count packets)
pk() { eos "$1" "show interfaces $2 counters incoming" | awk 'NR>1 {s+=$3} END {print s+0}'; }
# Send 200 pings from a host to fw-01 and show which core received them on the given access-side ports
who_routes() {  # who_routes host ports label
  local a1 a2 b1 b2
  a1=$(pk core-01 "$2"); a2=$(pk core-02 "$2")
  x "$1" ping -q -c 200 -i 0.01 -W1 10.10.99.1 >/dev/null
  sleep 6   # cEOS refreshes interface counters every few seconds
  b1=$(pk core-01 "$2"); b2=$(pk core-02 "$2")
  printf "   %-8s (%s): core-01 received %4d packets, core-02 received %4d\n" "$1" "$3" $((b1-a1)) $((b2-a2))
}

loadshare() {
  echo "== VRRP: each core is master for half of the VLANs"
  echo "-- core-01"; eos core-01 "show vrrp brief"
  echo "-- core-02"; eos core-02 "show vrrp brief"

  echo; echo "== Spanning tree roots (instance 0 = VLAN 50/70, instance 1 = VLAN 20/40)"
  eos core-01 "show spanning-tree root"

  echo; echo "== Which core carries the traffic (200 pings to fw-01 from each host)"
  who_routes web01 Ethernet3-4 "servers VLAN 20"
  who_routes pc-01 Ethernet6-7 "users VLAN 50"

  echo; echo "== Failover: shut CORE-02 Vlan50 (master for users) while pc-01 pings its gateway"
  docker exec $P-pc-01 sh -c 'ping -i 0.2 -c 75 -W 1 10.10.50.1 > /tmp/ls.log 2>&1' &
  sleep 3
  eos core-02 "configure
interface Vlan50
shutdown" >/dev/null; echo "   core-02 Vlan50 shut at $(date +%T)"
  sleep 6
  eos core-01 "show vrrp brief" | grep -E "Interface|Vl50" | sed 's/^/   core-01: /'
  eos core-02 "configure
interface Vlan50
no shutdown" >/dev/null; echo "   core-02 Vlan50 restored (preempts back to MASTER)"
  wait
  echo "   pc-01 ping summary: $(x pc-01 grep 'packet loss' /tmp/ls.log)"
  echo "   (a few lost pings = the failover time; core-01 routed the users until core-02 came back)"
}

monitoring() {
  zbx() { python3 scripts/zabbix-setup.py problems; }
  echo "== Zabbix problems before the demo"; zbx
  echo; echo "== Cooling failure: hall A loses its 3 CRAH units (BMS simulation, bms01)"
  ./scripts/facility.sh cooling-failure
  for i in 1 2 3 4 5 6; do sleep 10; echo "   +$((i * 10)) s  hall A: $(x bms01 cat /var/lib/bms/hall_a_temp) °C"; done
  echo "-- Zabbix now:"; zbx
  ./scripts/facility.sh restore >/dev/null

  echo; echo "== Power failure: utility feed A lost AND generator A does not start"
  ./scripts/facility.sh generator-failure
  for i in 1 2 3 4 5 6 7; do sleep 10; echo "   +$((i * 10)) s  UPS A on battery: $(x bms01 cat /var/lib/bms/ups_a_on_battery)" \
       " battery: $(x bms01 cat /var/lib/bms/ups_a_batt_pct) %  path A output: $(x bms01 cat /var/lib/bms/ups_a_output)" \
       " UPS B load: $(x bms01 cat /var/lib/bms/ups_b_load_pct) %"; done
  echo "-- Zabbix now (the IT keeps running on path B - that is what 2N is for):"; zbx
  ./scripts/facility.sh restore >/dev/null

  echo; echo "== Security event: a DMZ server tries to reach the intranet (blocked and logged centrally)"
  x web-dmz01 curl -s -m2 http://10.10.20.10 >/dev/null; sleep 2
  echo "   syslog01: $(x syslog01 sh -c 'grep "FW DROP" /var/log/remote/fw-01.log | tail -1' | cut -c1-160)"

  echo; echo "== Waiting 60 s for everything to recover..."; sleep 60; zbx
}

case "$1" in failover) failover ;; loadshare) loadshare ;; monitoring) monitoring ;; *) functional ;; esac
