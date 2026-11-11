# Daily use

[← Back to the README](../README.md) · Not installed yet? [First-time setup](setup.md)

> [!TIP]
> For demos and after every change, follow the **[testing guide (PDF)](testing-guide/RAM+_Data_Center_Testing_Guide.pdf)**:
> one command per feature with the expected result and why it matters, rule-by-rule firewall testing,
> the automated checks explained and a pass/fail checklist.

## Start and stop

```bash
cd ~/projects/mini-dc-lab
git pull
./deploy.sh                           # 5–8 min — never press Ctrl+C
                                      # after a reboot it offers to destroy the old copy: answer y
./scripts/tests.sh                    # wait 2–4 min for TrueNAS first; expect 27 passed, 0 failed
python3 scripts/zabbix-add-hosts.py   # re-register the Zabbix hosts (after every deploy)
```

When you are done — **always before shutting down Windows or running `wsl --shutdown`**:

```bash
docker exec clab-mini-dc-storage01 sh -c 'echo system_powerdown | socat - UNIX-CONNECT:/run/qemu-monitor.sock'   # clean TrueNAS shutdown, wait ~1 min
containerlab destroy -t mini-dc.clab.yml --cleanup
```

The virtual cables between containers do not survive a WSL restart. TrueNAS and its configuration are kept on its
virtual disks, so nothing has to be reinstalled.

## Commands

| Command | What it does |
|---|---|
| `./deploy.sh` | Start the lab (5–8 min) |
| `./scripts/tests.sh` | 27 functional checks |
| `./scripts/tests.sh failover` | ISP, core gateway, firewall and website failover demo |
| `./scripts/tests.sh loadshare` | Core load sharing: which core routes servers vs users, then user-gateway failover |
| `./scripts/db-failover.sh status` | Database: who owns the virtual IP, is the standby in sync |
| `./scripts/db-failover.sh` | Crash MariaDB on the primary and measure the takeover |
| `./scripts/db-failover.sh server` | Same, but the whole primary server goes offline |
| `./scripts/db-failover.sh restore` | Make the failed database server the new standby |
| `./scripts/backup.sh run` | Back up now: database + switch configs → backup01 + TrueNAS LUN |
| `./scripts/backup.sh list` | Restore points stored on backup01 and the job log |
| `./scripts/backup.sh restore-test` | Prove the last backup restores (local copy and TrueNAS copy) |
| `python3 scripts/zabbix-add-hosts.py` | Register all devices in Zabbix |
| `python3 scripts/truenas-setup.py` | (Re)apply the TrueNAS pool / zvols / iSCSI / snapshot configuration |
| `containerlab inspect -t mini-dc.clab.yml` | List nodes, state and management IPs |
| `containerlab destroy -t mini-dc.clab.yml --cleanup` | Stop and remove the lab |

## Consoles and web interfaces

| Device | How |
|---|---|
| cEOS (cores, ToRs) | `ssh admin@clab-mini-dc-core-01` (password `admin`) or `docker exec -it clab-mini-dc-core-01 Cli` |
| FRR routers / firewalls | `docker exec -it clab-mini-dc-fw-01 vtysh` (routing; same for `fw-02`) · `... sh` then `nft list ruleset` |
| Servers / PCs | `docker exec -it clab-mini-dc-web01 bash` |
| Zabbix | <http://localhost:8080> — `Admin` / `ZBX_ADMIN_PASS` from `lab.env` |
| Public website | `docker exec clab-mini-dc-isp-a curl --cacert /lab/pki/ca.crt --resolve www.dc.lab:443:10.0.0.1 https://www.dc.lab` |
| TrueNAS web UI | <https://localhost:8443> — `truenas_admin` |
| TrueNAS VM console | <http://localhost:6080/vnc_lite.html?scale=true> |
| Graphical view | VS Code → Containerlab icon → right-click `mini-dc` → **Graph (TopoViewer)** |

Useful checks:

```bash
docker exec clab-mini-dc-core-01 Cli -p 15 -c "show vrrp brief"
docker exec clab-mini-dc-core-01 Cli -p 15 -c "show ip ospf neighbor"
docker exec clab-mini-dc-fw-01 vtysh -c "show ip route"
```

## Failover tests

### Network — `./scripts/tests.sh failover`

Four failures in a row, each restored automatically, each measured with a fast ping or HTTPS requests:

| Failure | What takes over |
|---|---|
| ISP A link cut | the default route through edge-r2 (OSPF) |
| core-01's VLAN 20 interface shut | core-02 takes the server gateway (VRRP) |
| **fw-01 isolated** (all 5 cables down) | **fw-02**: OSPF reroutes through it, keepalived moves the DMZ gateway `10.10.60.1` |
| **web-dmz01 cut** | web-dmz02 takes `www.dc.lab` (`10.10.60.20`) and serves the site alone |

Measured: **ISP ≈ 0.2 s** · **core gateway (VRRP) ≈ 2.8 s** · **firewall ≈ 4.6 s** (OSPF dead interval 3 s +
rerouting; connections open at that moment must reconnect) · **website ≈ 3.0 s**, no loss when web-dmz01 takes it back.

### Backups — `./scripts/backup.sh`

backup01 backs up every night at 02:00 (first run 6 min after deploy): the shop database (dump taken from the
replica db02), the running configuration of the four switches, SHA-256 checksums, 7 restore points kept, and a
copy of everything on the TrueNAS backup LUN (iSCSI), where daily ZFS snapshots keep 14 days of versions
(run `python3 scripts/truenas-setup.py` once to create the snapshot schedule). Each run is logged to the NOC
(`syslog01`). `restore-test` restores the newest dump into a scratch MariaDB from the local copy and from the
copy read back from TrueNAS, and compares the row counts with the values recorded at backup time.

### Core load sharing — `./scripts/tests.sh loadshare`

The two cores share the routing: core-01 is the gateway for servers and backup (VLAN 20/40), core-02 for users and
the NOC (VLAN 50/70), each backing up the other. The test shows the VRRP masters on both cores, then sends 200 pings
from web01 and from pc-01 and counts the packets each core received (expected: web01 → core-01 only,
pc-01 → core-02 only). Finally it shuts core-02's VLAN 50 interface while pc-01 pings its gateway: core-01 takes
over (measured ≈ 2.4 s) and core-02 takes the users back when it returns.

### Database — `./scripts/db-failover.sh`

db01 (primary) and db02 (standby) share the database address `10.10.20.35` (`db.dc.lab`). The script makes app01
write one row every 0.2 s, breaks the primary, and reports how long writes failed and whether any data was lost.

| Command | Purpose |
|---|---|
| `status` | Read-only check: who owns `10.10.20.35`, is the standby replicating (`Yes / Yes`, 0 s behind) |
| *(no argument)* | **MariaDB crashes** on the primary → the standby takes over. Measured **≈ 2.3 s**, no data lost |
| `server` | **The whole primary server goes offline** (link cut) → detected by missing heartbeats. Measured **≈ 3.8 s** |
| `restore` | Rebuild the failed server as the new standby (≈ 7 s). Roles stay swapped — the next test fails over the other way |

Typical demo: `status` → *(crash)* → `restore` → `server` → `restore`. Redeploying also resets db01 as primary.
