#!/usr/bin/env bash
# One-time setup: builds the two lab images and checks the Arista cEOS image.
# Run inside the WSL-Containerlab distro, from the lab folder:  ./setup.sh
set -e
cd "$(dirname "$0")"

echo "[0/3] Checking kernel limits for cEOS..."
if [ "$(sysctl -n fs.inotify.max_user_instances)" -lt 8192 ]; then
  echo "      raising fs.inotify limits (sudo password may be asked)"
  printf 'fs.inotify.max_user_instances=8192\nfs.inotify.max_user_watches=1048576\n' | sudo tee /etc/sysctl.d/99-containerlab.conf >/dev/null
  sudo sysctl --system >/dev/null
fi

echo "[1/3] Building dc-router (FRR + nftables)..."
docker build -t dc-router:latest images/dc-router

echo "[2/3] Building dc-host (servers & PCs)..."
docker build -t dc-host:latest images/dc-host

echo "[3/3] Checking the Arista cEOS image..."
if docker image inspect ceos:latest >/dev/null 2>&1; then
  echo "      ceos:latest found."
else
  cat <<MSG
      ceos:latest NOT found. Download cEOS-lab from arista.com (free account):
        Software Downloads -> cEOS-lab -> cEOS64-lab-<version>.tar.xz
      then import it:
        docker import cEOS64-lab-<version>.tar.xz ceos:latest
MSG
  exit 1
fi

echo
echo "Pre-pulling monitoring images (Zabbix + PostgreSQL)..."
docker pull postgres:16-alpine
docker pull zabbix/zabbix-server-pgsql:alpine-7.0-latest
docker pull zabbix/zabbix-web-nginx-pgsql:alpine-7.0-latest

echo
echo "Ready. Deploy with:  ./deploy.sh"
