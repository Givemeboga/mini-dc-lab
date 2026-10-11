# Router / firewall image: FRRouting + nftables
# Used by: isp-a, isp-b, edge-r1, edge-r2, fw-01
FROM quay.io/frrouting/frr:10.1.0
RUN apk add --no-cache nftables tcpdump iperf3 curl conntrack-tools iproute2 bind-tools
