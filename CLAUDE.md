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
| `mini-dc.clab.yml` | Topology: 36 nodes, 44 links, mgmt network `dc-oob` 10.10.10.0/24 |
| `mini-dc.clab.yml.annotations.json` | TopoViewer layout (buildings, rooms, icons) — visual only |
| `configs/ceos/*.cfg` | Arista startup configs: core-01/02 (L3, VRRP load sharing: core-01 VLAN 20/40, core-02 VLAN 50/70, MSTP, OSPF), tor-01/02 (L2) |
| `configs/frr/*.conf`, `daemons` | FRR for edge-r1/r2, fw-01 (active) and fw-02 (standby, OSPF cost 100); bfdd on, `ip ospf bfd` on edge/fw/core links |
| `configs/nft/*.nft` | nftables: firewall policy (fw-01.nft, loaded on both firewalls), edge NAT/port-forward 80/443 → www VIP, ISP NAT |
| `scripts/init-router.sh` | exec for isp/edge/fw (sysctl, remove docker default route, MTU, nft, keepalived DMZ gateway VRRPv3 61, conntrackd over eth6) |
| `scripts/init-bridge.sh` | exec for Linux-bridge "switches" (`stp` arg for dual-homed ones) |
| `scripts/init-host.sh` | exec for every server/PC; role chosen by hostname (IPs, nginx, BIND, MariaDB HA, HTTPS LB on web-dmz01/02 + VRRP 62, host firewall `role_fw`, backup scheduler). `init-host.sh <function>` re-runs one function |
| `scripts/gen-secrets.sh` | creates git-ignored `lab.env` (random passwords) + `pki/` (lab CA, www.dc.lab cert); run by deploy.sh |
| `scripts/backup.sh` | backup job on backup01 (re-execs itself there): `run` · `list` · `restore-test` · `status`; nightly 02:00 |
| `scripts/init-truenas.sh` | exec for storage01: bridges eth1 (SAN) to the VM's tap0, creates qcow2 disks, starts QEMU/KVM + noVNC |
| `scripts/truenas-setup.py` | Idempotent TrueNAS config over JSON-RPC WebSocket (stdlib client): SAN IP, pool `tank`, zvols, iSCSI targets + `auth_networks` ACL |
| `scripts/db-failover.sh` | DB HA test: `status` · crash (default) · `server` · `restore`; measures write outage from app01 |
| `scripts/db-promote.sh` | keepalived notify_master: STOP/RESET SLAVE + read_only=OFF on the new VIP owner |
| `scripts/tests.sh` | 39 functional checks; `failover` = ISP, VRRP, firewall (+TCP stream), website, intranet, DNS; `loadshare` = core load sharing |
| `scripts/zabbix-setup.py` | Zabbix via API (run by deploy.sh): hosts, custom agent items + triggers, dashboard; `problems` lists active ones. Admin / ZBX_ADMIN_PASS |
| `scripts/init-ops.sh` | run by init-host/init-router: rsyslog forward to both collectors (OOB), chrony (-x), zabbix_agentd with role UserParameters |
| `scripts/ids.sh` | edges: Suricata on eth1 (ET Open selection baked in dc-router + configs/suricata/dc-lab.rules), auto-block in nft set `inet edge blocklist` (10 min) |
| `scripts/attack.sh` | kali attacks (web / recon / bruteforce), `status`, `unblock`; demo: `tests.sh attack` |
| `scripts/secure-switches.sh` | run by deploy.sh: RADIUS AAA (ad01), SNMPv3 user zabbix, random local admin, removes community dclab |
| `scripts/facility.sh` | BMS simulator on bms01 (`run` daemon) + `status`/`cooling-failure`/`power-failure`/`generator-failure`/`restore` |
| `deploy.sh` | Wrapper around `containerlab deploy`: refuses/offers to destroy a stale lab, watcher un-sticks cEOS rescue mode, reports real failures |
| `setup.sh` | Builds `dc-router` (FRR+nftables), `dc-host` (Debian services), `dc-truenas` (Ubuntu + QEMU + noVNC) images |
| `README.md` + `docs/*.md` | README = short landing page; `docs/setup.md` (install), `operations.md` (daily use), `architecture.md`, `troubleshooting.md`, `contributing.md` (workflow + full file layout) — update the right one, keep README short |

## Commands

```bash
./deploy.sh                                          # start (5–8 min, silent while cEOS boots)
./scripts/tests.sh                                   # expect 39 passed (iSCSI needs TrueNAS booted: 2–4 min, backup check: first backup 6 min after deploy)
./scripts/backup.sh run | restore-test               # backup now / prove it restores (local + TrueNAS copy)
python3 scripts/truenas-setup.py                     # (re)apply TrueNAS config, asks for the password
./scripts/db-failover.sh [status|server|restore]     # DB failover: crash ≈2.3 s, server offline ≈3.8 s
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
- Zabbix and the Linux PCs/servers keep state only while deployed; deploy.sh runs `zabbix-setup.py` (re-run it if it timed out).
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
- Mirror speed varies: Debian's (Fastly) was once ~30 KB/s, later 5 MB/s; a build where apt finds *no* packages
  is a transient network failure → just rebuild. dc-truenas is on `ubuntu:24.04`, dc-host on `debian:bookworm-slim`.
- **DB HA**: VIP 10.10.20.35 (keepalived VRRP 35, nopreempt, chk = `mariadb-admin ping` every 1 s). The DMZ may
  only reach the VIP (fw-01 `DB01` define), never db01/db02 directly. `skip_name_resolve` is required: without it
  each login waits for a reverse-DNS lookup and 1 s client timeouts fail.
- **Host MTU must be 1500**: clab veths default to 9500 but cEOS ports carry max 9214 bytes, so full-size TCP
  segments crossing the switches are silently dropped — pings and small queries work, bulk transfers hang forever
  (seen as `db-failover.sh restore` stuck on mariadb-dump). `init-host.sh` `addr()` sets mtu 1500.
- `pkill -f <name>` inside `sh -c '...'` matches the sh itself and kills it → use `pkill -x` (process name).
- Containers' PID 1 is `sleep infinity`: killed daemons stay zombies, and a stale `/run/mysqld/mysqld.pid` makes
  mysqld_safe refuse to start ("process already exists") → remove pid file + socket before restarting MariaDB.
- TrueNAS 25.10: REST API is deprecated (removed in 26) → use JSON-RPC 2.0 over `wss://host/api/current`,
  login with `auth.login_ex` (PASSWORD_PLAIN). Configuring one NIC stops DHCP on unconfigured ones, so the
  management NIC (QEMU user net, MAC 52:54:00:10:01:07) must be set to DHCP in the same change, then
  `interface.commit` (rollback) + reconnect + `interface.checkin` within the timeout.
