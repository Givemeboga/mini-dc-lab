# Server / client image for every host in the lab.
# One image, many roles: scripts/init-host.sh starts the right service per node.
FROM debian:bookworm-slim
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
      iproute2 iputils-ping traceroute curl ca-certificates dnsutils tcpdump iperf3 \
      nftables procps nano less netcat-openbsd python3 snmp \
      nginx-light bind9 mariadb-server mariadb-client rsyslog \
      tgt libiscsi-bin \
 && rm -rf /var/lib/apt/lists/* \
 && rm -f /etc/nginx/sites-enabled/default.dpkg-dist
CMD ["sleep", "infinity"]
