# Runbooks and disaster recovery

[← Back to the README](../README.md) · Commands: [Daily use](operations.md) · Design: [Architecture](architecture.md)

What the NOC does when something breaks, how each part is maintained without stopping the service (TIA-942
Rated-3 = *concurrently maintainable*), and how the data center is recovered after a disaster. Every procedure
starts from the alarm Zabbix raises (**Monitoring → Problems** or `python3 scripts/zabbix-setup.py problems`).

## Recovery objectives

**RTO** = how long the service may be down. **RPO** = how much data may be lost. "Measured" values come from
`./scripts/tests.sh failover`, `./scripts/db-failover.sh` and `./scripts/backup.sh restore-test` on the lab.

| Service | Protection | RTO target | Measured | RPO |
|---|---|---|---|---|
| Internet access | 2 ISPs, 2 edges (OSPF) | 5 s | ≈ 0.2 s | — |
| Firewalling | fw-01 / fw-02 (BFD, OSPF, conntrackd) | 5 s | ≈ 0.2 s, open connections kept | — |
| Server / user gateways | VRRP load sharing on core-01 / core-02 | 5 s | ≈ 2.8 s (cEOS VRRP adverts are 1 s minimum) | — |
| Public website www.dc.lab | 2 DMZ servers, virtual IP, load balancer | 5 s | ≈ 0.8 s | — |
| Intranet, API | 2 servers each, in 2 racks, virtual IPs | 5 s | ≈ 0.8 s | — |
| DNS | dns01 + ad01 (secondary) | 2 s | ≈ 40 ms per lookup | — |
| Shop database | db01 / db02 replication, virtual IP | 10 s | ≈ 0.6 s (crash), ≈ 1.3 s (server lost) | 0 (no acknowledged write lost) |
| Data after a logical error (deletion, ransomware) | nightly backups, ZFS snapshots | 4 h | restore test passes | ≤ 24 h (last nightly backup) |
| Whole site lost | off-site tapes (design), lab rebuild from git | 72 h | — | ≤ 7 days (weekly tape) |

## Incident procedures

### Firewall down — *"fw-01: OSPF neighbor lost"*, *"DMZ gateway … running on the backup fw-02"*
Impact: none expected — fw-02 already carries the traffic and the open connections.
1. Confirm: `docker exec clab-mini-dc-fw-02 vtysh -c "show ip ospf neighbor"` (4 Full), and that
   `docker exec clab-mini-dc-fw-02 ip -4 addr show eth5` holds 10.10.60.1.
2. Find the cause on fw-01 (`vtysh -c "show bfd peers brief"`, interfaces, logs on syslog01 `fw-01.log`).
3. Bring fw-01 back **gracefully** (no second interruption): `vtysh -c 'conf t' -c 'router ospf' -c 'max-metric router-lsa administrative'`,
   repair, wait for 4 OSPF neighbors Full, then `no max-metric router-lsa administrative`. The DMZ gateway returns after 10 s.

### Core switch down — *"… running on the backup …"*, OSPF/SNMP alarms on core-01 or core-02
Impact: ≈ 3 s for the VLANs it was gateway for, then the other core routes all VLANs.
1. Check `docker exec clab-mini-dc-core-02 Cli -p 15 -c "show vrrp brief"`: all four gateways Master on the survivor.
2. Repair; when the core returns it takes its VLANs back (VRRP preemption) — schedule that in a quiet moment.

### Database server or MariaDB down — *"db.dc.lab running on the backup db02"*, *"MariaDB down on db01"*
Impact: a few seconds of write errors, no acknowledged write lost.
1. `./scripts/db-failover.sh status`: db02 owns 10.10.20.35 and is writable (`read_only = 0`).
2. Repair db01, then `./scripts/db-failover.sh restore`: db01 becomes the replica of db02 (no automatic failback).
3. Check *"Replication broken"* / *"Replication … behind"* clear in Zabbix.

### Web, intranet or API server down — *"… running on the backup …"*, *"… down on webXX"*
Impact: < 1 s. The other server serves alone; the load balancer skips the dead backend.
Repair and restart the server; it takes its virtual IP back by itself.

### DNS server down — *"DNS server dns01 not answering"*
Impact: none (ad01 answers, 1 s timeout per lookup at most). If **both** are down (*disaster*), restart named on
dns01 first: `docker exec clab-mini-dc-dns01 named -u bind -4`; ad01 copies the zone again by itself.

### ISP down — *"edge-rX: OSPF neighbor lost"* / no Internet via one ISP
Impact: ≈ 0.2 s; the other ISP carries everything (the website stays published on both).
Contact the ISP; nothing to change in the data center.

