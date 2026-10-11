# Mini Data Center — Containerlab lab

The mini data center architecture (network + buildings) as a **Containerlab** lab.
Every device is a container: no GNS3 VM, no nested virtualization, runs on **Windows 11 Home** through WSL2.

```
Internet (ISP A, ISP B)
   │            │
EDGE-R1      EDGE-R2        FRRouting · NAT · port-forward to the DMZ
   └──── FW-01 ────┘        FRRouting (OSPF) + nftables policy ── DMZ (VLAN 60)
       │        │
   CORE-01 ══ CORE-02       Arista cEOS · VRRP · LACP · MSTP · OSPF
     │  ╲    ╱  │  ╲ ╲
   TOR-01 ══ TOR-02         Arista cEOS · dual-homed · LACP
   Rack A     Rack B        + fibers to the logistics building (NOC, users)
                 │
            STORAGE-SW ── STORAGE01 (iSCSI target)
```

---

## 1. What you need

| | |
|---|---|
| Windows 11 (Home is fine) | WSL **2.4.4+** (`wsl --version`), `.wslconfig` with `memory=16GB` |
| RAM | **12 GB+ free recommended** (4 × cEOS ≈ 5–6 GB, Zabbix ≈ 1 GB, the rest is small) |
| Disk | ~6 GB |
| Arista cEOS-lab | free download, arista.com account |

> If you disabled Hyper-V features while fighting GNS3, turn them back on:
> enable **Virtual Machine Platform**, run `bcdedit /set hypervisorlaunchtype auto` (admin), reboot.

## 2. One-time install

1. **WSL-Containerlab**: download `clab.wsl` from
   <https://github.com/srl-labs/wsl-containerlab/releases>, double-click it, then launch
   `wsl -d Containerlab` and finish the first-run wizard.
2. **VS Code** (on Windows) + extensions **WSL** and **Containerlab** (srl-labs).
3. **cEOS**: on arista.com → Software Downloads → *cEOS-lab* → `cEOS64-lab-4.3x.x.tar.xz`.
   Copy it into WSL and import it:
   ```bash
   docker import cEOS64-lab-4.33.1F.tar.xz ceos:latest
   ```
4. Copy this folder into WSL (e.g. `~/mini-dc-lab`) and build the lab images:
   ```bash
   cd ~/mini-dc-lab
   ./setup.sh
   ```

## 3. Run it

> **Never press Ctrl+C in the deploy window** — it cancels and destroys the lab. The deploy is
> silent for several minutes while the Arista switches boot; watch from a second window instead.

```bash
./deploy.sh                                        # 5–8 min (switches boot one after another)
./scripts/tests.sh                                 # functional tests
./scripts/tests.sh failover                        # failover demo
python3 scripts/zabbix-add-hosts.py                # register devices in Zabbix
containerlab destroy -t mini-dc.clab.yml --cleanup
```

**GNS3-style GUI:** in VS Code, open the folder from WSL (`code .`), click the Containerlab
icon in the sidebar → right-click the lab → **Graph (TopoViewer)**. Nodes are grouped by
building/room. Right-click any node for SSH/console, any interface for a Wireshark capture.

**Consoles**

| Device | How |
|---|---|
| cEOS (cores, ToRs) | `ssh admin@clab-mini-dc-core-01` (password `admin`) or `docker exec -it clab-mini-dc-core-01 Cli` |
| FRR routers / FW | `docker exec -it clab-mini-dc-fw-01 vtysh` (routing) or `... sh` (shell, `nft list ruleset`) |
| Servers / PCs | `docker exec -it clab-mini-dc-web01 bash` |
| Zabbix | <http://localhost:8080> — `Admin` / `zabbix` |

---

## 4. Design → lab mapping

| Building / room | Device | Lab node | Image |
|---|---|---|---|
| Internet | ISP A / ISP B | `isp-a`, `isp-b` (NAT to the real Internet) | dc-router |
| Bât. informatique – MMR | EDGE-R1 / EDGE-R2 | `edge-r1`, `edge-r2` | dc-router (FRR) |
| | FW-01 | `fw-01` — OSPF + **nftables** (replaces pfSense) | dc-router |
| | CORE-01 / CORE-02 | `core-01`, `core-02` | **cEOS** |
| DMZ (VLAN 60) | DMZ-SW, WEB-DMZ01/02 | `dmz-sw` (Linux bridge), `web-dmz01/02` (nginx) | dc-host |
| Salle serveurs 1 | TOR-01, WEB01, APP01, DNS01 | `tor-01` (cEOS), `web01` (nginx), `app01` (Python API), `dns01` (BIND9) | |
| Salle serveurs 2 | TOR-02, DB01, AD01, BACKUP01 | `tor-02` (cEOS), `db01` (MariaDB), `ad01`, `backup01` | |
| Zone stockage | STORAGE-SW, STORAGE01 | `storage-sw` (bridge), `storage01` (**tgt** iSCSI target) | |
| Bât. logistique | NOC, users | `noc-sw`, `user-sw` (bridges with STP, dual-homed), `noc-ws`, `syslog01`, `pc-01`, `pc-02` | |
| | Management | containerlab **OOB network 10.10.10.0/24** + `admin-pc` | |
| | Monitoring | `monitor01` (Zabbix server), `zbx-web`, `zbx-db` | official images |
| Bâtiments techniques A/B | UPS, generators, cooling | physical only — not emulated | |

