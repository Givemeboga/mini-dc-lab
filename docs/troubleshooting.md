# Troubleshooting

[← Back to the README](../README.md) · [Daily use](operations.md) · [First-time setup](setup.md)

## Install / Docker

| Symptom | Fix |
|---|---|
| `docker: permission denied` | `sudo usermod -aG docker $USER`, then `wsl --terminate Ubuntu-24.04` and reopen |
| Deploy hangs 15+ min at "Running postdeploy actions", `docker ps` shows no lab | Docker Desktop took over the socket — `docker info --format '{{.Name}}'` says `docker-desktop`. In Docker Desktop → *Settings → Resources → WSL integration*, untick **"Enable integration with my default WSL distro"** and the Ubuntu toggle, then `wsl --shutdown` |
| Image build fails with "Unable to locate package" for every package | Temporary network failure during `apt-get update` — run `./setup.sh` again |
| Not enough RAM | Comment out `zbx-*` and `monitor01`, or raise `memory=` in `%UserProfile%\.wslconfig` |
| `wsl` says *Catastrophic failure* | Quit Docker Desktop, `wsl --shutdown`, wait 10 s, retry; if it persists, restart Windows |

## Deploy / switches

| Symptom | Fix |
|---|---|
| Deploy silent for minutes | Normal while cEOS boots; `deploy.sh` also fixes a switch stuck in *rescue mode* |
| *"An old copy of the lab exists"* | After a reboot the old containers are half-broken — answer `y` |
| A switch never gets `Uptime` | `docker logs --tail 10 clab-mini-dc-tor-01` → if it says *rescue mode*: `docker exec clab-mini-dc-tor-01 systemctl default --no-block` |
| cEOS fails to boot with several switches | inotify limits too low — `setup.sh` raises them (`fs.inotify.max_user_instances=8192`) |
| VS Code: "VS Code Server for WSL closed unexpectedly" | The server install was corrupted (e.g. a reboot during install): `mv ~/.vscode-server/bin/<id> ~/.vscode-server/bin/<id>.broken`, then `code .` again |

## Network / services

| Symptom | Fix |
|---|---|
| OSPF core ↔ fw-01 stuck in EXCH START | MTU: `docker exec clab-mini-dc-fw-01 ip link set eth3 mtu 1500` (same for eth4) |
| Large transfers between racks hang, pings work | Server MTU is not 1500 (cEOS ports carry max 9214 B) — `init-host.sh` sets it; check `cat /sys/class/net/eth1/mtu` |
| Hosts can't reach the Internet | Check `docker exec clab-mini-dc-fw-01 vtysh -c "show ip route"` has a default route |
| noc-sw / user-sw no traffic for ~30 s | Spanning tree converging with the Linux bridges — wait |
| Zabbix page not loading | Wait 1–2 min after deploy (database initialisation) |

## Database (MariaDB HA)

| Symptom | Fix |
|---|---|
| `db-failover.sh` says "not replicating" | A previous test left a node failed: `./scripts/db-failover.sh restore` (or redeploy) |
| `restore` stuck for more than 30 s | Ctrl+C is safe here, then run `restore` again; check the server MTU is 1500 |
| Nobody owns the virtual IP | Redeploy the lab |

## TrueNAS / storage

| Symptom | Fix |
|---|---|
| The 3 iSCSI tests fail right after a deploy | TrueNAS is still booting: check the console, wait 2–4 min, run the tests again |
| VM console page stays black / spinning | Use the lite page: <http://localhost:6080/vnc_lite.html?scale=true> |
| `truenas-setup.py`: "Login refused" | Wrong password; forgotten? console option **4) Change local administrator password** |
| storage01 boots the installer again | `truenas/boot.qcow2` was deleted or is empty: reinstall ([setup step 9](setup.md#step-9--install-and-configure-truenas-first-time-only)) |
| TrueNAS slow / out of memory | `free -g` in WSL must show ~23 GB (`memory=24GB`); lower `TRUENAS_RAM` on 16 GB laptops |
