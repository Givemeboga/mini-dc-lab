# Mini Data Center — Containerlab lab

School project (ESPRIT, cybersecurity & cloud engineering): a mini data center (network + buildings)
emulated with **Containerlab** on **Windows 11 Home → WSL2 Ubuntu 24.04** (no GNS3: nested
virtualization does not work on this machine). Everything runs as containers.

## Environment

- Host: Windows 11 Home, 32 GB RAM. WSL `.wslconfig`: `memory=16GB`, `processors=6`, `swap=4GB`.
- Lab lives in `~/projects/mini-dc-lab` (Linux FS). `C:\Projects\mini-dc-lab` is a symlink to it.
- User is in groups `docker` and `clab_admins` → run `containerlab` **without sudo**.
- Containerlab 0.79.0. Arista cEOS image imported as `ceos:latest` (cEOS64-lab-4.33.10M).
- `/etc/sysctl.d/99-containerlab.conf`: `fs.inotify.max_user_instances=8192`, `max_user_watches=1048576`.

## Layout

| Path | Purpose |
|---|---|
| `mini-dc.clab.yml` | Topology: 30 nodes, 34 links, mgmt network `dc-oob` 10.10.10.0/24 |
| `mini-dc.clab.yml.annotations.json` | TopoViewer layout (buildings, rooms, icons) — visual only |
| `configs/ceos/*.cfg` | Arista startup configs: core-01/02 (L3, VRRP, MSTP root, OSPF), tor-01/02 (L2) |
| `configs/frr/*.conf`, `daemons` | FRR for edge-r1/r2 and fw-01 (OSPF, static defaults) |
| `configs/nft/*.nft` | nftables: fw-01 policy, edge NAT/port-forward, ISP NAT, db01 host firewall |
| `scripts/init-router.sh` | exec for isp/edge/fw (sysctl, remove docker default route, MTU, nft) |
| `scripts/init-bridge.sh` | exec for Linux-bridge "switches" (`stp` arg for dual-homed ones) |
| `scripts/init-host.sh` | exec for every server/PC; role chosen by hostname (IPs, nginx, BIND, MariaDB, tgt iSCSI, rsyslog) |
| `scripts/tests.sh` | 20 functional checks; `tests.sh failover` = ISP + VRRP failover demo |
| `scripts/zabbix-add-hosts.py` | Registers devices in Zabbix via API (http://localhost:8080, Admin/zabbix) |
| `deploy.sh` | Wrapper around `containerlab deploy` + watcher that un-sticks cEOS rescue mode |
| `setup.sh` | Builds `dc-router` (FRR+nftables) and `dc-host` (Debian services) images |

## Commands

```bash
./deploy.sh                                          # start (5–8 min, silent while cEOS boots)
./scripts/tests.sh                                   # expect 20 passed
./scripts/tests.sh failover                          # ISP ≈0.2 s, VRRP ≈2.8 s measured
containerlab destroy -t mini-dc.clab.yml --cleanup   # stop
docker exec clab-mini-dc-core-01 Cli -p 15 -c "show vrrp brief"
docker exec -it clab-mini-dc-fw-01 vtysh
```

## Hard-won lessons (do not regress)

- **Never Ctrl+C a deploy** — it destroys the lab. It is silent for minutes while cEOS boots.
- cEOS on WSL sometimes boots into **systemd rescue mode** (random switch, usually tor-01).
  Fix: `docker exec <node> systemctl default --no-block` — `deploy.sh` does this automatically.
- Several cEOS need higher **inotify** limits (see sysctl above) or they fail to boot.
- Switches boot staggered (`startup-delay` 30/60/90 s on core-02/tor-01/tor-02) to avoid a WSL crash.
- **OSPF MTU**: clab veths are 9500, cEOS routed ports 1500 → fw-01 eth3/eth4 set to MTU 1500 in
  `init-router.sh` (waits for the links) + `ip ospf mtu-ignore` in `fw-01.conf`.
- cEOS-lab accepts but **does not enforce SVI ACLs** (`USERS-IN`) → policy enforced by the db01 host
  firewall (`configs/nft/db01-host.nft`).
- EOS 4.33: `show port-channel summary` is deprecated → use `show port-channel dense`.
- In `tests.sh`, `timeout` cannot wrap shell functions → timeout lives inside `x()`.
- Zabbix: "Arista by SNMP" already contains icmpping → don't add "ICMP Ping" to switches.
- Daemons started from exec scripts must detach stdio (`</dev/null >/dev/null 2>&1`).
- Zabbix and the Linux PCs/servers keep state only while deployed; rerun `zabbix-add-hosts.py` after each deploy.
- **Docker Desktop hijacks `/var/run/docker.sock`** if its WSL integration is on (watch the
  "Enable integration with my default WSL distro" checkbox, not just the per-distro toggle): containerlab
  then hangs at "Running postdeploy actions" and `docker ps` shows no lab. Check `docker info --format '{{.Name}}'`
  is the Ubuntu hostname, not `docker-desktop`. Keep that integration off.
- Lab links do not survive a WSL restart: after a reboot / `wsl --shutdown`, destroy and redeploy.

## Design deviations from the original diagram

pfSense → FRR+nftables · HSRP → VRRP · Rapid-PVST → MSTP · MGMT VLAN 10 → clab OOB network ·
Zabbix on OOB network · storage switch cabled to servers' storage NICs · AD01 = IP/DNS only (no Samba).

## Possible next work

Update the architecture diagram/PDF to match the lab · report chapter (tests 20/20, failover numbers) ·
faster VRRP/BFD · second firewall · Samba AD on ad01 · Grafana dashboards · Kali node for attack demos.
