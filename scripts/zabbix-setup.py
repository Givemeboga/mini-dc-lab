#!/usr/bin/env python3
"""Configures Zabbix for the lab through its API. Run by deploy.sh after every deploy; safe to re-run.
    python3 scripts/zabbix-setup.py            hosts, data center checks, alarms (triggers) and the dashboard
    python3 scripts/zabbix-setup.py problems   list the current problems (exit code 1 if any, for tests.sh)
Zabbix web UI: http://localhost:8080 - user Admin, password ZBX_ADMIN_PASS from lab.env (the default "zabbix"
password is replaced on the first run). Dashboard: Dashboards -> "RAM+ Data Center".
Everything is polled by monitor01 over the OOB management network: the switches by SNMPv3 (SHA + AES), every other
node by its Zabbix agent (configured by scripts/init-ops.sh, TLS with a pre-shared key) and ping."""
import json, os, sys, time, urllib.request

URL = "http://localhost:8080/api_jsonrpc.php"
ENV = {}
_env = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "lab.env")
if os.path.exists(_env):
    for line in open(_env):
        if "=" in line and not line.lstrip().startswith("#"):
            k, v = line.strip().split("=", 1); ENV[k] = v
ADMIN_PASS = ENV.get("ZBX_ADMIN_PASS", "zabbix")
PSK = {"tls_connect": 2, "tls_accept": 2, "tls_psk_identity": "dc-lab", "tls_psk": ENV.get("ZBX_PSK", "")}
SNMPV3 = {"version": 3, "bulk": 1, "securityname": "zabbix", "securitylevel": 2, "contextname": "",
          "authprotocol": 1, "authpassphrase": ENV.get("SNMP_AUTH_PASS", ""),       # SHA1
          "privprotocol": 1, "privpassphrase": ENV.get("SNMP_PRIV_PASS", "")}       # AES128

# ---------------------------------------------------------------- inventory (name -> OOB management IP)
SWITCHES = {"core-01": "10.10.10.11", "core-02": "10.10.10.12", "tor-01": "10.10.10.21", "tor-02": "10.10.10.22"}
AGENTS = {"edge-r1": "10.10.10.31", "edge-r2": "10.10.10.32", "fw-01": "10.10.10.40", "fw-02": "10.10.10.41",
          "web01": "10.10.10.101", "app01": "10.10.10.102", "dns01": "10.10.10.103", "db01": "10.10.10.104",
          "ad01": "10.10.10.105", "backup01": "10.10.10.106", "web-dmz01": "10.10.10.108", "web-dmz02": "10.10.10.109",
          "syslog01": "10.10.10.110", "noc-ws": "10.10.10.111", "db02": "10.10.10.114", "web02": "10.10.10.115",
          "app02": "10.10.10.116", "bms01": "10.10.10.117"}
# kali (the attacker) is deliberately not monitored
PING_ONLY = {"storage01": "10.10.10.107"}            # TrueNAS VM: no agent

FLOAT, UINT = 0, 3
# (host, key, name, value type, units, interval)
ITEMS = []
# (expression, name, severity 1 info .. 5 disaster)
TRIGGERS = []


def item(host, key, name, vtype=UINT, units="", delay="30s"):
    ITEMS.append((host, key, name, vtype, units, delay))
    return f"/{host}/{key}"


# Service addresses shared by two nodes: exactly one must own each, the primary normally
for svc, ip, primary, backup, sev in [("www.dc.lab (public website)", "10.10.60.20", "web-dmz01", "web-dmz02", 4),
                                      ("intranet.dc.lab", "10.10.20.12", "web01", "web02", 4),
                                      ("app.dc.lab (API)", "10.10.20.22", "app01", "app02", 4),
                                      ("db.dc.lab (database)", "10.10.20.35", "db01", "db02", 5),
                                      ("DMZ gateway 10.10.60.1", "10.10.60.1", "fw-01", "fw-02", 4)]:
    a = item(primary, f"dc.vip[{ip}]", f"Owns {svc}", delay="10s")
    b = item(backup, f"dc.vip[{ip}]", f"Owns {svc}", delay="10s")
    TRIGGERS.append((f"last({a})+last({b})<>1", f"{svc}: no owner (or two) - service down", sev))
    TRIGGERS.append((f"last({b})=1", f"{svc}: running on the backup {backup} (failover happened)", 2))

# Services
for h in ["web01", "web02"]:
    k = item(h, "net.tcp.service[https,,443]", "Intranet web server (HTTPS 443)")
    TRIGGERS.append((f"last({k})=0", f"Intranet web server down on {h}", 3))
for h in ["web-dmz01", "web-dmz02"]:
    k = item(h, "net.tcp.service[https,,443]", "Public website (HTTPS 443)")
    TRIGGERS.append((f"last({k})=0", f"HTTPS front end down on {h}", 3))
