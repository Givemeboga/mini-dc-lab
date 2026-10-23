# Team workflow

[← Back to the README](../README.md) · New here? [First-time setup](setup.md)

## Making a change

1. **Update** — `git pull` on `main` before you start.
2. **Branch** — one branch per task: `git switch -c feature/<topic>`.
3. **Test** — `./scripts/tests.sh` must say `20 passed`; for database changes also run `./scripts/db-failover.sh`.
4. **Push** — `git push -u origin feature/<topic>`, then open a pull request and paste the test result.
5. **Review & merge** — no direct pushes to `main`.

> [!NOTE]
> `mini-dc.clab.yml.annotations.json` (the TopoViewer layout) is rewritten whenever someone moves things
> in the graph — agree on one person for layout changes to avoid merge conflicts.

After pulling a change to `images/` (Dockerfiles), run `./setup.sh` to rebuild the images, then redeploy.

## Repository layout

| Path | Purpose |
|---|---|
| `mini-dc.clab.yml` | Topology: 31 nodes, 35 links, management network `dc-oob` |
| `mini-dc.clab.yml.annotations.json` | TopoViewer layout (buildings, rooms, labels) — visual only |
| `.clab-icons/` | Custom TopoViewer icons |
| `configs/ceos/` | Arista startup configs — cores (L3, VRRP, MSTP root, OSPF), ToRs (L2) |
| `configs/frr/` | FRRouting configs for the edges, firewall and ISPs |
| `configs/nft/` | nftables — firewall policy, edge NAT / port-forwards, ISP NAT, database host firewall |
| `scripts/init-router.sh` | Boot script for ISPs, edges, firewall (sysctl, routes, MTU, nftables) |
| `scripts/init-bridge.sh` | Turns a container into a Linux-bridge switch (`stp` for dual-homed ones) |
| `scripts/init-host.sh` | Boot script for every server / PC — role chosen by hostname (incl. MariaDB primary/replica + keepalived) |
| `scripts/init-truenas.sh` | Boot script for storage01: bridges the SAN cable, starts the TrueNAS VM (QEMU/KVM) |
| `scripts/truenas-setup.py` | Configures TrueNAS (SAN IP, ZFS pool, zvols, iSCSI targets + ACL) via its API |
| `scripts/tests.sh` | 20 functional checks · `failover` demo |
| `scripts/db-failover.sh` | Database failover test: status · crash · server · restore |
| `scripts/db-promote.sh` | keepalived hook: makes the node that takes the DB virtual IP a writable primary |
| `scripts/zabbix-add-hosts.py` | Registers all devices in Zabbix through its API |
| `deploy.sh` | `containerlab deploy` + stale-lab check + cEOS rescue-mode watcher + real failure reporting |
| `setup.sh` | One-time: kernel limits, builds `dc-router` / `dc-host` / `dc-truenas`, pulls Zabbix images |
| `images/` | Dockerfiles for `dc-router`, `dc-host` and `dc-truenas` |
| `truenas/` | TrueNAS ISO and VM disks (local only, not in git) |
| `docs/` | This documentation, the architecture diagram, the TopoViewer screenshot and the testing guide |
| `CLAUDE.md` | Notes for the Claude Code assistant: environment, commands, lessons learned |

## Not versioned

See `.gitignore`: `clab-mini-dc/` (generated at every deploy, contains TLS keys), `truenas/` (ISO + VM disks),
logs, layout backups and the cEOS image. **Never commit the cEOS `.tar.xz`** — it is licensed by Arista.

## Updating the documentation

- **Testing guide** — edit `docs/testing-guide/testing-guide.html`, then re-print it to PDF (the command is in a
  comment at the top of the file) and commit both files.
- **Architecture diagram** — `docs/architecture.svg` is hand-written SVG; open it in a browser to check.
- **TopoViewer screenshot** — replace `docs/topoviewer.png` after a layout change.
