# Architecture

[← Back to the README](../README.md)

Two views of the same design:

| | |
|---|---|
| [`architecture.svg`](architecture.svg) | Architecture diagram — buildings, rooms, VLANs, link types (for the report) |
| [`topoviewer.png`](topoviewer.png) | The running lab in VS Code TopoViewer |

```
Internet (ISP A, ISP B)
   │            │
EDGE-R1      EDGE-R2        FRRouting · NAT · port-forward 80/443 to www.dc.lab
   ├─ FW-01 ──┤             FRRouting (OSPF) + nftables policy, active ── DMZ (VLAN 60):
   └─ FW-02 ──┘             same policy, standby (OSPF cost 100)          www.dc.lab = HTTPS load balancer
       │        │                                                         on web-dmz01/02 (virtual IP .20)
   CORE-01 ══ CORE-02       Arista cEOS · VRRP · LACP · MSTP · OSPF
     │  ╲    ╱  │  ╲ ╲
   TOR-01 ══ TOR-02         Arista cEOS · dual-homed · LACP
   Rack A     Rack B        + fibers to the logistics building (NOC, users)
  (db02)      (db01)        MariaDB replica / primary, virtual IP 10.10.20.35
                 │
            STORAGE-SW ── STORAGE01 (TrueNAS SCALE · iSCSI)
```

## Design → lab mapping

| Building / room | Device | Lab node | Image |
|---|---|---|---|
| Internet | ISP A / ISP B | `isp-a`, `isp-b` (NAT to the real Internet) | dc-router |
| Bât. informatique – MMR | EDGE-R1 / EDGE-R2 | `edge-r1`, `edge-r2` | dc-router (FRR) |
| | FW-01 / FW-02 | `fw-01` (active), `fw-02` (standby) — OSPF + **nftables** (replaces pfSense), keepalived for the DMZ gateway | dc-router |
| | CORE-01 / CORE-02 | `core-01`, `core-02` | **cEOS** |
| DMZ (VLAN 60) | DMZ-SW, WEB-DMZ01/02 | `dmz-sw` (Linux bridge), `web-dmz01/02` (nginx TLS + load balancer, keepalived) | dc-host |
| Salle serveurs 1 | TOR-01, WEB01, APP01, DNS01, DB02 | `tor-01` (cEOS), `web01` (nginx), `app01` (Python API), `dns01` (BIND9), `db02` (MariaDB replica) | dc-host |
| Salle serveurs 2 | TOR-02, DB01, AD01, BACKUP01, WEB02, APP02 | `tor-02` (cEOS), `db01` (MariaDB primary), `ad01` (secondary DNS), `backup01` (backup job), `web02` / `app02` (second intranet / API server) | dc-host |
| Zone stockage | STORAGE-SW, STORAGE01 | `storage-sw` (bridge), `storage01` (**TrueNAS SCALE** VM under KVM) | dc-truenas |
| Bât. logistique | NOC, users | `noc-sw`, `user-sw` (bridges with STP, dual-homed), `noc-ws`, `syslog01`, `pc-01`, `pc-02` | dc-host |
| | Management | containerlab **OOB network 10.10.10.0/24** + `admin-pc` | dc-host |
| | Monitoring | `monitor01` (Zabbix server), `zbx-web`, `zbx-db` | official images |
| Bâtiments techniques A/B | UPS, generators, cooling | physical only — not emulated | |

## Addressing

| VLAN / segment | Network | Gateway | Hosts |
|---|---|---|---|
| OOB management (VLAN 10 role) | 10.10.10.0/24 | .1 | cores .11/.12, ToRs .21/.22, edges .31/.32, fw-01 .40, fw-02 .41, Zabbix .50–.52, bridges .71–.74, servers .100–.116 |
| 20 Servers | 10.10.20.0/24 | VRRP .1 (core-01 .2 master, core-02 .3) | web01 .10, web02 .11, **intranet VIP .12**, app01 .20, app02 .21, **app VIP .22**, db01 .30, db02 .31, **DB virtual IP .35** (`db.dc.lab`), dns01 .40, ad01 .50 |
| 30 Storage (not routed) | 10.10.30.0/24 | none | storage01 .10, db01 .30, backup01 .40 |
| 40 Backup | 10.10.40.0/24 | VRRP .1 | backup01 .10 |
| 50 Users | 10.10.50.0/24 | VRRP .1 | pc-01 .101, pc-02 .102 |
| 60 DMZ | 10.10.60.0/24 | VRRP .1 (fw-01 .2 master, fw-02 .3) | web-dmz01 .10, web-dmz02 .11, **website virtual IP .20** (`www.dc.lab`) |
| 70 Monitoring / NOC | 10.10.70.0/24 | VRRP .1 | noc-ws .10, syslog01 .20 |
| 99 Core transit | 10.10.99.8/30 | — | core-01 .9, core-02 .10 |
| FW-01 ↔ cores | 10.10.99.0/30, .4/30 | — | fw-01 .1/.5, core-01 .2, core-02 .6 |
| FW-02 ↔ cores | 10.10.99.12/30, .16/30 | — | fw-02 .13/.17, core-01 .14, core-02 .18 (OSPF cost 100) |
| Edges ↔ FW-01 | 10.0.1.0/30, .4/30 | — | edge-r1 .1, edge-r2 .5, fw-01 .2/.6 |
| Edges ↔ FW-02 | 10.0.1.8/30, .12/30 | — | edge-r1 .9, edge-r2 .13, fw-02 .10/.14 (OSPF cost 100) |
| FW-01 ↔ FW-02 sync | 10.10.99.20/30 | — | fw-01 .21, fw-02 .22 — conntrackd only, not routed |
| WAN | 10.0.0.0/30, .4/30 | — | edge-r1 .1 ↔ isp-a .2, edge-r2 .5 ↔ isp-b .6 |