## 5. Addressing

| VLAN / segment | Network | Gateway | Hosts |
|---|---|---|---|
| OOB management (VLAN 10 role) | 10.10.10.0/24 | .1 | cores .11/.12, ToRs .21/.22, edges .31/.32, fw .40, Zabbix .50–.52, bridges .71–.74, servers .100–.113 |
| 20 Servers | 10.10.20.0/24 | VRRP .1 (core-01 .2 master, core-02 .3) | web01 .10, app01 .20, db01 .30, dns01 .40, ad01 .50 |
| 30 Storage (not routed) | 10.10.30.0/24 | none | storage01 .10, db01 .30, backup01 .40 |
| 40 Backup | 10.10.40.0/24 | VRRP .1 | backup01 .10 |
| 50 Users | 10.10.50.0/24 | VRRP .1 | pc-01 .101, pc-02 .102 |
| 60 DMZ | 10.10.60.0/24 | fw-01 .1 | web-dmz01 .10, web-dmz02 .11 |
| 70 Monitoring / NOC | 10.10.70.0/24 | VRRP .1 | noc-ws .10, syslog01 .20 |
| 99 Core transit | 10.10.99.8/30 | — | core-01 .9, core-02 .10 |
| FW ↔ cores | 10.10.99.0/30, .4/30 | — | fw .1/.5, core-01 .2, core-02 .6 |
| Edges ↔ FW | 10.0.1.0/30, .4/30 | — | edge-r1 .1, edge-r2 .5, fw .2/.6 |
| WAN | 10.0.0.0/30, .4/30 | — | edge-r1 .1 ↔ isp-a .2, edge-r2 .5 ↔ isp-b .6 |

## 6. How each feature is implemented

- **Dual ISP + failover** — each edge has a static default to its ISP and injects it into OSPF
  (`default-information originate`, metric 10 on edge-r1, 20 on edge-r2). If an ISP link dies the
  route disappears and FW-01 switches to the other edge in ~3 s (OSPF hello 1 s / dead 3 s).
- **NAT** — edges masquerade outbound traffic; `edge-r1:80 → web-dmz01`, `edge-r2:80 → web-dmz02`.
  Port-forwarded traffic is also source-NATed so replies return through the same ISP.
- **Firewall** (`configs/nft/fw-01.nft`) — default drop. Inside → anywhere; Internet → DMZ web 80/443;
  DMZ → db01:3306 and dns01:53 only; DMZ → Internet 80/443/53; everything else counted + logged.
- **Core** — VRRP (HSRP equivalent) with core-01 master, LACP Port-Channel between cores and between
  ToRs, MSTP with core-01 as root, OSPF to the firewall + a transit VLAN 99 between cores as backup path,
  ACL `USERS-IN` so users only reach DNS / intranet / app (documented on the cores; cEOS-lab does not
  enforce SVI ACLs in software, so `db01` also runs a host firewall that only accepts MariaDB from
  the app servers and the DMZ — defense in depth).
- **SAN** — `storage01` runs a userspace iSCSI target (tgt) with one target per server, restricted by
  initiator IP. `db01` and `backup01` use dedicated storage NICs; VLAN 30 has no gateway.
  Tested with `iscsi-ls` / `iscsi-readcapacity16` (userspace initiator, no kernel module needed).
- **OOB management** — cEOS management lives in a `MGMT` VRF; SSH, eAPI, SNMP and syslog run only there.
- **NOC** — switches send syslog to `syslog01` (`/var/log/remote/<host>.log`); Zabbix polls the switches
  over SNMP (community `dclab`) and pings every node.

## 7. Differences from the architecture diagram

