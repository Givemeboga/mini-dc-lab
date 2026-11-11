# Attacker for the security demo (scripts/attack.sh): Kali Linux with the usual tools, outside the data center
FROM kalilinux/kali-rolling
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
      nmap hydra nikto sqlmap curl iproute2 iputils-ping netcat-traditional ca-certificates \
 && rm -rf /var/lib/apt/lists/*
CMD ["sleep", "infinity"]