- TrueNAS refuses a zvol bigger than 80% of the free pool space (2 × 20 GiB mirror → db 10 GiB, backup 4 GiB).
- The iSCSI base name is set to `iqn.2026-09.lab.dc` and targets are LUN 1, so the tests kept the old tgt IQNs.
- OpenSSL `-subj`: a bare `+` splits an RDN (`RAM+` silently produced no certificate) → write `RAM\+`.
- Secrets live in git-ignored `lab.env` / `pki/`; the DMZ servers and PCs `umount /lab` after boot, so
  `init-host.sh <function>` cannot be re-run there (redeploy instead). Tests read passwords from `lab.env`.
- fw-01/fw-02 sync connections with conntrackd (FTFW, `DisableExternalCache On` = written straight into the kernel
  table, no commit step needed) over the eth6 cable 10.10.99.20/30; nft input must allow udp 3780 there and udp 3784 (BFD).
- Redundant internal services: `start_vip` in init-host.sh (keepalived VRRPv3, advert 0.2 s): intranet 10.10.20.12 (web01/02,
  VRRP 21), app 10.10.20.22 (app01/02, VRRP 22), www 10.10.60.20 (VRRP 62); fw DMZ gateway VRRP 61. VRIDs must stay
  unique per VLAN (cores use 20/40/50/70, DB 35).
- ad01 = secondary DNS (slave of dns01); resolv.conf lists both with `options timeout:1 attempts:2`.
- Cutting a host's eth1 (`ip link set down`) deletes its default route: restore with `ip route replace default via …`.
- keepalived: one directive per line. `global_defs { a; b; vrrp_version 3 }` on one line was silently ignored (adverts
  stayed VRRPv2 1 s) → `version 3` inside each vrrp_instance. Restart = pkill + wait until the old process is gone
  (it takes ~1 s; a new one started earlier exits because the pid file still exists).
- Slow OSPF reroute was the SPF hold timer (5 s max by default on cEOS and FRR), not detection → cores
  `timers spf delay initial 0 50 500` + lsa timers, FRR `timers throttle spf 0 50 500`. Firewall failover 0.2 s.
- Bringing fw-01 back: `max-metric router-lsa administrative` until its 4 adjacencies are Full, then remove it
  (tests.sh does this); FRR also has `max-metric router-lsa on-startup 20`, keepalived DMZ_GW `preempt_delay 10`.
- BIND secondary with no zone retries after 500 s by default → `min-retry-time 30` on ad01.
- nftables `log` does nothing in a container netns (`nf_log_all_netns=0`) → `log group 1` + ulogd (NFLOG) → rsyslog.
- Security: Suricata only on the edges' WAN link — behind them port-forwards are SNATed, so the firewall would only
  see edge IPs; HTTPS payloads are invisible to any network IDS (web attacks are detected on port 80). Switch logins:
  `aaa authentication login default group NETADMIN local` -> local admin works only when RADIUS is unreachable, so tools
  (backup.sh eAPI) use SWITCH_USER=netadmin. MariaDB clients use TLS by default (10.11); `REQUIRE SSL` on web/app/repl/backup.
  kali: eth0 down + /lab unmounted (attacker gets no management access, no secrets).
- Zabbix agent runs as user zabbix: MariaDB via `zabbix@localhost` unix_socket (REPLICATION CLIENT, SLAVE MONITOR),
  vtysh needs groups frr + frrvty. Agents listen on the OOB IP only; monitor01 has `zabbix_get` for tests.
- Writing to the iSCSI LUN from a container: no kernel initiator in WSL → `qemu-img convert -n … iscsi://` /
  `qemu-img dd` (qemu-block-extra) in dc-host.

## Design deviations from the original diagram

pfSense → FRR+nftables · HSRP → VRRP · Rapid-PVST → MSTP · MGMT VLAN 10 → clab OOB network ·
Zabbix on OOB network · storage switch cabled to servers' storage NICs · AD01 = IP/DNS only (no Samba) ·
STORAGE01 = TrueNAS SCALE VM (required by the professor) instead of a container iSCSI target ·
added DB02 + keepalived virtual IP (database high availability) · added FW-02 standby firewall ·
DMZ web servers behind one HTTPS load balancer VIP (10.10.60.20 www.dc.lab) instead of one server per ISP.

## Possible next work

Priority 2 of the project review: NTP · Samba AD / FreeIPA + RADIUS · Suricata IDS + Kali attack demo ·
Zabbix alerts/dashboards automated from deploy.sh · storage replication · BFD · simulated UPS/temperature sensors.
