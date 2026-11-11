<div align="center">

# RAM+ Data Center — Containerlab Lab

**A complete data center (network + buildings) emulated with containers on a Windows laptop.**
No GNS3 VM — just WSL2, Docker and Containerlab.

![Containerlab](https://img.shields.io/badge/Containerlab-0.79-0b6ba8)
![Arista cEOS](https://img.shields.io/badge/Arista_cEOS-4.33.10M-1f5fbf)
![FRRouting](https://img.shields.io/badge/FRRouting-OSPF-7c3aed)
![nftables](https://img.shields.io/badge/firewall-nftables-e4572e)
![TrueNAS](https://img.shields.io/badge/TrueNAS_SCALE-25.10-0095d5)
![MariaDB HA](https://img.shields.io/badge/MariaDB-HA_keepalived-c0765a)
![Zabbix](https://img.shields.io/badge/Zabbix-7.0-d40000)
![Tests](https://img.shields.io/badge/tests-27%2F27_passing-22a06b)

*School project — ESPRIT, cybersecurity & cloud engineering*

[Quick start](#quick-start) · [Setup guide](docs/setup.md) · [Daily use](docs/operations.md) · [Architecture](docs/architecture.md) · [Testing guide](docs/testing-guide/RAM+_Data_Center_Testing_Guide.pdf) · [Troubleshooting](docs/troubleshooting.md)

<br>

<img src="docs/architecture.svg" alt="RAM+ data center architecture: ISPs, edges, firewall, cores, ToRs, racks, SAN, NOC and management" width="100%">

</div>

---

## What's inside

| | |
|---|---|
| **Scale** | 32 containers · 40 links · 3 buildings · out-of-band management network `10.10.10.0/24` |
| **Internet edge** | 2 ISPs (NAT to the real Internet) · 2 FRR edge routers with NAT and port-forwards |
| **Security** | **2 firewalls** (FRR + nftables, default drop; fw-02 standby) · host firewall on every server · no secrets in git (generated `lab.env` + lab CA) |
| **Public website** | `https://www.dc.lab` — TLS, HTTP→HTTPS, load balancer over 2 DMZ servers behind a keepalived virtual IP |
| **Core / access** | 2 Arista cEOS cores (VRRP load sharing, LACP, MSTP, OSPF) · 2 cEOS top-of-rack switches, dual-homed |
| **Servers** | nginx intranet, Python API, BIND9 DNS, AD (IP/DNS), backup · **MariaDB primary + replica** behind a keepalived virtual IP |
| **Storage** | **TrueNAS SCALE 25.10** (KVM VM inside the lab): ZFS mirror, one iSCSI LUN per server with ACL, isolated SAN |
| **Backups** | nightly job on backup01: database + switch configs, checksums, 7 restore points, copy on TrueNAS (ZFS snapshots), automatic restore test |
| **Operations** | NOC with rsyslog from every switch · Zabbix 7 (SNMP + ICMP) on the OOB network |

## Measured results

| Feature | How | Result |
|---|---|---|
| ISP failover | each edge announces its default route in OSPF (cost 10 / 20) | **≈ 0.2 s** |
| Gateway failover | VRRP on the cores, servers keep the `.1` gateway | **≈ 2.8 s** |
| Database failover | MariaDB replication + keepalived virtual IP `10.10.20.35` | **≈ 2.3 s** crash · **≈ 3.8 s** server offline · no data lost |
| Firewall policy | nftables default drop + host firewalls — allowed and forbidden flows checked rule by rule | allowed / blocked as designed |
| Storage isolation | per-server iSCSI target, SAN VLAN not routed | other LUN denied |
| Automated checks | `./scripts/tests.sh` | **27 / 27 passing** |

## Quick start

Already installed? From the Ubuntu terminal:

```bash
cd ~/projects/mini-dc-lab
git pull
./deploy.sh                           # 5–8 min — never press Ctrl+C
./scripts/tests.sh                    # wait 2–4 min for TrueNAS first; expect 27 passed, 0 failed
python3 scripts/zabbix-add-hosts.py   # Zabbix: http://localhost:8080 (Admin / password in lab.env)
```

When you are done:

```bash
containerlab destroy -t mini-dc.clab.yml --cleanup
```

> [!IMPORTANT]
> Destroy the lab **before** shutting down Windows or running `wsl --shutdown` — the virtual cables do not
> survive a WSL restart. First time here? Follow the **[setup guide](docs/setup.md)** (about 1 hour).

## Documentation

| Document | Read it when you want to… |
|---|---|
| **[Setup guide](docs/setup.md)** | install everything on a new laptop — WSL, Docker, Containerlab, cEOS, TrueNAS (12 steps) |
| **[Daily use](docs/operations.md)** | start / stop the lab, find a command, a console or a web UI, run the failover tests |
| **[Architecture](docs/architecture.md)** | understand the design: mapping to the buildings, addressing, how each feature works |
| **[Testing guide (PDF)](docs/testing-guide/RAM+_Data_Center_Testing_Guide.pdf)** | demo or verify every layer, with the expected result and why it matters |
| **[Troubleshooting](docs/troubleshooting.md)** | fix something that does not work |
| **[Team workflow](docs/contributing.md)** | change something: branches, tests, repository layout, updating the docs |

## Repository at a glance

```
mini-dc.clab.yml        topology (32 nodes)              deploy.sh   start the lab
configs/                switch, router, firewall      setup.sh    build the images (once)
scripts/                boot scripts, tests,          images/     Dockerfiles
                        failover + TrueNAS tools      docs/       documentation + diagrams
```

Full file list: [Team workflow → Repository layout](docs/contributing.md#repository-layout).

## Status

Validated on Windows 11 Home + WSL2 (Ubuntu 24.04, 32 GB RAM): VRRP, LACP, MSTP, OSPF, ISP failover,
firewall pair, NAT / port-forwards, firewall + host firewall policy, HTTPS load balancer, DNS, database high
availability, backups with restore test, iSCSI on TrueNAS SCALE with per-server ACL, storage isolation, syslog —
**27/27 automated checks passing**.
