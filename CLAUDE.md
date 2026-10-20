# RAM+ Data Center — Containerlab lab

School project (ESPRIT, cybersecurity & cloud engineering): a mini data center (network + buildings)
emulated with **Containerlab** on **Windows 11 Home → WSL2 Ubuntu 24.04** (no GNS3 — its VM setup failed
here). Everything runs as containers, except TrueNAS, which runs as a KVM VM *inside* the storage01 container
(`/dev/kvm` works in WSL2 on this AMD Ryzen 9 9955HX).

## Environment

- Host: Windows 11 Home, 32 GB RAM. WSL `.wslconfig`: `memory=24GB` (TrueNAS VM needs 8 GB), `processors=6`, `swap=4GB`.
- Lab lives in `~/projects/mini-dc-lab` (Linux FS). `C:\Projects\mini-dc-lab` is a symlink to it.
- User is in groups `docker` and `clab_admins` → run `containerlab` **without sudo**.
- Containerlab 0.79.0. Arista cEOS image imported as `ceos:latest` (cEOS64-lab-4.33.10M).
- TrueNAS SCALE 25.10.7 (Goldeye): ISO + VM disks in `truenas/` (gitignored). Admin user `truenas_admin`,
  password chosen by the user at install (not `truenas`) — never ask for it in chat; `truenas-setup.py` prompts.
  Web UI https://localhost:8443, VM console http://localhost:6080/vnc_lite.html (the full vnc.html fails in the in-app browser).
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
| `scripts/init-host.sh` | exec for every server/PC; role chosen by hostname (IPs, nginx, BIND, MariaDB, rsyslog) |
| `scripts/init-truenas.sh` | exec for storage01: bridges eth1 (SAN) to the VM's tap0, creates qcow2 disks, starts QEMU/KVM + noVNC |
| `scripts/truenas-setup.py` | Idempotent TrueNAS config over JSON-RPC WebSocket (stdlib client): SAN IP, pool `tank`, zvols, iSCSI targets + `auth_networks` ACL |
| `scripts/tests.sh` | 20 functional checks; `tests.sh failover` = ISP + VRRP failover demo |
| `scripts/zabbix-add-hosts.py` | Registers devices in Zabbix via API (http://localhost:8080, Admin/zabbix) |
| `deploy.sh` | Wrapper around `containerlab deploy`: refuses/offers to destroy a stale lab, watcher un-sticks cEOS rescue mode, reports real failures |
| `setup.sh` | Builds `dc-router` (FRR+nftables), `dc-host` (Debian services), `dc-truenas` (Ubuntu + QEMU + noVNC) images |

## Commands

```bash
./deploy.sh                                          # start (5–8 min, silent while cEOS boots)
./scripts/tests.sh                                   # expect 20 passed (iSCSI needs TrueNAS booted: 2–4 min)
python3 scripts/truenas-setup.py                     # (re)apply TrueNAS config, asks for the password
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
- Lab links do not survive a WSL restart: after a reboot / `wsl --shutdown`, destroy and redeploy
  (`deploy.sh` now detects the stale lab and offers to destroy it). The user often reboots without destroying.
- **Editing files through `\\wsl.localhost\...` (Windows Write/Edit tools) drops the executable bit** →
  `chmod +x` the script and check `git ls-files -s` shows 100755 before committing.
- Commands passed through `wsl.exe -- bash -c '...'` get `$var` expanded by the outer shell → put anything
  with `$`, awk or loops in a script file and run that.
- The Debian mirror (Fastly) is ~30 KB/s from here; Ubuntu's mirror is ~2 MB/s → base images on `ubuntu:24.04`.
- TrueNAS 25.10: REST API is deprecated (removed in 26) → use JSON-RPC 2.0 over `wss://host/api/current`,
  login with `auth.login_ex` (PASSWORD_PLAIN). Configuring one NIC stops DHCP on unconfigured ones, so the
  management NIC (QEMU user net, MAC 52:54:00:10:01:07) must be set to DHCP in the same change, then
  `interface.commit` (rollback) + reconnect + `interface.checkin` within the timeout.
- TrueNAS refuses a zvol bigger than 80% of the free pool space (2 × 20 GiB mirror → db 10 GiB, backup 4 GiB).
- The iSCSI base name is set to `iqn.2026-09.lab.dc` and targets are LUN 1, so the tests kept the old tgt IQNs.

## Design deviations from the original diagram

pfSense → FRR+nftables · HSRP → VRRP · Rapid-PVST → MSTP · MGMT VLAN 10 → clab OOB network ·
Zabbix on OOB network · storage switch cabled to servers' storage NICs · AD01 = IP/DNS only (no Samba) ·
STORAGE01 = TrueNAS SCALE VM (required by the professor) instead of a container iSCSI target.

## Possible next work

report chapter (tests 20/20, failover numbers) ·
faster VRRP/BFD · second firewall · Samba AD on ad01 · Grafana dashboards · Kali node for attack demos.