## How each feature is implemented

- **Dual ISP + failover** — each edge has a static default to its ISP and injects it into OSPF
  (`default-information originate`, metric 10 on edge-r1, 20 on edge-r2). If an ISP link dies the
  route disappears and the firewall switches to the other edge (OSPF hello 1 s / dead 3 s). Measured ≈ 0.2 s.
- **NAT** — edges masquerade outbound traffic and forward TCP 80/443 of their public address to the website's
  virtual IP `10.10.60.20`. Port-forwarded traffic is also source-NATed so replies return through the same ISP.
- **Firewall pair** (`configs/nft/fw-01.nft`, loaded on both) — default drop. Inside → anywhere; Internet → the
  website virtual IP on 80/443 only; DMZ → the database virtual IP `10.10.20.35:3306` and dns01:53 only;
  DMZ → Internet 80/443/53; everything else counted + logged as `FW-01 DROP`. **fw-02** has the same five
  connections (both edges, both cores, DMZ) with OSPF cost 100 on every link, so all traffic uses fw-01 while it is
  alive; if fw-01 fails, OSPF reroutes through fw-02 within the 3 s dead interval and keepalived (VRRP 61) moves the
  DMZ gateway `10.10.60.1` to it. **BFD** (300 ms × 3) on every OSPF link between edges, firewalls and cores detects
  the failure in < 1 s instead of the 3 s OSPF dead interval, the route recalculation timers are shortened
  (SPF hold 50–500 ms instead of up to 5 s), and the DMZ gateway uses VRRPv3 with 0.2 s adverts. Measured: ≈ 0.2 s.
  fw-01 comes back with maximum OSPF cost until all its adjacencies are up, so its return is lossless.
  **conntrackd** copies every connection between the two firewalls over a dedicated cable (eth6), writing the other
  firewall's connections straight into the kernel table, so connections open during a failover keep working.
