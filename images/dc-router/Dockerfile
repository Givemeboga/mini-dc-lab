# Router / firewall image: FRRouting + nftables
# Used by: isp-a, isp-b, edge-r1, edge-r2, fw-01, fw-02 (keepalived: shared DMZ gateway of the firewalls)
FROM quay.io/frrouting/frr:10.1.0
RUN apk add --no-cache nftables tcpdump iperf3 curl conntrack-tools iproute2 bind-tools keepalived zabbix-agent ulogd rsyslog suricata \
 && (suricata-update --no-test --no-reload -o /tmp/et >/dev/null 2>&1 || true) \
 && mkdir -p /etc/suricata/rules \
 && (grep -hE '^alert .*msg:"ET (SCAN|WEB_SERVER|EXPLOIT|ATTACK_RESPONSE|DOS) ' /tmp/et/suricata.rules \
       > /etc/suricata/rules/et-selected.rules || touch /etc/suricata/rules/et-selected.rules) \
 && rm -rf /tmp/et
