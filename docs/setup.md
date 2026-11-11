# First-time setup

[← Back to the README](../README.md) · Next: [Daily use](operations.md)

From a fresh Windows laptop to a running, tested data center — about **1 hour** the first time
(mostly downloads and image builds), then 5–8 minutes per deploy.

## What you need

| | |
|---|---|
| **OS** | Windows 11 (Home is fine), **virtualization enabled in BIOS/UEFI** (TrueNAS runs under KVM inside WSL) |
| **RAM** | **32 GB recommended** — WSL gets 24 GB (4 × cEOS ≈ 5–6 GB, TrueNAS VM 8 GB, Zabbix ≈ 1 GB). 16 GB laptops: see step 1 |
| **Disk** | ~20 GB free (images, TrueNAS ISO and virtual disks) |
| **Accounts** | GitHub (invited to this repo) · free **arista.com** account for the cEOS image |

**Team versions:** WSL2 + Ubuntu 24.04 · Docker Engine 27.x (*not* Docker Desktop) · Containerlab 0.79.0 ·
Arista cEOS-lab 4.33.10M · TrueNAS SCALE 25.10.7

> [!NOTE]
> Commands marked **PowerShell** run on Windows. Everything else runs in the **Ubuntu** terminal
> (Windows Terminal → ˅ → Ubuntu-24.04). Do the steps in order.

