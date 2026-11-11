#!/usr/bin/env bash
# Demo / verification script. Run from the lab folder after deploy:
#   ./scripts/tests.sh            -> all functional tests
#   ./scripts/tests.sh failover   -> ISP + core failover demo
#   ./scripts/tests.sh loadshare  -> core load sharing demo (which core routes which VLAN)
P=clab-mini-dc
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

  echo; echo "== Connectivity"
  check "web01 -> its gateway (VRRP VIP)"            pass x web01 ping -c1 -W1 10.10.20.1
  check "web01 -> db01 (same VLAN, other rack)"      pass x web01 ping -c1 -W1 10.10.20.30
  check "pc-01 -> web01 intranet (HTTP allowed)"     pass x pc-01 curl -sf -m3 http://10.10.20.10
  check "pc-01 -> db01:3306 (blocked, host firewall)" block x pc-01 nc -z -w2 10.10.20.30 3306
  check "noc-ws -> fw-01 (routed through core)"      pass x noc-ws ping -c1 -W1 10.10.99.1
  check "web01 -> Internet (via FW, edge, ISP)"      pass x web01 curl -sf -m5 -o /dev/null https://example.com

  echo; echo "== DNS"
  check "dns01 resolves db01.dc.lab"                 pass x web01 sh -c 'dig +short db01.dc.lab | grep -q 10.10.20.30'
  check "dns01 forwards Internet names"              pass x web01 sh -c 'dig +short example.com | grep -q .'

  echo; echo "== DMZ & firewall"
  check "Internet -> edge-r1:80 -> web-dmz01"        pass x isp-a curl -sf -m3 http://10.0.0.1
  check "Internet -> edge-r2:80 -> web-dmz02"        pass x isp-b curl -sf -m3 http://10.0.0.5
  check "Internet cannot reach internal IPs"         block x isp-a curl -sf -m3 http://10.10.20.10
  check "DMZ web -> MariaDB via db VIP (allowed)"    pass x web-dmz01 mariadb -h 10.10.20.35 -u web -pWebPass2026 shop -e 'select 1'
  check "DMZ web -> web01:80 (pivot blocked)"        block x web-dmz01 curl -sf -m3 http://10.10.20.10
  check "DMZ web -> storage01 (blocked)"             block x web-dmz01 ping -c1 -W1 10.10.30.10

  echo; echo "== SAN (iSCSI)"
  check "db01 sees its iSCSI target"                 pass x db01 sh -c 'iscsi-ls -s iscsi://10.10.30.10 | grep -q storage01.db'
  check "db01 reads LUN capacity"                    pass x db01 iscsi-readcapacity16 iscsi://10.10.30.10/iqn.2026-09.lab.dc:storage01.db/1
  check "db01 -> backup LUN (ACL denies)"            block x db01 iscsi-readcapacity16 iscsi://10.10.30.10/iqn.2026-09.lab.dc:storage01.backup/1
  check "backup01 reads its backup LUN"              pass x backup01 iscsi-readcapacity16 iscsi://10.10.30.10/iqn.2026-09.lab.dc:storage01.backup/1
  check "storage VLAN not routed (web01 -> SAN)"     block x web01 ping -c1 -W1 10.10.30.10

  echo; echo "== NOC"
  check "syslog01 receives logs from the switches"   pass x syslog01 sh -c 'ls /var/log/remote/ | grep -qi core'

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

case "$1" in failover) failover ;; loadshare) loadshare ;; *) functional ;; esac
