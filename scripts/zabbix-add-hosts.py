#!/usr/bin/env python3
"""Registers every lab device in Zabbix (run once after deploy, from WSL):
      python3 scripts/zabbix-add-hosts.py
Zabbix web UI: http://localhost:8080  (user Admin, password = ZBX_ADMIN_PASS in lab.env)
On the first run the default password "zabbix" is replaced by the one from lab.env.
The Zabbix server (monitor01) polls everything over the OOB management network."""
import json, os, time, urllib.request

ENV = {}
_env = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "lab.env")
if os.path.exists(_env):
    for line in open(_env):
        if "=" in line and not line.lstrip().startswith("#"):
            k, v = line.strip().split("=", 1); ENV[k] = v
ADMIN_PASS = ENV.get("ZBX_ADMIN_PASS", "zabbix")

URL = "http://localhost:8080/api_jsonrpc.php"
SNMP_COMMUNITY = "dclab"

# name -> OOB management IP
SWITCHES = {"core-01": "10.10.10.11", "core-02": "10.10.10.12",
            "tor-01": "10.10.10.21", "tor-02": "10.10.10.22"}
PING_ONLY = {"edge-r1": "10.10.10.31", "edge-r2": "10.10.10.32", "fw-01": "10.10.10.40", "fw-02": "10.10.10.41",
             "web01": "10.10.10.101", "app01": "10.10.10.102", "dns01": "10.10.10.103",
             "db01": "10.10.10.104", "ad01": "10.10.10.105", "backup01": "10.10.10.106",
             "storage01": "10.10.10.107", "web-dmz01": "10.10.10.108", "web-dmz02": "10.10.10.109",
             "syslog01": "10.10.10.110", "db02": "10.10.10.114",
             "web02": "10.10.10.115", "app02": "10.10.10.116", "noc-ws": "10.10.10.111"}

token = None
def api(method, params):
    body = json.dumps({"jsonrpc": "2.0", "method": method, "params": params, "id": 1}).encode()
    req = urllib.request.Request(URL, body, {"Content-Type": "application/json-rpc"})
    if token:
        req.add_header("Authorization", f"Bearer {token}")
    res = json.load(urllib.request.urlopen(req, timeout=10))
    if "error" in res:
        raise RuntimeError(f"{method}: {res['error']['data']}")
    return res["result"]

def login(password):
    try:
        return api("user.login", {"username": "Admin", "password": password})
    except RuntimeError:
        return None                               # wrong password (the web UI answered)

for attempt in range(30):                       # the web UI needs ~1 min after deploy
    try:
        token = login(ADMIN_PASS)
        if token is None and ADMIN_PASS != "zabbix":
            token = login("zabbix")               # fresh install: replace the default password
            if token is None:
                raise SystemExit("Zabbix refused both the lab.env password and the default one")
            uid = api("user.get", {"output": ["userid"], "filter": {"username": "Admin"}})[0]["userid"]
            api("user.update", {"userid": uid, "current_passwd": "zabbix", "passwd": ADMIN_PASS})
            print("  Admin password changed to ZBX_ADMIN_PASS from lab.env")
            token = None; token = login(ADMIN_PASS)
        break
    except (OSError, ValueError):
        print("waiting for Zabbix web..."); time.sleep(5)
else:
    raise SystemExit("Zabbix web UI not reachable on http://localhost:8080")

groups = api("hostgroup.get", {"filter": {"name": ["Mini-DC"]}})
gid = groups[0]["groupid"] if groups else api("hostgroup.create", {"name": "Mini-DC"})["groupids"][0]

tpl = {t["host"]: t["templateid"] for t in
       api("template.get", {"output": ["host"], "filter": {"host": ["Arista by SNMP", "ICMP Ping"]}})}
existing = {h["host"] for h in api("host.get", {"output": ["host"]})}

def add(name, ip, templates, snmp):
    if name in existing:
        print(f"  = {name} already exists"); return
    iface = ({"type": 2, "main": 1, "useip": 1, "ip": ip, "dns": "", "port": "161",
              "details": {"version": 2, "community": SNMP_COMMUNITY}} if snmp else
             {"type": 1, "main": 1, "useip": 1, "ip": ip, "dns": "", "port": "10050"})
    api("host.create", {"host": name, "groups": [{"groupid": gid}], "interfaces": [iface],
                        "templates": [{"templateid": tpl[t]} for t in templates if t in tpl]})
    print(f"  + {name} ({ip}) {templates}")

for n, ip in SWITCHES.items():
    add(n, ip, ["Arista by SNMP"], snmp=True)
for n, ip in PING_ONLY.items():
    add(n, ip, ["ICMP Ping"], snmp=False)
print("Done. Open http://localhost:8080 -> Monitoring -> Hosts (group Mini-DC).")