| Step | What | Time |
|:---:|---|:---:|
| 1 | [Install WSL2 + Ubuntu 24.04](#step-1--install-wsl2-and-ubuntu-2404) | 10 min |
| 2 | [Install Docker Engine](#step-2--install-docker-engine) | 5 min |
| 3 | [Install Containerlab](#step-3--install-containerlab) | 3 min |
| 4 | [Connect Git to GitHub](#step-4--connect-git-to-github) | 3 min |
| 5 | [Clone the repo](#step-5--clone-the-repo) | 1 min |
| 6 | [Get the cEOS image and the TrueNAS ISO](#step-6--get-the-ceos-image-and-the-truenas-iso) | 15 min |
| 7 | [Build the lab images](#step-7--build-the-lab-images) | 5–10 min |
| 8 | [Deploy the lab](#step-8--deploy-the-lab) | 5–8 min |
| 9 | [Install and configure TrueNAS](#step-9--install-and-configure-truenas-first-time-only) | 20 min |
| 10 | [Check it works](#step-10--check-it-works) | 2 min |
| 11 | [Open the graphical view](#step-11--open-the-graphical-view) | 5 min |
| 12 | [Stop the lab](#step-12--stop-the-lab) | 1 min |

---

## Step 1 — Install WSL2 and Ubuntu 24.04

**PowerShell (as Administrator):**

```powershell
wsl --install -d Ubuntu-24.04
```

Reboot if asked, open **Ubuntu-24.04** from the Start menu and create your Linux user. Then:

```powershell
wsl --update
wsl -l -v          # VERSION column must say 2
```

Give WSL enough memory — create `C:\Users\<you>\.wslconfig`:

```ini
[wsl2]
memory=24GB
processors=6
swap=4GB
```

Apply it with `wsl --shutdown` (PowerShell) and reopen Ubuntu.

> [!TIP]
> **16 GB laptop?** Use `memory=12GB`, comment out the `zbx-db`, `monitor01` and `zbx-web` nodes in
> `mini-dc.clab.yml` (saves ~1 GB) and give TrueNAS 4 GB: add `env: {TRUENAS_RAM: "4096"}` to `storage01`.

✅ **Check** — systemd must be running (Docker needs it) and KVM must exist (TrueNAS needs it):

```bash
ps -p 1 -o comm=      # systemd
ls /dev/kvm           # /dev/kvm
```

If it prints `init`: `printf '[boot]\nsystemd=true\n' | sudo tee /etc/wsl.conf`, then `wsl --shutdown` and reopen Ubuntu.

---

## Step 2 — Install Docker Engine

Inside Ubuntu, from Docker's official repository (what the lab is tested with):

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

> [!WARNING]
> **Docker Desktop installed on Windows?** Open *Settings → Resources → WSL integration* and **untick both**
> "Enable integration with my default WSL distro" **and** the Ubuntu-24.04 toggle, then *Apply & restart*.
> Otherwise Docker Desktop takes over Ubuntu's Docker socket and the deploy hangs for 15+ minutes.

---

## Step 3 — Install Containerlab

```bash
bash -c "$(curl -sL https://get.containerlab.dev)"
sudo usermod -aG clab_admins $USER
```

The new groups only apply to new sessions: close Ubuntu, run `wsl --terminate Ubuntu-24.04` in
**PowerShell**, and reopen Ubuntu.

✅ **Check:**

```bash
groups                               # lists docker and clab_admins
docker run --rm hello-world          # "Hello from Docker!"
docker info --format '{{.Name}}'     # your PC name — NOT docker-desktop
containerlab version                 # 0.79.x or newer
```

From now on, run `containerlab` **without sudo**.

---

## Step 4 — Connect Git to GitHub

```bash
git config --global user.name "Your Name"
git config --global user.email "you@example.com"
ssh-keygen -t ed25519 -C "$(whoami)@wsl"      # press Enter 3 times
cat ~/.ssh/id_ed25519.pub
```

Paste the printed line into <https://github.com/settings/ssh/new> (type: *Authentication Key*).

✅ **Check:**

```bash
ssh -T git@github.com      # "Hi <username>! You've successfully authenticated"
```

---

## Step 5 — Clone the repo

```bash
mkdir -p ~/projects && cd ~/projects
git clone git@github.com:Givemeboga/mini-dc-lab.git
cd mini-dc-lab
```

> [!CAUTION]
> Always clone under `~/projects/...` (Linux filesystem). A clone under `/mnt/c/...` is very slow
> and breaks script permissions and line endings.

---

## Step 6 — Get the cEOS image and the TrueNAS ISO

The Arista image is licensed, so it is **not** in the repo — each member downloads their own.

1. Log in on <https://www.arista.com> → **Support → Software Download**.
2. **EOS → Active Releases → 4.33 → EOS-4.33.10M → cEOS-lab** → `cEOS64-lab-4.33.10M.tar.xz` (~800 MB).
3. Import it (adapt the Windows user name):

```bash
cp /mnt/c/Users/<you>/Downloads/cEOS64-lab-4.33.10M.tar.xz ~/
docker import ~/cEOS64-lab-4.33.10M.tar.xz ceos:latest
rm ~/cEOS64-lab-4.33.10M.tar.xz      # optional, frees 800 MB
```

✅ **Check** — `docker images ceos` shows `ceos  latest  ~2.6GB`. The tag **must** be `ceos:latest`.

Then download the TrueNAS SCALE ISO (2.3 GB) into `truenas/` and verify it:

```bash
mkdir -p truenas && cd truenas
U=https://download.sys.truenas.net/TrueNAS-SCALE-Goldeye/25.10.7
curl -fLO $U/TrueNAS-SCALE-25.10.7.iso -fLO $U/TrueNAS-SCALE-25.10.7.iso.sha256
echo "$(cat TrueNAS-SCALE-25.10.7.iso.sha256)  TrueNAS-SCALE-25.10.7.iso" | sha256sum -c -   # ...: OK
cd ..
```

`truenas/` is in `.gitignore`: the ISO and the VM disks never go to GitHub.

---

## Step 7 — Build the lab images

```bash
./setup.sh
```

What it does:
- raises the kernel *inotify* limits (asks your sudo password once — several cEOS won't boot without it);
- builds `dc-router` (FRR + nftables), `dc-host` (Debian services + keepalived) and `dc-truenas` (QEMU for the TrueNAS VM);
- checks `ceos:latest` and pre-pulls the Zabbix / PostgreSQL images.

✅ **Check** — it ends with `Ready. Deploy with: ./deploy.sh`.

---

## Step 8 — Deploy the lab

```bash
./deploy.sh
```

> [!CAUTION]
> **Never press Ctrl+C in this window** — it cancels the deploy and destroys the lab.
> The output stops for several minutes while the 4 Arista switches boot one after another. That is normal.
> `[deploy.sh] tor-01 booted into rescue mode -> continuing the boot` is also normal: the script fixes it.

Watch progress from a **second** Ubuntu tab:

```bash
watch -n5 'docker ps --format "table {{.Names}}\t{{.Status}}" | grep clab-mini-dc'
```

✅ **Check** — the deploy prints a table of **31 nodes** and `Deployed. Wait ~30 s ...`.
If it says *"An old copy of the lab exists"* (after a reboot), answer `y`. If it says `Deploy FAILED`, read the ERROR above it.

---

## Step 9 — Install and configure TrueNAS (first time only)

`storage01` runs **TrueNAS SCALE** as a virtual machine. On the first deploy its disk is empty, so it boots the installer.

1. Open the VM console in your Windows browser: **<http://localhost:6080/vnc_lite.html?scale=true>** and click inside it.
2. **`1 Install/Upgrade`** → tick only **`vda` (32 GiB)** with Space → Enter → **Yes**.
   Do **not** tick `vdb` / `vdc` (20 GiB): they become the ZFS pool.
3. **`1 Administrative user (truenas_admin)`** → choose a password (lab default: `truenas`) → keep the other defaults.
4. "Installation succeeded" → **`3 Reboot System`**. After 2–4 min the console shows *Console setup* with options 1–10.
5. Configure it (it asks for the password if it is not `truenas`):

```bash
python3 scripts/truenas-setup.py
```

It sets the SAN address `10.10.30.10/24`, creates the ZFS mirror pool `tank`, the zvols `tank/db` (10 GiB) and
`tank/backup` (4 GiB), and the iSCSI targets `iqn.2026-09.lab.dc:storage01.db` (only db01) and `...:storage01.backup`
(only backup01). Safe to run again.

✅ **Check** — it ends with `Done.` Web UI: **<https://localhost:8443>** (`truenas_admin`, accept the self-signed certificate).

> [!NOTE]
> The installed TrueNAS and its configuration live in `truenas/*.qcow2` and survive destroy / deploy.
> You only do this step once per machine.

---

## Step 10 — Check it works

Wait ~30 s for OSPF and spanning tree to converge, then:

```bash
./scripts/tests.sh
```

✅ **Check** — last line: **`Result: 27 passed, 0 failed`** (the backup check needs the first backup, 6 min after deploy).
A test failed? Wait a minute and run it again, then see [Troubleshooting](troubleshooting.md).

Register the devices in Zabbix (needed after **every** deploy), then open <http://localhost:8080>
in your Windows browser — user `Admin`, password `ZBX_ADMIN_PASS` from `lab.env` (the script replaces the
default `zabbix` password on its first run):

```bash
python3 scripts/zabbix-add-hosts.py
```

Check the database redundancy — db01 must own the virtual IP and db02 must be in sync:

```bash
./scripts/db-failover.sh status
```

---

## Step 11 — Open the graphical view

1. Install **VS Code** on Windows with the extensions **WSL** (Microsoft) and **Containerlab** (srl-labs).
2. In Ubuntu, from the lab folder: `code .`
3. Containerlab icon in the sidebar → right-click `mini-dc` → **Graph (TopoViewer)**.
4. Switch VS Code to a light theme (**Ctrl+K Ctrl+T → Light Modern**) — the layout uses a white canvas.

Right-click a node for SSH / console, right-click a link for a Wireshark capture.
You should see this layout ([screenshot](topoviewer.png)); interface names appear when you click a link.

---

## Step 12 — Stop the lab

```bash
docker exec clab-mini-dc-storage01 sh -c 'echo system_powerdown | socat - UNIX-CONNECT:/run/qemu-monitor.sock'   # clean TrueNAS shutdown
containerlab destroy -t mini-dc.clab.yml --cleanup
```

Forgot before a reboot? Docker restarts the containers half-broken — `./deploy.sh` detects it and offers to clean up.

🎉 **Setup done.** Next time, use the [Quick start](../README.md#quick-start) and the [daily use guide](operations.md).
