#!/usr/bin/env python3
"""Configure TrueNAS (storage01) for the lab through its JSON-RPC WebSocket API.

Run from the lab folder after TrueNAS is installed and booted:
    python3 scripts/truenas-setup.py            # tries $TRUENAS_PASSWORD (default "truenas"), else asks

Idempotent: it only creates what is missing.
  - SAN NIC (MAC 52:54:00:30:00:10) -> static 10.10.30.10/24, no gateway (VLAN 30 is not routed)
  - ZFS pool "tank" = mirror of the two data disks, zvols tank/db (10 GiB) and tank/backup (4 GiB)
  - iSCSI: base name iqn.2026-09.lab.dc, portal 10.10.30.10:3260,
    targets storage01.db (only db01 10.10.30.30) and storage01.backup (only backup01 10.10.30.40), LUN 1
  - periodic ZFS snapshots: tank/backup daily 02:30 kept 14 days (versions of the nightly backup copy),
    tank/db every hour kept 24 hours
Uses only the Python standard library (minimal WebSocket client below).
"""
import base64, json, os, socket, ssl, struct, sys, time

HOST = os.environ.get("TRUENAS_HOST", "10.10.10.107")   # storage01 mgmt IP, QEMU forwards :443 to the VM
USER = os.environ.get("TRUENAS_USER", "truenas_admin")
PASSWORD = os.environ.get("TRUENAS_PASSWORD", "truenas")

SAN_MAC, SAN_IP = "52:54:00:30:00:10", "10.10.30.10"
MGMT_MAC = "52:54:00:10:01:07"                           # QEMU user-mode NIC, web UI / API path
BASENAME = "iqn.2026-09.lab.dc"
GIB = 1024 ** 3
TARGETS = [  # (target name, zvol, size GiB, allowed initiator network) - pool = 2 x 20 GiB mirror
    ("storage01.db", "tank/db", 10, "10.10.30.30/32"),
    ("storage01.backup", "tank/backup", 4, "10.10.30.40/32"),
]


# ------------------------------------------------------------------ minimal WebSocket JSON-RPC client
class Rpc:
    def __init__(self, host):
        ctx = ssl.create_default_context()
        ctx.check_hostname, ctx.verify_mode = False, ssl.CERT_NONE   # TrueNAS self-signed certificate
        self.s = ctx.wrap_socket(socket.create_connection((host, 443), timeout=60), server_hostname=host)
        key = base64.b64encode(os.urandom(16)).decode()
        self.s.sendall((f"GET /api/current HTTP/1.1\r\nHost: {host}\r\nUpgrade: websocket\r\n"
                        f"Connection: Upgrade\r\nSec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n\r\n").encode())
        head = b""
        while b"\r\n\r\n" not in head:
            head += self.s.recv(1)
        if b" 101 " not in head.split(b"\r\n")[0]:
            raise RuntimeError("WebSocket handshake failed: " + head.split(b"\r\n")[0].decode())
        self.n = 0

    def _send(self, text):
        data, mask = text.encode(), os.urandom(4)
        hdr = bytes([0x81])
        ln = len(data)
        hdr += bytes([0x80 | ln]) if ln < 126 else (bytes([0x80 | 126]) + struct.pack(">H", ln) if ln < 65536
                                                   else bytes([0x80 | 127]) + struct.pack(">Q", ln))
        self.s.sendall(hdr + mask + bytes(b ^ mask[i % 4] for i, b in enumerate(data)))

    def _exact(self, n):
        buf = b""
        while len(buf) < n:
            chunk = self.s.recv(n - len(buf))
            if not chunk:
                raise ConnectionError("connection closed")
            buf += chunk
        return buf

    def _recv(self):
        msg = b""
        while True:
            b1, b2 = self._exact(2)
            ln = b2 & 0x7F
            if ln == 126: ln = struct.unpack(">H", self._exact(2))[0]
            elif ln == 127: ln = struct.unpack(">Q", self._exact(8))[0]
            payload = self._exact(ln)
            op = b1 & 0x0F
            if op == 0x9:                       # ping -> pong
                self.s.sendall(bytes([0x8A, 0x80 | len(payload)]) + b"\0\0\0\0" + payload); continue
            if op == 0x8: raise ConnectionError("server closed the WebSocket")
            msg += payload
            if b1 & 0x80: return msg.decode()

    def call(self, method, *params):
        self.n += 1
        self._send(json.dumps({"jsonrpc": "2.0", "id": self.n, "method": method, "params": list(params)}))
        while True:
            r = json.loads(self._recv())
            if r.get("id") == self.n:
                if "error" in r:
                    raise RuntimeError(f"{method}: {json.dumps(r['error'])[:600]}")
                return r.get("result")

    def job(self, method, *params, timeout=600):
        jid = self.call(method, *params)
        t0 = time.time()
        while time.time() - t0 < timeout:
            j = self.call("core.get_jobs", [["id", "=", jid]])[0]
            if j["state"] == "SUCCESS": return j["result"]
            if j["state"] in ("FAILED", "ABORTED"): raise RuntimeError(f"{method}: {j.get('error')}")
            time.sleep(2)
        raise TimeoutError(method)