for h in ["app01", "app02"]:
    k = item(h, "net.tcp.service[https,,8443]", "API (HTTPS 8443)")
    TRIGGERS.append((f"last({k})=0", f"API down on {h}", 3))
dns = {h: item(h, "net.dns[127.0.0.1,db01.dc.lab,A,2,1]", "DNS answers for dc.lab") for h in ["dns01", "ad01"]}
for h, k in dns.items():
    TRIGGERS.append((f"last({k})=0", f"DNS server {h} not answering", 3))
TRIGGERS.append((f"last({dns['dns01']})=0 and last({dns['ad01']})=0", "Both DNS servers down: name resolution broken", 5))
for h in ["db01", "db02"]:
    alive = item(h, "dc.mysql.alive", "MariaDB answers")
    repl = item(h, "dc.mysql.repl", "Replication threads running (2 = OK, -1 = primary)")
    lag = item(h, "dc.mysql.lag", "Replication lag", units="s")
    item(h, "dc.mysql.readonly", "Read-only (1 = replica)")
    TRIGGERS.append((f"last({alive})=0", f"MariaDB down on {h}", 4))
    TRIGGERS.append((f"last({repl})>=0 and last({repl})<2", f"Replication broken on {h}", 4))
    TRIGGERS.append((f"last({lag})>30", f"Replication on {h} is more than 30 s behind", 2))
age = item("backup01", "dc.backup.age", "Age of the last backup", units="s", delay="60s")
ok = item("backup01", "dc.backup.ok", "Last backup succeeded (1), failed (0), none yet (-1)", delay="60s")
TRIGGERS.append((f"last({age})>93600", "No backup for more than 26 hours", 4))
TRIGGERS.append((f"last({ok})=0", "Last backup failed", 4))
for h in ["syslog01", "noc-ws"]:
    k = item(h, "dc.syslog.sources", "Devices whose logs are received")
    TRIGGERS.append((f"last({k})=0", f"Log collector {h} receives nothing", 2))
for h, need, sev in [("fw-01", 4, 4), ("fw-02", 4, 3), ("edge-r1", 2, 3), ("edge-r2", 2, 3)]:
    o = item(h, "dc.ospf.full", "OSPF neighbors Full")
    b = item(h, "dc.bfd.up", "BFD sessions up")
    item(h, "dc.ct.count", "Connections tracked")
    TRIGGERS.append((f"last({o})<{need}", f"{h}: OSPF neighbor lost (fewer than {need} Full)", sev))
    TRIGGERS.append((f"last({b})<{need}", f"{h}: BFD session down", 2))
# Intrusion detection / prevention at the Internet edge (scripts/ids.sh)
for h in ["edge-r1", "edge-r2"]:
    a = item(h, "dc.ids.alerts", "IDS alerts (total since boot)", delay="10s")
    b = item(h, "dc.ips.blocked", "Attackers blocked now", delay="10s")
    TRIGGERS.append((f"last({a})-min({a},5m)>0", f"IDS: attack detected at the Internet edge ({h})", 3))
    TRIGGERS.append((f"last({b})>0", f"IPS: attacker blocked at {h} (10 min)", 4))
for h in ["dns01", "ad01"]:
    k = item(h, "dc.ntp.synced", "NTP synchronised to the Internet pool", delay="60s")
    TRIGGERS.append((f"last({k})=0", f"NTP server {h} not synchronised", 2))
for h in ["web01", "app01", "db01", "db02", "backup01", "syslog01"]:
    k = item(h, "dc.ntp.offset", "Clock offset to dns01 / ad01", FLOAT, "s", delay="60s")
    TRIGGERS.append((f"abs(last({k}))>0.5", f"Clock of {h} is more than 0.5 s off", 2))

# Building management system (simulated power + cooling, scripts/facility.sh)
S = {}
for key, name, vt, unit in [("hall_a_temp", "Server hall A temperature", FLOAT, "°C"),
                            ("hall_b_temp", "Server hall B temperature", FLOAT, "°C"),
                            ("hall_a_rh", "Server hall A humidity", FLOAT, "%"),
                            ("crah_hall_a_running", "Hall A CRAH units running", UINT, ""),
                            ("crah_hall_b_running", "Hall B CRAH units running", UINT, ""),
                            ("utility_a_ok", "Utility feed A (STEG feeder 1) present", UINT, ""),
                            ("utility_b_ok", "Utility feed B (STEG feeder 2) present", UINT, ""),
                            ("ups_a_on_battery", "UPS A on battery", UINT, ""), ("ups_b_on_battery", "UPS B on battery", UINT, ""),
                            ("ups_a_batt_pct", "UPS A battery charge", FLOAT, "%"), ("ups_b_batt_pct", "UPS B battery charge", FLOAT, "%"),
                            ("ups_a_output", "Power path A output", UINT, ""), ("ups_b_output", "Power path B output", UINT, ""),
                            ("ups_a_load_pct", "UPS A load", FLOAT, "%"), ("ups_b_load_pct", "UPS B load", FLOAT, "%"),
                            ("gen_a_running", "Generator A running", UINT, ""), ("gen_b_running", "Generator B running", UINT, ""),
                            ("it_power_kw", "IT power", FLOAT, "kW"), ("pue", "PUE", FLOAT, "")]:
    S[key] = item("bms01", f"bms.sensor[{key}]", name, vt, unit, delay="10s")