- **Public website** (`start_dmz_web` in `init-host.sh`) — `www.dc.lab` = virtual IP `10.10.60.20`, owned by
  web-dmz01 and moved to web-dmz02 by keepalived (VRRP 62) if web-dmz01 or its nginx fails. nginx terminates TLS
  (certificate from the lab's own CA, `pki/`), redirects HTTP to HTTPS, adds HSTS, and load-balances round robin over
  both servers' backend port 8080 (a dead backend is skipped after 0.5 s and avoided for 10 s).
- **No single server for internal services** — the intranet and the API each run on two servers in different
  racks (web01 / web02, app01 / app02) behind a keepalived virtual IP (`start_vip`, VRRPv3 0.2 s adverts, health check
  every second): `intranet.dc.lab` = 10.10.20.12, `app.dc.lab` = 10.10.20.22. DNS: dns01 is the primary, **ad01 a
  secondary** that copies the `dc.lab` zone (zone transfer + NOTIFY); every host lists both, with a 1 s timeout. The
  switches log to two collectors (syslog01 and noc-ws).
- **Remaining single point of failure: storage01.** A second TrueNAS needs another 8 GB of RAM that the laptop does not
  have. Mitigations: ZFS mirror (disk failure), snapshots, backups also kept on backup01's own disk.
- **Host firewalls** (`role_fw` in `init-host.sh`) — every server and PC drops incoming connections by default
  and opens only its role's ports (web01 80, app01 8080, dns01 53, db01/02 3306 + VRRP, syslog01 514, DMZ 80/443),
  each to the networks that need it. This enforces the user policy that cEOS-lab cannot (SVI ACLs).
- **Backups** (`scripts/backup.sh`, runs on backup01) — every night at 02:00 (and 6 min after deploy):
  `mariadb-dump` of the shop database from the replica db02, the running configs of the four switches through
  their API (eAPI, OOB network), SHA-256 checksums, 7 restore points kept, then a copy of everything onto the
  TrueNAS backup LUN over iSCSI (`qemu-img`). TrueNAS keeps daily ZFS snapshots of that LUN for 14 days.
  `backup.sh restore-test` proves the backups work: checksums, restore into a scratch MariaDB from the local copy
  **and** from the copy read back from TrueNAS, row counts compared with the backup-time values.
- **Secrets** — passwords are not in the repository: `scripts/gen-secrets.sh` (run by `deploy.sh`) creates
  `lab.env` with random values and the certificate authority in `pki/`, both git-ignored. The DMZ servers and the
  PCs unmount the lab folder after boot, so a compromised host cannot read them.
- **Core** — VRRP (HSRP equivalent) with **load sharing**: core-01 is master for VLAN 20/40 (servers, backup) and
  core-02 for VLAN 50/70 (users, NOC); each is the backup of the other. MSTP follows the same split (instance 1 =
  VLAN 20/40 rooted on core-01, instance 0 = VLAN 50/70 rooted on core-02), so each VLAN's frames go straight to
  the core that routes them. LACP Port-Channel between cores and between ToRs, OSPF to the firewall + a transit VLAN 99 between cores as backup path,
  ACL `USERS-IN` so users only reach DNS / intranet / app (documented on the cores; cEOS-lab does not
  enforce SVI ACLs in software, so every server enforces it with its own host firewall — defense in depth).
  Gateway failover measured ≈ 2.8 s.
- **Database high availability** — db01 (primary, rack B) replicates live to db02 (replica, rack A) with MariaDB
  GTID replication. keepalived (VRRP group 35) on both shares the database virtual IP `10.10.20.35`
  (`db.dc.lab`) and checks MariaDB every second. If MariaDB or the whole server fails, the replica takes the
  address and `db-promote.sh` makes it writable — no client change. Measured with `scripts/db-failover.sh`
  (a write every 0.2 s): **MariaDB crash ≈ 2.3 s**, **server offline ≈ 3.8 s**, no acknowledged write lost.
  No automatic failback: `restore` rebuilds the failed node as the new replica.
- **SAN** — `storage01` is a container running **TrueNAS SCALE 25.10** as a KVM virtual machine
  (`scripts/init-truenas.sh`). Its SAN NIC is bridged onto the container's `eth1` cable to `storage-sw`, so TrueNAS
  owns `10.10.30.10`; a second NIC (QEMU user network) carries the web UI / API. `truenas-setup.py` configures it
  through the JSON-RPC WebSocket API: ZFS mirror pool `tank`, one zvol per server, one iSCSI target per server
  restricted by initiator network. `db01` and `backup01` use dedicated storage NICs; VLAN 30 has no gateway.
  Tested with `iscsi-ls` / `iscsi-readcapacity16` (userspace initiator, no kernel module needed).
- **OOB management** — cEOS management lives in a `MGMT` VRF; SSH, eAPI, SNMP and syslog run only there.
- **NOC** — switches send syslog to `syslog01` (`/var/log/remote/<host>.log`); Zabbix polls the switches
  over SNMP (community `dclab`) and pings every node.
- **MTU** — servers use 1500-byte frames: the cEOS ports carry at most 9214 bytes, so containerlab's default 9500
  would silently drop large TCP segments crossing the switches.

## Differences from the original design

| Original design | Lab | Why |
|---|---|---|
| pfSense | FRR + nftables | pfSense is a FreeBSD appliance; FRR + nftables runs as a container |
| HSRP | VRRP | HSRP is Cisco-only; VRRP is the open standard |
| Rapid-PVST | MSTP | cEOS default, interoperates with the Linux bridges |
| MGMT-SW (VLAN 10) | containerlab management network | it *is* a separate OOB network |
| MONITOR01 in VLAN 70 | Zabbix on the OOB network, `noc-ws` in VLAN 70 | monitoring usually sits on management |
| STORAGE-SW → ToRs | STORAGE-SW → servers' storage NICs | dedicated SAN, no loop, not routed |
| FW 10.10.99.254 | routed /30 links to each core | lets OSPF use both cores |
| STORAGE01 | **TrueNAS SCALE** VM (KVM inside the container) | required by the course |
| DB01 alone | DB01 + **DB02** replica with a keepalived virtual IP | database high availability |
| FW-01 alone | FW-01 + **FW-02** standby (OSPF cost, VRRP DMZ gateway, BFD, conntrackd) | no single firewall to fail |
| WEB01, APP01, DNS01 alone | WEB02, APP02 + virtual IPs, AD01 = secondary DNS | no single server for an internal service |
| One DMZ web server per ISP | HTTPS **load balancer** on both servers behind one virtual IP | TLS, failover, both servers used |
| AD01 (Samba AD) | IP + DNS only | optional; install `samba` inside ad01 if needed |