def login(c, password):
    r = c.call("auth.login_ex", {"mechanism": "PASSWORD_PLAIN", "username": USER, "password": password})
    return r.get("response_type") == "SUCCESS"


def connect(tries=60):
    global PASSWORD
    for _ in range(tries):
        try:
            c = Rpc(HOST)
        except (OSError, RuntimeError, ConnectionError):
            time.sleep(5)
            continue
        if login(c, PASSWORD):
            return c
        if sys.stdin.isatty():                      # wrong/unknown password: ask, hidden input
            import getpass
            PASSWORD = getpass.getpass(f"TrueNAS password for {USER}: ")
            if login(c, PASSWORD):
                return c
        sys.exit(f"Login refused for {USER} - run again with the password chosen at install "
                 f"(prompt, or TRUENAS_PASSWORD=... in the environment)")
    sys.exit(f"TrueNAS API not reachable on https://{HOST} - is the VM installed and booted?")


def step(msg): print(f"  - {msg}")


def main():
    print(f"== TrueNAS setup on {HOST}")
    c = connect()
    step(f"connected, TrueNAS {c.call('system.version')}")

    # ---- interfaces: SAN static, management (QEMU user net) explicitly DHCP.
    # Once one interface is configured, TrueNAS stops DHCP on unconfigured ones - so both are set together.
    ifaces = c.call("interface.query")
    by_mac = {i.get("state", {}).get("link_address", "").lower(): i for i in ifaces}
    san, mgmt = by_mac.get(SAN_MAC), by_mac.get(MGMT_MAC)
    if san is None or mgmt is None:
        sys.exit(f"NICs not found (SAN {SAN_MAC}, mgmt {MGMT_MAC}): {list(by_mac)}")
    if any(a.get("address") == SAN_IP for a in san.get("aliases", [])) and mgmt.get("ipv4_dhcp"):
        step(f"{san['name']} already {SAN_IP}/24, {mgmt['name']} DHCP")
    else:
        c.call("interface.update", mgmt["name"], {"ipv4_dhcp": True, "ipv6_auto": False, "aliases": []})
        c.call("interface.update", san["name"],
               {"ipv4_dhcp": False, "ipv6_auto": False, "aliases": [{"type": "INET", "address": SAN_IP, "netmask": 24}]})
        c.s.settimeout(10)                          # the commit restarts the NIC we are connected through
        try:
            c.call("interface.commit", {"rollback": True, "checkin_timeout": 120})
        except OSError:
            pass
        for _ in range(20):                         # reconnect within the 120 s window and confirm
            time.sleep(4)
            try:
                c = connect(tries=1)
                c.call("interface.checkin")
                break
            except (OSError, RuntimeError, SystemExit):
                continue
        else:
            sys.exit("could not confirm the network change - TrueNAS rolled it back; run the script again")
        step(f"{san['name']} set to {SAN_IP}/24 (SAN, no gateway), {mgmt['name']} DHCP (management)")

    # ---- pool + zvols
    if c.call("pool.query", [["name", "=", "tank"]]):
        step("pool tank exists")
    else:
        disks = [d["name"] for d in c.call("disk.query") if str(d.get("serial", "")).startswith("DATA")]
        if len(disks) < 2:
            sys.exit(f"data disks not found (got {disks})")
        c.job("pool.create", {"name": "tank", "topology": {"data": [{"type": "MIRROR", "disks": sorted(disks)[:2]}]}})
        step(f"pool tank created (mirror {' + '.join(sorted(disks)[:2])})")
    for _, zvol, size, _ in TARGETS:
        if not c.call("pool.dataset.query", [["id", "=", zvol]]):
            c.call("pool.dataset.create", {"name": zvol, "type": "VOLUME", "volsize": size * GIB, "volblocksize": "16K"})
            step(f"zvol {zvol} created ({size} GiB)")

    # ---- iSCSI
    c.call("iscsi.global.update", {"basename": BASENAME})
    portal = next((p for p in c.call("iscsi.portal.query")
                   if any(l.get("ip") == SAN_IP for l in p.get("listen", []))), None)
    if portal is None:
        portal = c.call("iscsi.portal.create", {"listen": [{"ip": SAN_IP}], "comment": "SAN VLAN 30"})
        step(f"portal {SAN_IP}:3260 created")
    initiator = next((i for i in c.call("iscsi.initiator.query") if i.get("comment") == "lab-any"), None) \
        or c.call("iscsi.initiator.create", {"initiators": [], "comment": "lab-any"})
    for name, zvol, _, net in TARGETS:
        t = next(iter(c.call("iscsi.target.query", [["name", "=", name]])), None)
        if t is None:
            t = c.call("iscsi.target.create", {"name": name, "auth_networks": [net],
                                               "groups": [{"portal": portal["id"], "initiator": initiator["id"]}]})
        e = next(iter(c.call("iscsi.extent.query", [["name", "=", name]])), None) \
            or c.call("iscsi.extent.create", {"name": name, "type": "DISK", "disk": f"zvol/{zvol}"})
        if not c.call("iscsi.targetextent.query", [["target", "=", t["id"]]]):
            c.call("iscsi.targetextent.create", {"target": t["id"], "extent": e["id"], "lunid": 1})
        step(f"target {BASENAME}:{name} -> {zvol} (LUN 1), allowed from {net}")

    c.call("service.update", "iscsitarget", {"enable": True})
    try:
        c.job("service.control", "START", "iscsitarget")
    except RuntimeError:
        c.call("service.start", "iscsitarget")
    step("iSCSI service enabled and started")

    # ---- snapshots: the backup LUN is overwritten every night by backup01 (scripts/backup.sh),
    # the snapshots keep the previous versions (ransomware / mistake protection)
    for ds, lifetime, unit, sched in [("tank/backup", 14, "DAY", {"minute": "30", "hour": "2"}),
                                      ("tank/db", 24, "HOUR", {"minute": "0", "hour": "*"})]:
        if c.call("pool.snapshottask.query", [["dataset", "=", ds]]):
            step(f"snapshot task for {ds} exists")
            continue
        c.call("pool.snapshottask.create", {
            "dataset": ds, "recursive": False, "lifetime_value": lifetime, "lifetime_unit": unit,
            "naming_schema": "auto-%Y-%m-%d_%H-%M", "enabled": True, "allow_empty": True,
            "schedule": {**sched, "dom": "*", "month": "*", "dow": "*"}})
        step(f"snapshot task: {ds} at {sched['hour']}:{sched['minute'].zfill(2)}, kept {lifetime} {unit.lower()}s")
    print("Done. Check with: ./scripts/tests.sh")


if __name__ == "__main__":
    main()
