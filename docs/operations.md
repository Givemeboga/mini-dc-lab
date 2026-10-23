# Daily use

[← Back to the README](../README.md) · Not installed yet? [First-time setup](setup.md)

> [!TIP]
> For demos and after every change, follow the **[testing guide (PDF)](testing-guide/RAM+_Data_Center_Testing_Guide.pdf)**:
> one command per feature with the expected result and why it matters, rule-by-rule firewall testing,
> the 20 automated checks explained and a pass/fail checklist.

## Start and stop

```bash
cd ~/projects/mini-dc-lab
git pull
./deploy.sh                           # 5–8 min — never press Ctrl+C
                                      # after a reboot it offers to destroy the old copy: answer y
./scripts/tests.sh                    # wait 2–4 min for TrueNAS first; expect 20 passed, 0 failed
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
| `./scripts/tests.sh` | 20 functional checks |
| `./scripts/tests.sh failover` | ISP + VRRP gateway failover demo |
| `./scripts/db-failover.sh status` | Database: who owns the virtual IP, is the standby in sync |
| `./scripts/db-failover.sh` | Crash MariaDB on the primary and measure the takeover |
| `./scripts/db-failover.sh server` | Same, but the whole primary server goes offline |
| `./scripts/db-failover.sh restore` | Make the failed database server the new standby |
| `python3 scripts/zabbix-add-hosts.py` | Register all devices in Zabbix |
| `python3 scripts/truenas-setup.py` | (Re)apply the TrueNAS pool / zvols / iSCSI configuration |
| `containerlab inspect -t mini-dc.clab.yml` | List nodes, state and management IPs |
| `containerlab destroy -t mini-dc.clab.yml --cleanup` | Stop and remove the lab |

## Consoles and web interfaces

| Device | How |
|---|---|
| cEOS (cores, ToRs) | `ssh admin@clab-mini-dc-core-01` (password `admin`) or `docker exec -it clab-mini-dc-core-01 Cli` |
| FRR routers / firewall | `docker exec -it clab-mini-dc-fw-01 vtysh` (routing) · `... sh` then `nft list ruleset` |
| Servers / PCs | `docker exec -it clab-mini-dc-web01 bash` |
| Zabbix | <http://localhost:8080> — `Admin` / `zabbix` |
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

Cuts ISP A, then shuts the VRRP master's VLAN 20 interface, while web01 pings 5 times per second; both are restored
automatically. Measured: **ISP failover ≈ 0.2 s**, **gateway (VRRP) failover ≈ 2.8 s**.

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