for hall in "ab":
    H = hall.upper()
    TRIGGERS += [(f"last({S[f'hall_{hall}_temp']})>27", f"Server hall {H} above 27 °C (ASHRAE recommended limit)", 2),
                 (f"last({S[f'hall_{hall}_temp']})>32", f"Server hall {H} above 32 °C: equipment at risk", 4),
                 (f"last({S[f'crah_hall_{hall}_running']})<2", f"Hall {H}: fewer than 2 CRAH units running (no N+1)", 4)]
TRIGGERS.append((f"last({S['hall_a_rh']})>60", "Server hall A humidity above 60 %", 2))
for p in "ab":
    P = p.upper()
    TRIGGERS += [(f"last({S[f'utility_{p}_ok']})=0", f"Utility feed {P} lost", 3),
                 (f"last({S[f'gen_{p}_running']})=1", f"Generator {P} running", 2),
                 (f"last({S[f'ups_{p}_on_battery']})=1", f"UPS {P} on battery", 4),
                 (f"last({S[f'ups_{p}_batt_pct']})<30", f"UPS {P} battery below 30 %", 5),
                 (f"last({S[f'ups_{p}_output']})=0", f"Power path {P} down - IT running on path {'B' if p == 'a' else 'A'} only (2N)", 4)]

# Dashboard: (title, host, key) shown as single values
TILES = [("Hall A temperature", "bms01", "bms.sensor[hall_a_temp]"), ("Hall B temperature", "bms01", "bms.sensor[hall_b_temp]"),
         ("UPS A load", "bms01", "bms.sensor[ups_a_load_pct]"), ("UPS B load", "bms01", "bms.sensor[ups_b_load_pct]"),
         ("UPS A battery", "bms01", "bms.sensor[ups_a_batt_pct]"), ("IT power", "bms01", "bms.sensor[it_power_kw]"),
         ("PUE", "bms01", "bms.sensor[pue]"), ("Replication lag db02", "db02", "dc.mysql.lag"),
         ("fw-01 OSPF neighbors", "fw-01", "dc.ospf.full"), ("fw-02 synced connections", "fw-02", "dc.ct.count"),
         ("Last backup age", "backup01", "dc.backup.age"), ("Log sources (syslog01)", "syslog01", "dc.syslog.sources"),
         ("IDS alerts (edge-r1)", "edge-r1", "dc.ids.alerts"), ("Attackers blocked (edge-r1)", "edge-r1", "dc.ips.blocked")]

# ---------------------------------------------------------------- API
token = None


def api(method, params):
    body = json.dumps({"jsonrpc": "2.0", "method": method, "params": params, "id": 1}).encode()
    req = urllib.request.Request(URL, body, {"Content-Type": "application/json-rpc"})
    if token:
        req.add_header("Authorization", f"Bearer {token}")
    res = json.load(urllib.request.urlopen(req, timeout=20))
    if "error" in res:
        raise RuntimeError(f"{method}: {res['error']['data']}")
    return res["result"]


def login(password):
    try:
        return api("user.login", {"username": "Admin", "password": password})
    except RuntimeError:
        return None


def connect():
    global token
    for _ in range(40):                           # the web UI needs ~1 min after deploy
        try:
            token = login(ADMIN_PASS)
            if token is None and ADMIN_PASS != "zabbix":
                token = login("zabbix")           # fresh install: replace the default password
                if token is None:
                    raise SystemExit("Zabbix refused both the lab.env password and the default one")
                uid = api("user.get", {"output": ["userid"], "filter": {"username": "Admin"}})[0]["userid"]
                api("user.update", {"userid": uid, "current_passwd": "zabbix", "passwd": ADMIN_PASS})
                print("  Admin password changed to ZBX_ADMIN_PASS from lab.env")
                token = None; token = login(ADMIN_PASS)
            return
        except (OSError, ValueError):
            print("  waiting for Zabbix web..."); time.sleep(5)
    raise SystemExit("Zabbix web UI not reachable on http://localhost:8080")


