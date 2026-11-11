#!/bin/sh
# Runs inside isp-a, isp-b, edge-r1, edge-r2, fw-01 and fw-02 right after deploy.
H=$(hostname)
echo "[init-router] $H"

sysctl -w net.ipv4.ip_forward=1 >/dev/null
[ -f /etc/frr/vtysh.conf ] || echo "service integrated-vtysh-config" > /etc/frr/vtysh.conf
sysctl -w net.ipv4.conf.all.rp_filter=0 >/dev/null
sysctl -w net.ipv4.conf.default.rp_filter=0 >/dev/null

case "$H" in
  isp-a|isp-b)
    # ISPs keep Docker's default route (eth0) = the real Internet.
    [ "$H" = isp-a ] && IP=10.0.0.2/30 || IP=10.0.0.6/30
    ip link set eth1 up
    ip addr add "$IP" dev eth1 2>/dev/null
    nft -f /lab/configs/nft/isp.nft
    ;;
  edge-r1|edge-r2)
    # Remove Docker's default route via the management network so the
    # routing table only contains what FRR (static + OSPF) decides.
    ip route del default dev eth0 2>/dev/null
    nft -f /lab/configs/nft/$H.nft
    ;;
  fw-01|fw-02)
    ip route del default dev eth0 2>/dev/null
    # cEOS routed ports use MTU 1500; containerlab veths default to 9500.
    # OSPF refuses neighbors with different MTUs, so align the core-facing links.
    # Core links may appear later (staggered switch boot): wait for them.
    for i in $(seq 1 180); do [ -e /sys/class/net/eth3 ] && [ -e /sys/class/net/eth4 ] && break; sleep 1; done
    ip link set eth3 mtu 1500; ip link set eth4 mtu 1500
    nft -f /lab/configs/nft/fw-01.nft            # same policy on both firewalls
    # DMZ gateway 10.10.60.1 is a virtual IP: on fw-01, moves to fw-02 if fw-01 fails (VRRP 61)
    [ "$H" = fw-01 ] && PRIO=110 || PRIO=100
    mkdir -p /etc/keepalived
    cat > /etc/keepalived/keepalived.conf <<CONF
vrrp_instance DMZ_GW {
    state BACKUP
    interface eth5
    virtual_router_id 61
    priority $PRIO
    advert_int 1
    virtual_ipaddress { 10.10.60.1/24 dev eth5 }
}
CONF
    keepalived -f /etc/keepalived/keepalived.conf </dev/null >/dev/null 2>&1
    ;;
esac
echo "[init-router] $H done"
