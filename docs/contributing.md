# Team workflow

[← Back to the README](../README.md) · New here? [First-time setup](setup.md)

## Making a change

1. **Update** — `git pull` on `main` before you start.
2. **Branch** — one branch per task: `git switch -c feature/<topic>`.
3. **Test** — `./scripts/tests.sh` must say `39 passed`; for database changes also run `./scripts/db-failover.sh`.
4. **Push** — `git push -u origin feature/<topic>`, then open a pull request and paste the test result.
5. **Review & merge** — no direct pushes to `main`.

> [!NOTE]
> `mini-dc.clab.yml.annotations.json` (the TopoViewer layout) is rewritten whenever someone moves things
> in the graph — agree on one person for layout changes to avoid merge conflicts.

After pulling a change to `images/` (Dockerfiles), run `./setup.sh` to rebuild the images, then redeploy.

## Repository layout

| Path | Purpose |
|---|---|
| `mini-dc.clab.yml` | Topology: 36 nodes, 44 links, management network `dc-oob` |
| `mini-dc.clab.yml.annotations.json` | TopoViewer layout (buildings, rooms, labels) — visual only |
| `.clab-icons/` | Custom TopoViewer icons |
| `configs/ceos/` | Arista startup configs — cores (L3, VRRP load sharing, MSTP, OSPF), ToRs (L2) |
| `configs/frr/` | FRRouting configs for the edges, both firewalls and the ISPs |
| `configs/nft/` | nftables — firewall policy (both firewalls), edge NAT / port-forwards, ISP NAT |
| `scripts/init-router.sh` | Boot script for ISPs, edges, firewalls (sysctl, routes, MTU, nftables, DMZ gateway keepalived) |
| `scripts/init-bridge.sh` | Turns a container into a Linux-bridge switch (`stp` for dual-homed ones) |
| `scripts/init-host.sh` | Boot script for every server / PC — role chosen by hostname (MariaDB HA, HTTPS load balancer, host firewalls) |
| `scripts/gen-secrets.sh` | Creates `lab.env` (random passwords) and `pki/` (lab CA + www.dc.lab certificate) — run by `deploy.sh` |
| `scripts/backup.sh` | Backup job on backup01: run · list · restore-test · status |
| `scripts/init-truenas.sh` | Boot script for storage01: bridges the SAN cable, starts the TrueNAS VM (QEMU/KVM) |
| `scripts/truenas-setup.py` | Configures TrueNAS (SAN IP, ZFS pool, zvols, iSCSI targets + ACL, snapshot tasks) via its API |
| `scripts/tests.sh` | functional checks · `failover` · `loadshare` · `monitoring` demos |
| `scripts/db-failover.sh` | Database failover test: status · crash · server · restore |
| `scripts/db-promote.sh` | keepalived hook: makes the node that takes the DB virtual IP a writable primary |
| `scripts/zabbix-setup.py` | Configures Zabbix through its API: hosts, checks, alarms, dashboard · `problems` |
| `scripts/init-ops.sh` | Boot script part run on every server / firewall / edge: log forwarding, NTP, Zabbix agent checks |
| `scripts/ids.sh` / `configs/suricata/` | Suricata IDS + automatic blocking on the edges, lab-specific rules |
| `scripts/attack.sh` | Attack simulation from kali for the security demo |
| `scripts/secure-switches.sh` | Switch hardening at deploy: RADIUS logins, SNMPv3, random local password |
| `scripts/facility.sh` | Building management simulator on bms01 (UPS, generators, cooling) + incident commands |
| `deploy.sh` | secrets + `containerlab deploy` + stale-lab check + cEOS rescue-mode watcher + real failure reporting |
| `setup.sh` | One-time: kernel limits, builds `dc-router` / `dc-host` / `dc-truenas`, pulls Zabbix images |
| `images/` | Dockerfiles for `dc-router`, `dc-host`, `dc-truenas` and `dc-kali` (attacker) |
| `lab.env.example` | Template of `lab.env` (the real file is generated and never committed) |
| `truenas/` | TrueNAS ISO and VM disks (local only, not in git) |
| `docs/` | This documentation, the architecture diagram, the TopoViewer screenshot and the testing guide |
| `CLAUDE.md` | Notes for the Claude Code assistant: environment, commands, lessons learned |

## Not versioned

See `.gitignore`: `lab.env` and `pki/` (this machine's passwords and private keys), `clab-mini-dc/` (generated at every deploy, contains TLS keys), `truenas/` (ISO + VM disks),
logs, layout backups and the cEOS image. **Never commit the cEOS `.tar.xz`** — it is licensed by Arista.

## Updating the documentation

- **Testing guide** — edit `docs/testing-guide/testing-guide.html`, then re-print it to PDF (the command is in a
  comment at the top of the file) and commit both files.
- **Architecture diagram** — `docs/architecture.svg` is hand-written SVG; open it in a browser to check.
- **TopoViewer screenshot** — replace `docs/topoviewer.png` after a layout change.