def setup():
    # the container image of the Zabbix server has no agent: disable its built-in self-monitoring host
    for h in api("host.get", {"output": ["hostid", "status"], "filter": {"host": ["Zabbix server"]}}):
        if h["status"] == "0":
            api("host.update", {"hostid": h["hostid"], "status": 1})
    gid = (api("hostgroup.get", {"filter": {"name": ["Mini-DC"]}}) or [None])[0]
    gid = gid["groupid"] if gid else api("hostgroup.create", {"name": "Mini-DC"})["groupids"][0]
    tpl = {t["host"]: t["templateid"] for t in
           api("template.get", {"output": ["host"], "filter": {"host": ["Arista by SNMP", "ICMP Ping"]}})}
    existing = {h["host"]: h["hostid"] for h in api("host.get", {"output": ["host"]})}
    hosts = {}
    for name, ip in {**SWITCHES, **AGENTS, **PING_ONLY}.items():
        snmp = name in SWITCHES
        tls = PSK if name in AGENTS else {}
        if name in existing:
            hosts[name] = existing[name]
            if tls:
                api("host.update", {"hostid": existing[name], **tls})
            continue
        iface = ({"type": 2, "main": 1, "useip": 1, "ip": ip, "dns": "", "port": "161", "details": SNMPV3} if snmp else
                 {"type": 1, "main": 1, "useip": 1, "ip": ip, "dns": "", "port": "10050"})
        t = ["Arista by SNMP"] if snmp else ["ICMP Ping"]
        hosts[name] = api("host.create", {"host": name, "groups": [{"groupid": gid}], "interfaces": [iface], **tls,
                                          "templates": [{"templateid": tpl[x]} for x in t if x in tpl]})["hostids"][0]
    print(f"  {len(hosts)} hosts")

    ifaces = {i["hostid"]: i["interfaceid"] for i in api("hostinterface.get", {"output": ["hostid", "interfaceid"],
                                                                                 "filter": {"type": 1}})}
    have = {(i["hostid"], i["key_"]): i["itemid"] for i in api("item.get", {"output": ["hostid", "key_"],
                                                                            "hostids": list(hosts.values())})}
    new = 0
    for host, key, name, vtype, units, delay in ITEMS:
        hid = hosts[host]
        if (hid, key) in have:
            continue
        have[(hid, key)] = api("item.create", {"hostid": hid, "name": name, "key_": key, "type": 0, "value_type": vtype,
                                               "units": units, "delay": delay, "interfaceid": ifaces[hid],
                                               "tags": [{"tag": "dc", "value": "custom"}]})["itemids"][0]
        new += 1
    print(f"  {len(ITEMS)} data center checks ({new} new)")

    names = {t["description"] for t in api("trigger.get", {"output": ["description"], "hostids": list(hosts.values())})}
    new = 0
    for expr, name, sev in TRIGGERS:
        if name not in names:
            api("trigger.create", {"description": name, "expression": expr, "priority": sev})
            new += 1
    print(f"  {len(TRIGGERS)} alarms ({new} new)")

    if not api("dashboard.get", {"output": ["dashboardid"], "filter": {"name": "RAM+ Data Center"}}):
        widgets = [{"type": "problems", "name": "Current problems", "x": 0, "y": 0, "width": 44, "height": 9,
                    "fields": [{"type": 0, "name": "show_lines", "value": 25}]},
                   {"type": "problemsbysv", "name": "Problems by severity", "x": 44, "y": 0, "width": 28, "height": 4, "fields": []},
                   {"type": "hostavail", "name": "Availability", "x": 44, "y": 4, "width": 28, "height": 5, "fields": []}]
        for n, (title, host, key) in enumerate(TILES):
            widgets.append({"type": "item", "name": title, "x": (n % 6) * 12, "y": 9 + (n // 6) * 3, "width": 12,
                            "height": 3, "fields": [{"type": 4, "name": "itemid.0", "value": have[(hosts[host], key)]}]})
        api("dashboard.create", {"name": "RAM+ Data Center", "display_period": 30, "auto_start": 1,
                                 "pages": [{"widgets": widgets}]})
        print("  dashboard \"RAM+ Data Center\" created")
    print("Done. http://localhost:8080 -> Dashboards -> RAM+ Data Center (problems: Monitoring -> Problems)")


def problems():
    trig = api("trigger.get", {"output": ["description", "priority"], "filter": {"value": 1}, "monitored": True,
                               "skipDependent": True, "expandDescription": True, "selectHosts": ["host"],
                               "sortfield": "priority", "sortorder": "DESC"})
    names = ["", "info", "WARNING", "AVERAGE", "HIGH", "DISASTER"]
    for t in trig:
        print(f"  {names[int(t['priority'])]:<8} {t['hosts'][0]['host'] if t['hosts'] else '':<10} {t['description']}")
    print(f"  {len(trig)} active problem(s)")
    return 1 if trig else 0


connect()
if sys.argv[1:] == ["problems"]:
    sys.exit(problems())
setup()
