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
| OS | Windows 11 (Home is fine) or Windows 10 22H2, **virtualization enabled in the BIOS/UEFI** |
| RAM | **32 GB recommended** (WSL gets 16 GB: 4 × cEOS ≈ 5–6 GB, Zabbix ≈ 1 GB, the rest is small). 16 GB machines: see the note in step 1 |
| Disk | ~10 GB free (images ≈ 4 GB + Ubuntu) |
| Accounts | GitHub account (invited to this repo) · free **arista.com** account for the cEOS image |
| Time | ~1 h the first time (mostly downloads and image builds), then 5–8 min per deploy |

Versions used by the team: WSL2 + **Ubuntu 24.04**, **Docker Engine 27.x** (not Docker Desktop),
**Containerlab 0.79.0**, **Arista cEOS-lab 4.33.10M**.

> If you disabled Hyper-V features while fighting GNS3, turn them back on:
> enable **Virtual Machine Platform**, run `bcdedit /set hypervisorlaunchtype auto` (admin), reboot.

## 2. First run — step by step

Do the steps in order. Commands marked **PowerShell** run on Windows; everything else runs in the
**Ubuntu** terminal (Windows Terminal → ˅ → Ubuntu-24.04).

### Step 1 — Install WSL2 and Ubuntu 24.04 (PowerShell as Administrator)

```powershell
wsl --install -d Ubuntu-24.04
```

Reboot if asked, open **Ubuntu-24.04** from the Start menu and create your Linux user and password.
Then check you are on WSL **2** and up to date:

```powershell
wsl --update
wsl -l -v
```

Give WSL enough memory: create `C:\Users\<you>\.wslconfig` with

```ini
[wsl2]
memory=16GB
processors=6
swap=4GB
```

and apply it with `wsl --shutdown` (PowerShell), then reopen Ubuntu.

> **16 GB laptop?** Use `memory=12GB` and, before deploying, comment out the `zbx-db`, `monitor01`
> and `zbx-web` nodes in `mini-dc.clab.yml` (saves ~1 GB).

Check that systemd is running (needed for Docker) — this must print `systemd`:

```bash
ps -p 1 -o comm=
```

If it prints `init`, run `printf '[boot]\nsystemd=true\n' | sudo tee /etc/wsl.conf`, then `wsl --shutdown` (PowerShell) and reopen Ubuntu.

### Step 2 — Install Docker Engine inside Ubuntu

Use Docker's official repository (this is what the lab is tested with):

```bash
sudo apt-get update && sudo apt-get install -y ca-certificates curl git
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
sudo apt-get update
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
sudo usermod -aG docker $USER
```

> ⚠️ **Docker Desktop users:** if Docker Desktop is installed on Windows, open
> *Settings → Resources → WSL integration* and **untick both** "Enable integration with my default WSL distro"
> **and** the Ubuntu-24.04 toggle, then *Apply & restart*. Otherwise Docker Desktop takes over Ubuntu's
> Docker socket and the deploy hangs for 15+ minutes (see Troubleshooting).

### Step 3 — Install Containerlab

```bash
bash -c "$(curl -sL https://get.containerlab.dev)"
sudo usermod -aG clab_admins $USER
```

The new groups (`docker`, `clab_admins`) only apply to new sessions: close Ubuntu, run
`wsl --terminate Ubuntu-24.04` in **PowerShell**, and reopen Ubuntu. Then check:

```bash
groups                               # must list docker and clab_admins
docker run --rm hello-world          # must print "Hello from Docker!"
docker info --format '{{.Name}}'     # must print your PC name, NOT docker-desktop
containerlab version                 # 0.79.x or newer
```

From now on, run `containerlab` **without sudo**.

### Step 4 — Connect Git to GitHub (SSH)

```bash
git config --global user.name "Your Name"
git config --global user.email "you@example.com"
ssh-keygen -t ed25519 -C "$(whoami)@wsl"      # press Enter 3 times
cat ~/.ssh/id_ed25519.pub
```

Copy the printed line into <https://github.com/settings/ssh/new> (type: *Authentication Key*), then test:

```bash
ssh -T git@github.com      # "Hi <username>! You've successfully authenticated"
```

### Step 5 — Clone the repo (Linux filesystem, not `/mnt/c`)

```bash
mkdir -p ~/projects && cd ~/projects
git clone git@github.com:Givemeboga/mini-dc-lab.git
cd mini-dc-lab
```

> Always work under `~/projects/...`. A clone under `/mnt/c/...` is very slow and breaks file
> permissions and line endings for the scripts.

### Step 6 — Get the Arista cEOS image (each member downloads their own)

The image is licensed by Arista, so it is **not** in the repo.

1. Log in on <https://www.arista.com> → **Support → Software Download**.
2. **EOS → Active Releases → 4.33 → EOS-4.33.10M → cEOS-lab** → download `cEOS64-lab-4.33.10M.tar.xz` (~800 MB).
   Take the same version as the team if it is available.
3. Import it (adapt the Windows user name):

```bash
cp /mnt/c/Users/<you>/Downloads/cEOS64-lab-4.33.10M.tar.xz ~/
docker import ~/cEOS64-lab-4.33.10M.tar.xz ceos:latest
docker images ceos                   # ceos  latest  ~2.6 GB
rm ~/cEOS64-lab-4.33.10M.tar.xz      # optional, frees 800 MB
```

