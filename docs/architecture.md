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
EDGE-R1      EDGE-R2        FRRouting · NAT · port-forward to the DMZ
   └──── FW-01 ────┘        FRRouting (OSPF) + nftables policy ── DMZ (VLAN 60)
       │        │
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
| | FW-01 | `fw-01` — OSPF + **nftables** (replaces pfSense) | dc-router |
| | CORE-01 / CORE-02 | `core-01`, `core-02` | **cEOS** |
| DMZ (VLAN 60) | DMZ-SW, WEB-DMZ01/02 | `dmz-sw` (Linux bridge), `web-dmz01/02` (nginx) | dc-host |
| Salle serveurs 1 | TOR-01, WEB01, APP01, DNS01, DB02 | `tor-01` (cEOS), `web01` (nginx), `app01` (Python API), `dns01` (BIND9), `db02` (MariaDB replica) | dc-host |
| Salle serveurs 2 | TOR-02, DB01, AD01, BACKUP01 | `tor-02` (cEOS), `db01` (MariaDB primary), `ad01`, `backup01` | dc-host |
| Zone stockage | STORAGE-SW, STORAGE01 | `storage-sw` (bridge), `storage01` (**TrueNAS SCALE** VM under KVM) | dc-truenas |
| Bât. logistique | NOC, users | `noc-sw`, `user-sw` (bridges with STP, dual-homed), `noc-ws`, `syslog01`, `pc-01`, `pc-02` | dc-host |
| | Management | containerlab **OOB network 10.10.10.0/24** + `admin-pc` | dc-host |
| | Monitoring | `monitor01` (Zabbix server), `zbx-web`, `zbx-db` | official images |
| Bâtiments techniques A/B | UPS, generators, cooling | physical only — not emulated | |

## Addressing

| VLAN / segment | Network | Gateway | Hosts |
|---|---|---|---|
| OOB management (VLAN 10 role) | 10.10.10.0/24 | .1 | cores .11/.12, ToRs .21/.22, edges .31/.32, fw .40, Zabbix .50–.52, bridges .71–.74, servers .100–.114 |
| 20 Servers | 10.10.20.0/24 | VRRP .1 (core-01 .2 master, core-02 .3) | web01 .10, app01 .20, db01 .30, db02 .31, **DB virtual IP .35** (`db.dc.lab`), dns01 .40, ad01 .50 |
| 30 Storage (not routed) | 10.10.30.0/24 | none | storage01 .10, db01 .30, backup01 .40 |
| 40 Backup | 10.10.40.0/24 | VRRP .1 | backup01 .10 |
| 50 Users | 10.10.50.0/24 | VRRP .1 | pc-01 .101, pc-02 .102 |
| 60 DMZ | 10.10.60.0/24 | fw-01 .1 | web-dmz01 .10, web-dmz02 .11 |
| 70 Monitoring / NOC | 10.10.70.0/24 | VRRP .1 | noc-ws .10, syslog01 .20 |
| 99 Core transit | 10.10.99.8/30 | — | core-01 .9, core-02 .10 |
| FW ↔ cores | 10.10.99.0/30, .4/30 | — | fw .1/.5, core-01 .2, core-02 .6 |
| Edges ↔ FW | 10.0.1.0/30, .4/30 | — | edge-r1 .1, edge-r2 .5, fw .2/.6 |
| WAN | 10.0.0.0/30, .4/30 | — | edge-r1 .1 ↔ isp-a .2, edge-r2 .5 ↔ isp-b .6 |

## How each feature is implemented

- **Dual ISP + failover** — each edge has a static default to its ISP and injects it into OSPF
  (`default-information originate`, metric 10 on edge-r1, 20 on edge-r2). If an ISP link dies the
  route disappears and FW-01 switches to the other edge (OSPF hello 1 s / dead 3 s). Measured ≈ 0.2 s.
- **NAT** — edges masquerade outbound traffic; `edge-r1:80 → web-dmz01`, `edge-r2:80 → web-dmz02`.
  Port-forwarded traffic is also source-NATed so replies return through the same ISP.
- **Firewall** (`configs/nft/fw-01.nft`) — default drop. Inside → anywhere; Internet → DMZ web 80/443;
  DMZ → the database virtual IP `10.10.20.35:3306` and dns01:53 only; DMZ → Internet 80/443/53;
  everything else counted + logged as `FW-01 DROP`.
- **Core** — VRRP (HSRP equivalent) with core-01 master, LACP Port-Channel between cores and between
  ToRs, MSTP with core-01 as root, OSPF to the firewall + a transit VLAN 99 between cores as backup path,
  ACL `USERS-IN` so users only reach DNS / intranet / app (documented on the cores; cEOS-lab does not
  enforce SVI ACLs in software, so the database servers also run a host firewall that only accepts MariaDB from
  the server VLAN and the DMZ — defense in depth). Gateway failover measured ≈ 2.8 s.
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
| AD01 (Samba AD) | IP + DNS only | optional; install `samba` inside ad01 if needed |