| Diagram | Lab | Why |
|---|---|---|
| pfSense | FRR + nftables | pfSense is a VM image (needs KVM) |
| HSRP | VRRP | HSRP is Cisco-only; VRRP is the open standard |
| Rapid-PVST | MSTP | cEOS default, interoperates with the Linux bridges |
| MGMT-SW (VLAN 10) | containerlab management network | it *is* a separate OOB network |
| MONITOR01 in VLAN 70 | Zabbix on the OOB network, `noc-ws` in VLAN 70 | monitoring usually sits on management |
| STORAGE-SW → ToRs | STORAGE-SW → servers' storage NICs | dedicated SAN, no loop, not routed |
| FW 10.10.99.254 | routed /30 links to each core | lets OSPF use both cores |
| AD01 (Samba AD) | IP + DNS only | optional; install `samba` inside ad01 if needed |

## 8. Status

Validated on Windows 11 Home + WSL2 (Ubuntu 24.04, 32 GB RAM, cEOS 4.33.10M): VRRP, LACP, MSTP,
OSPF (cores + firewall), ISP failover, NAT/port-forwards, firewall policy, DNS, MariaDB from the DMZ,
iSCSI with per-server ACL, storage isolation, syslog (19/20 tests on first full run; the 20th,
users → db01:3306, is now enforced by the db01 host firewall).

## 9. Troubleshooting

| Symptom | Fix |
|---|---|
| `docker: permission denied` | `sudo usermod -aG docker $USER`, reopen WSL |
| cEOS nodes stuck / slow | normal first boot takes 1–2 min; check RAM with `free -h` |
| Not enough RAM | comment out `zbx-*` and `monitor01`, or give WSL more RAM in `%UserProfile%\.wslconfig` (`[wsl2]` `memory=12GB`) |
| Deploy silent for minutes | normal while cEOS boots; `deploy.sh` also auto-fixes a switch stuck in *rescue mode* |
| A switch never gets `Uptime` | `docker logs --tail 10 clab-mini-dc-tor-01` → if it says *rescue mode*: `docker exec clab-mini-dc-tor-01 systemctl default --no-block` |
| cEOS fails to boot with several switches | inotify limits too low — `setup.sh` raises them (`fs.inotify.max_user_instances=8192`) |
| OSPF core ↔ fw-01 stuck in EXCH START | MTU: `docker exec clab-mini-dc-fw-01 ip link set eth3 mtu 1500` (same for eth4) |
| Hosts can't reach the Internet | check `docker exec clab-mini-dc-fw-01 vtysh -c "show ip route"` has a default |
| noc-sw / user-sw no traffic for ~30 s | Spanning Tree converging with the Linux bridges; wait |
| Zabbix page not loading | wait 1–2 min after deploy (DB initialisation) |
| Deploy hangs 15+ min at "Running postdeploy actions" / `docker ps` shows no lab | Docker Desktop took over the socket: `docker info --format '{{.Name}}'` says `docker-desktop`. In Docker Desktop → Settings → Resources → WSL integration, untick **"Enable integration with my default WSL distro"** and the Ubuntu toggle, then `wsl --shutdown` |
| Lab half-dead after a reboot / `wsl --shutdown` | links don't survive a WSL restart: `containerlab destroy -t mini-dc.clab.yml --cleanup && ./deploy.sh` |

## 10. Working on this repo as a team

**First-time setup (each member)**

1. WSL2 Ubuntu 24.04 + Docker Engine + Containerlab; add yourself to the `docker` and `clab_admins` groups.
2. Download **your own** cEOS-lab from arista.com (the image is licensed, it is not in the repo) and import it:
   `docker import cEOS64-lab-4.33.x.tar.xz ceos:latest`
3. Clone into the Linux filesystem (not `/mnt/c`) and build the images:
   ```bash
   git clone <repo-url> ~/projects/mini-dc-lab && cd ~/projects/mini-dc-lab && ./setup.sh
   ```
4. Check Ubuntu uses its own Docker engine — this must print your machine name, not `docker-desktop`:
   `docker info --format '{{.Name}}'`
5. `./deploy.sh`, then `./scripts/tests.sh` → expect **20 passed**.

**Workflow**

- One branch per task (`git switch -c feature/<topic>`), push it and open a pull request — no direct pushes to `main`.
- Run `./scripts/tests.sh` before every pull request and paste the result in the description.
- `mini-dc.clab.yml.annotations.json` (TopoViewer layout) is rewritten whenever someone moves things in the graph:
  agree on one person for layout changes to avoid merge conflicts. Custom icons live in `.clab-icons/`.
- Not versioned (see `.gitignore`): `clab-mini-dc/` (generated at deploy), logs, backups, the cEOS image.