The tag **must** be `ceos:latest` — the topology uses that name.

### Step 7 — Build the lab images (`setup.sh`, ~5–10 min)

```bash
./setup.sh
```

It raises the kernel *inotify* limits (asks your sudo password once — several cEOS will not boot
without it), builds `dc-router` (FRR + nftables) and `dc-host` (Debian services), checks `ceos:latest`
and pre-pulls the Zabbix/PostgreSQL images. It ends with `Ready. Deploy with: ./deploy.sh`.

### Step 8 — Deploy the lab (5–8 min)

```bash
./deploy.sh
```

> 🛑 **Never press Ctrl+C in this window** — it cancels the deploy and destroys the lab.
> The output stops for several minutes while the 4 Arista switches boot one after another
> (`startup-delay` 30/60/90 s). That is normal. A message like
> `[deploy.sh] tor-01 booted into rescue mode -> continuing the boot` is also normal: the script fixes it.

To watch progress, open a **second** Ubuntu tab:

```bash
watch -n5 'docker ps --format "table {{.Names}}\t{{.Status}}" | grep clab-mini-dc'
```

The deploy is finished when it prints a table of 30 nodes and `Deployed. Wait ~30 s ...`.

### Step 9 — Check it works

Wait ~30 s (OSPF / spanning tree converge), then:

```bash
./scripts/tests.sh
```

Expected last line: **`Result: 20 passed, 0 failed`**. If a test fails, wait one more minute and run it
again; if it still fails, see [Troubleshooting](#9-troubleshooting).

Register the devices in Zabbix (needed after **every** deploy):

```bash
python3 scripts/zabbix-add-hosts.py
```

Open <http://localhost:8080> in your Windows browser — login `Admin` / `zabbix`. Hosts turn green after 1–2 min.

Optional — the failover demo (cuts ISP A and the VRRP master for a few seconds, then restores them):

```bash
./scripts/tests.sh failover          # expect ≈0.2 s loss for ISP, ≈2.8 s for VRRP
```

### Step 10 — Open the graphical view (VS Code + TopoViewer)

1. Install **VS Code** on Windows and the extensions **WSL** (Microsoft) and **Containerlab** (srl-labs).
2. In Ubuntu, from the lab folder: `code .` (VS Code opens connected to WSL).
3. Click the **Containerlab** icon in the left sidebar → right-click `mini-dc` → **Graph (TopoViewer)**.
4. The layout uses a white canvas: switch VS Code to a light theme (**Ctrl+K Ctrl+T → Light Modern**) so node names are readable.

Right-click a node for SSH / console, right-click a link for a Wireshark capture.

### Step 11 — Stop, and start again later

```bash
containerlab destroy -t mini-dc.clab.yml --cleanup      # stop and remove everything
```

Do this **before** shutting down Windows or running `wsl --shutdown`. The virtual cables between
containers do not survive a WSL restart: if you forgot, Docker restarts the containers half-broken —
just run the destroy command above, then `./deploy.sh` again.

Typical session after the first install:

```bash
cd ~/projects/mini-dc-lab
git pull
./deploy.sh
./scripts/tests.sh
python3 scripts/zabbix-add-hosts.py
# ... work ...
containerlab destroy -t mini-dc.clab.yml --cleanup
```

## 3. Everyday commands & consoles

```bash
./deploy.sh                                        # start (5–8 min)
./scripts/tests.sh                                 # 20 functional tests
./scripts/tests.sh failover                        # failover demo
python3 scripts/zabbix-add-hosts.py                # register devices in Zabbix (after each deploy)
containerlab inspect -t mini-dc.clab.yml           # list nodes and IPs
containerlab destroy -t mini-dc.clab.yml --cleanup # stop
```

**Consoles**

| Device | How |
|---|---|
| cEOS (cores, ToRs) | `ssh admin@clab-mini-dc-core-01` (password `admin`) or `docker exec -it clab-mini-dc-core-01 Cli` |
| FRR routers / FW | `docker exec -it clab-mini-dc-fw-01 vtysh` (routing) or `... sh` (shell, `nft list ruleset`) |
| Servers / PCs | `docker exec -it clab-mini-dc-web01 bash` |
| Zabbix | <http://localhost:8080> — `Admin` / `zabbix` |

The full architecture diagram is in [`docs/architecture.svg`](docs/architecture.svg).

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

First install: follow [section 2](#2-first-run--step-by-step) from step 1.

- **Before you start working:** `git pull` on `main`.
- **One branch per task:** `git switch -c feature/<topic>` → commit → `git push -u origin feature/<topic>` →
  open a pull request on GitHub. No direct pushes to `main`.
- **Run `./scripts/tests.sh` before every pull request** and paste the `Result: 20 passed` line in the description.
- **TopoViewer layout:** `mini-dc.clab.yml.annotations.json` is rewritten whenever someone moves things in the
  graph — agree on one person for layout changes to avoid merge conflicts. Custom icons live in `.clab-icons/`.
- **Not versioned** (see `.gitignore`): `clab-mini-dc/` (generated at every deploy, contains TLS keys),
  logs, layout backups, the cEOS image. Never commit the cEOS `.tar.xz`.
