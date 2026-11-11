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
    sh /lab/scripts/init-ops.sh
    ;;
  fw-01|fw-02)
    ip route del default dev eth0 2>/dev/null
    # cEOS routed ports use MTU 1500; containerlab veths default to 9500.
    # OSPF refuses neighbors with different MTUs, so align the core-facing links.
    # Core links may appear later (staggered switch boot): wait for them.
    for i in $(seq 1 180); do [ -e /sys/class/net/eth3 ] && [ -e /sys/class/net/eth4 ] && break; sleep 1; done
    ip link set eth3 mtu 1500; ip link set eth4 mtu 1500
    nft -f /lab/configs/nft/fw-01.nft            # same policy on both firewalls
    # DMZ gateway 10.10.60.1 is a virtual IP: on fw-01, moves to fw-02 if fw-01 fails (VRRPv3 61, 0.2 s
    # adverts); a returning fw-01 waits 10 s (preempt_delay) so its routes are complete before it takes it back
    [ "$H" = fw-01 ] && PRIO=110 || PRIO=100
    mkdir -p /etc/keepalived
    cat > /etc/keepalived/keepalived.conf <<CONF
vrrp_instance DMZ_GW {
    version 3
    state BACKUP
    preempt_delay 10
    interface eth5
    virtual_router_id 61
    priority $PRIO
    advert_int 0.2
    virtual_ipaddress { 10.10.60.1/24 dev eth5 }
}
CONF
    keepalived -f /etc/keepalived/keepalived.conf </dev/null >/dev/null 2>&1
    # conntrackd copies every connection to the other firewall over the eth6 cable and writes the
    # other's straight into this kernel's table: after a failover, open connections keep working.
    [ "$H" = fw-01 ] && { ME=10.10.99.21; PEER=10.10.99.22; } || { ME=10.10.99.22; PEER=10.10.99.21; }
    cat > /etc/conntrackd.conf <<CONF
Sync {
    Mode FTFW {
        DisableExternalCache On
    }
    UDP {
        IPv4_address $ME
        IPv4_Destination_Address $PEER
        Port 3780
        Interface eth6
        Checksum on
    }
}
General {
    HashSize 8192
    HashLimit 65535
    LogFile off
    Syslog off
    LockFile /var/lock/conntrackd.lock
    UNIX {
        Path /var/run/conntrackd.ctl
    }
    NetlinkBufferSize 2097152
    NetlinkBufferSizeMaxGrowth 8388608
    Filter From Userspace {
        Address Ignore {
            IPv4_address 127.0.0.1
            IPv4_address $ME
            IPv4_address $PEER
        }
    }
}
CONF
    mkdir -p /var/lock /var/run
    # conntrackd binds to the sync address: wait until FRR has put it on eth6
    for i in $(seq 60); do ip -4 addr show eth6 2>/dev/null | grep -q "$ME/" && break; sleep 1; done
    conntrackd -d -C /etc/conntrackd.conf </dev/null >/dev/null 2>&1
    # dropped packets: nftables "log group 1" (NFLOG works inside a container, plain "log" does not)
    # -> ulogd -> syslog -> both NOC collectors (init-ops.sh)
    cat > /etc/ulogd.conf <<'CONF'
[global]
logfile="syslog"
loglevel=5
plugin="/usr/lib/ulogd/ulogd_inppkt_NFLOG.so"
plugin="/usr/lib/ulogd/ulogd_raw2packet_BASE.so"
plugin="/usr/lib/ulogd/ulogd_filter_IFINDEX.so"
plugin="/usr/lib/ulogd/ulogd_filter_IP2STR.so"
plugin="/usr/lib/ulogd/ulogd_filter_PRINTPKT.so"
plugin="/usr/lib/ulogd/ulogd_output_SYSLOG.so"
stack=log1:NFLOG,base1:BASE,ifi1:IFINDEX,ip2str1:IP2STR,print1:PRINTPKT,sys1:SYSLOG
[log1]
group=1
[sys1]
facility=LOG_LOCAL0
level=LOG_WARNING
CONF
    sh /lab/scripts/init-ops.sh
    ulogd -d -c /etc/ulogd.conf </dev/null >/dev/null 2>&1
    ;;
esac
echo "[init-router] $H done"