### Storage (TrueNAS) down — iSCSI checks fail, *"Last backup failed"*
Impact: the nightly copy to the SAN fails (backups stay on backup01's disk). TrueNAS is the one accepted single
point of failure (see [architecture](architecture.md)).
1. Console: <http://localhost:6080/vnc_lite.html?scale=true>; `zpool status tank` (a failed mirror disk keeps the pool online).
2. After repair: `python3 scripts/truenas-setup.py` (idempotent), then `./scripts/backup.sh run`.

### Data lost or corrupted (human error, ransomware) — no alarm, reported by users
1. Stop the damage: isolate the affected server (host firewall / link down).
2. `./scripts/backup.sh list`, pick the last good restore point; `./scripts/backup.sh restore-test` proves it restores.
3. Restore the dump as root on the current primary (the backup account can only read): copy it from backup01
   (`docker cp clab-mini-dc-backup01:/srv/backup/db/shop-<date>.sql.gz .` then into db01) and run
   `zcat shop-<date>.sql.gz | mariadb` there; then rebuild the replica with `./scripts/db-failover.sh restore`.
4. If backup01 is affected too: read the copy back from TrueNAS (`restore-test` shows how), or a ZFS snapshot of
   `tank/backup` from before the incident (14 daily snapshots).

### Power or cooling incident — BMS alarms (bms01)
| Alarm | Meaning | Action |
|---|---|---|
| *Utility feed A lost* (average) | STEG feeder 1 down, path A on UPS then generator | Check *Generator A running* appears within 10 s; inform STEG |
| *UPS A on battery* (high) | no input power on path A | If it lasts > 1 min the generator did not start: on-site technician |
| *UPS A battery below 30 %* (disaster) | path A will stop | Everything is dual-corded: it keeps running on path B; prepare for the loss of redundancy |
| *Power path A down* (high) | IT on path B only (2N) | No action on IT; restore path A before any work on path B |
| *Server hall A above 27 °C* / *32 °C* | cooling lost in the hall | Check CRAH units (*fewer than 2 running*); above 32 °C shut down non-critical load |
Demo / drill: `./scripts/facility.sh cooling-failure`, `power-failure`, `generator-failure`, then `restore`.

### Security incident — *"IDS: attack detected"*, *"IPS: attacker blocked"*
Impact: the attacker is blocked at the edge for 10 minutes automatically.
1. `./scripts/attack.sh status` (or syslog01 `/var/log/remote/edge-r1.log`): which rules, which source.
2. Repeated attacks: block permanently in `configs/nft/edge-r*.nft`; report to the ISP's abuse contact.
3. False positive: `./scripts/attack.sh unblock`, then tune `configs/suricata/dc-lab.rules`.
4. Check the target servers' logs on the collectors; if anything got through, follow *Data lost or corrupted*.

## Maintenance without interruption (Rated-3)

| Component | Procedure |
|---|---|
| Firewall | graceful removal: `max-metric router-lsa administrative` on the firewall → traffic moves to the other one, connections kept; maintain; graceful return (see above) |
| Core switch | lower its VRRP priorities below 100 for its VLANs (the other core takes them), maintain, restore the priorities |
| Database | maintain the **replica** first; to maintain the primary, fail over on purpose (`./scripts/db-failover.sh`), then `restore` |
| Web / intranet / API server | stop it: the virtual IP moves in < 1 s; maintain; start it |
| Power path A or B | close the TGBT bus coupler only for transformer / ATS work; every rack stays fed by the other path |
| Cooling | one CRAH per hall at a time (N+1); one chiller at a time (each carries the whole site) |

Before and after every intervention: `./scripts/tests.sh` must report **0 failed** and Zabbix 0 problems.

## Disaster recovery (site lost)

1. Infrastructure as code: the whole network and server configuration is in git — `git clone`, `./setup.sh`,
   `./deploy.sh` rebuilds the lab in ≈ 10 minutes on any machine with the prerequisites ([setup guide](setup.md)).
2. Secrets: `lab.env` and `pki/` are **not** in git — keep an encrypted copy off site (password manager or safe).
3. Data: restore the latest dump from the off-site copy (weekly tape in the design; in the lab, a copy of
   `/srv/backup` from backup01), then `./scripts/backup.sh restore-test`.
4. Switch configurations: the nightly archive `switches-<date>.tar.gz` holds each switch's running config.

## Drills

| What | How often | Command |
|---|---|---|
| Functional checks | after every change | `./scripts/tests.sh` |
| Failover of every redundant pair | monthly | `./scripts/tests.sh failover`, `./scripts/db-failover.sh` + `restore` |
| Restore from backup | monthly | `./scripts/backup.sh restore-test` |
| Facility incident | quarterly | `./scripts/tests.sh monitoring` |
| Security incident | quarterly | `./scripts/tests.sh attack` |
