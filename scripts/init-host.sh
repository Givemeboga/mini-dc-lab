#!/bin/bash
# Runs inside every server / PC right after deploy.
# The node's role is picked from its hostname (= containerlab node name).
#   bash /lab/scripts/init-host.sh            full role setup (containerlab exec)
#   bash /lab/scripts/init-host.sh role_fw    only (re)apply one function, e.g. the host firewall
H=$(hostname)
log() { echo "[init-host] $H: $*"; }

# Passwords come from lab.env (generated per machine by scripts/gen-secrets.sh, never committed)
[ -f /lab/lab.env ] && . /lab/lab.env

# MTU 1500: clab veths default to 9500 but the cEOS switch ports carry max 9214 bytes, so full-size
# 9500 TCP segments crossing the switches are silently dropped (bulk transfers hang).
addr()  { ip link set "$1" mtu 1500 up; ip addr add "$2" dev "$1" 2>/dev/null || true; }
gw()    { ip route replace default via "$1"; }          # data-plane gateway (VRRP VIP)
# two internal resolvers (dns01 primary, ad01 secondary); a dead one is skipped after 1 s
use_dc_dns() { printf 'search dc.lab\nnameserver 10.10.20.40\nnameserver 10.10.20.50\nnameserver 127.0.0.11\noptions timeout:1 attempts:2\n' > /etc/resolv.conf; }

web_page() {   # $1 = title, $2 = colour
  cat > /var/www/html/index.html <<HTML
<!doctype html><html><head><meta charset="utf-8"><title>$H</title></head>
<body style="font-family:sans-serif;background:$2;color:#fff;display:flex;align-items:center;justify-content:center;height:100vh;margin:0">
<div style="text-align:center"><h1 style="margin:0">$H</h1><p>$1</p><p>$(ip -4 -o addr show eth1 | awk '{print $4}')</p></div></body></html>
HTML
}

tls_files() {  # $1 = certificate name in /lab/pki (intranet, app, db, www) -> /etc/ssl/dc/$1.{crt,key}
  mkdir -p /etc/ssl/dc
  install -m 644 /lab/pki/$1.crt /etc/ssl/dc/$1.crt
  install -m 640 /lab/pki/$1.key /etc/ssl/dc/$1.key
}

start_web() {  # intranet web01/web02: HTTPS (lab CA certificate), HTTP only redirects
  tls_files intranet
  cat > /etc/nginx/sites-enabled/default <<'CONF'
server {
    listen 80 default_server;
    return 301 https://$host$request_uri;
}
server {
    listen 443 ssl default_server;
    server_name intranet.dc.lab;
    ssl_certificate     /etc/ssl/dc/intranet.crt;
    ssl_certificate_key /etc/ssl/dc/intranet.key;
    ssl_protocols TLSv1.2 TLSv1.3;
    add_header Strict-Transport-Security "max-age=31536000" always;
    root /var/www/html;
    index index.html;
}
CONF
  nginx </dev/null >/dev/null 2>&1
}

# A service address shared by two servers: keepalived (VRRPv3, advert every 0.2 s) keeps it on the
# higher priority server while its health check passes, and moves it to the other one within ~0.7 s.
start_vip() {  # $1 name, $2 VRRP id, $3 virtual IP/prefix, $4 priority, $5 health check command
  cat > /etc/keepalived/keepalived.conf <<CONF
global_defs {
    enable_script_security
    script_user root
}
vrrp_script chk {
    script "$5"
    interval 1
    fall 2
    rise 2
}
vrrp_instance $1 {
    version 3
    state BACKUP
    interface eth1
    virtual_router_id $2
    priority $4
    advert_int 0.2
    virtual_ipaddress { $3 dev eth1 }
    track_script { chk }
}
CONF
  pkill -x keepalived
  for _ in $(seq 50); do pidof keepalived >/dev/null || break; sleep 0.1; done   # old one takes ~1 s to stop
  keepalived -f /etc/keepalived/keepalived.conf </dev/null >/dev/null 2>&1
}

# ---- Public website: two DMZ servers behind one virtual IP (www.dc.lab = 10.10.60.20) -----------
# Each server runs the same nginx: port 8080 = its own page (backend), port 443 = TLS front end that
# load-balances over both backends, port 80 = redirect to HTTPS. keepalived (VRRP 62) puts the virtual
# IP on web-dmz01 and moves it to web-dmz02 if web-dmz01 or its nginx fails (start_vip). The edges forward 80/443
# from both ISPs to the virtual IP.
WWW_VIP=10.10.60.20
start_dmz_web() {  # $1 = VRRP priority (web-dmz01 110, web-dmz02 100)
  mkdir -p /etc/nginx/tls
  install -m 644 /lab/pki/www.crt /etc/nginx/tls/www.crt
  install -m 600 /lab/pki/www.key /etc/nginx/tls/www.key
  cat > /etc/nginx/sites-enabled/default <<'CONF'
upstream dmz_web {
    server 10.10.60.10:8080 max_fails=1 fail_timeout=10s;
    server 10.10.60.11:8080 max_fails=1 fail_timeout=10s;
}
server {                      # backend: this server's own page
    listen 8080;
    root /var/www/html;
    index index.html;
}
server {                      # plain HTTP only redirects
    listen 80 default_server;
    return 301 https://$host$request_uri;
}
server {                      # TLS front end + load balancer (round robin)
    listen 443 ssl default_server;
    server_name www.dc.lab;
    ssl_certificate     /etc/nginx/tls/www.crt;
    ssl_certificate_key /etc/nginx/tls/www.key;
    ssl_protocols TLSv1.2 TLSv1.3;
    add_header Strict-Transport-Security "max-age=31536000" always;
    location / {
        proxy_pass http://dmz_web;
        proxy_connect_timeout 500ms;    # a dead backend is skipped quickly
        proxy_next_upstream error timeout http_502 http_503;
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        add_header X-Backend $upstream_addr always;
    }
}
CONF
  nginx -s reload 2>/dev/null || nginx </dev/null >/dev/null 2>&1
  start_vip WWW 62 $WWW_VIP/24 "$1" "/usr/bin/curl -sf -o /dev/null --max-time 1 http://127.0.0.1:8080/"
}

start_dns() {  # $1 = primary (dns01) | secondary (ad01, copies the zone from dns01)
  cat > /etc/bind/named.conf.options <<'CONF'
options {
    directory "/var/cache/bind";
    recursion yes;
    allow-query { 10.10.0.0/16; 127.0.0.1; };
    forwarders { 1.1.1.1; 8.8.8.8; };
    dnssec-validation no;
    listen-on { any; };
    listen-on-v6 { none; };
};
CONF
  if [ "$1" = secondary ]; then
    # retry every 30 s: at boot dns01 may not answer yet (BIND's default first retry is 500 s)
    echo 'zone "dc.lab" { type slave; masters { 10.10.20.40; }; file "/var/cache/bind/db.dc.lab";
                         min-retry-time 30; max-retry-time 60; };' > /etc/bind/named.conf.local
    mkdir -p /run/named && chown bind:bind /run/named /var/cache/bind
    # at boot the switches may not forward yet, and after a failed transfer BIND caches dns01 as unreachable and
    # stops trying. Watchdog (background, first 10 min): while ad01 has no zone but dns01 answers, restart named.
    ( for _ in $(seq 60); do
        dig +short +time=1 +tries=1 @127.0.0.1 dc.lab SOA | grep -q . && break
        if dig +short +time=1 +tries=1 @10.10.20.40 dc.lab SOA | grep -q .; then
          pkill -x named; while pidof named >/dev/null; do sleep 0.2; done
        fi
        pidof named >/dev/null || named -u bind -4 </dev/null >/dev/null 2>&1
        sleep 10
      done ) </dev/null >/dev/null 2>&1 &
    return
  fi
  cat > /etc/bind/named.conf.local <<'CONF'
zone "dc.lab" { type master; file "/etc/bind/db.dc.lab";
                allow-transfer { 10.10.20.50; }; also-notify { 10.10.20.50; }; };
CONF
  cat > /etc/bind/db.dc.lab <<'ZONE'
$TTL 300
@          IN SOA dns01.dc.lab. admin.dc.lab. ( 2026111301 3600 60 86400 300 )
           IN NS  dns01.dc.lab.
           IN NS  ad01.dc.lab.
gw         IN A   10.10.20.1
web01      IN A   10.10.20.10
web02      IN A   10.10.20.11
intranet   IN A   10.10.20.12
app01      IN A   10.10.20.20
app02      IN A   10.10.20.21
app        IN A   10.10.20.22
db01       IN A   10.10.20.30
db02       IN A   10.10.20.31
db         IN A   10.10.20.35
dns01      IN A   10.10.20.40
ad01       IN A   10.10.20.50
backup01   IN A   10.10.40.10
storage01  IN A   10.10.30.10
web-dmz01  IN A   10.10.60.10
web-dmz02  IN A   10.10.60.11
www        IN A   10.10.60.20
noc-ws     IN A   10.10.70.10
syslog01   IN A   10.10.70.20
pc-01      IN A   10.10.50.101
pc-02      IN A   10.10.50.102
ZONE
  mkdir -p /run/named && chown bind:bind /run/named
  named -u bind -4 </dev/null >/dev/null 2>&1
}

# ---- MariaDB high availability -----------------------------------------------
# db01 = primary, db02 = replica (GTID replication). keepalived (VRRP 35) moves the
# database virtual IP 10.10.20.35 (db.dc.lab) to db02 if MariaDB on db01 dies; db02 is then
# promoted to a writable primary (scripts/db-promote.sh). Test: ./scripts/db-failover.sh
DB_VIP=10.10.20.35

db_users_sql() { cat <<SQL
CREATE USER IF NOT EXISTS 'web'@'10.10.60.%' IDENTIFIED BY '$DB_WEB_PASS';
CREATE USER IF NOT EXISTS 'app'@'10.10.20.%' IDENTIFIED BY '$DB_APP_PASS';
CREATE USER IF NOT EXISTS 'repl'@'10.10.20.%' IDENTIFIED BY '$DB_REPL_PASS';
CREATE USER IF NOT EXISTS 'backup'@'10.10.40.10' IDENTIFIED BY '$DB_BACKUP_PASS';
GRANT SELECT ON shop.* TO 'web'@'10.10.60.%';
GRANT ALL ON shop.* TO 'app'@'10.10.20.%';
GRANT REPLICATION SLAVE, REPLICATION CLIENT, SELECT, RELOAD, LOCK TABLES, SHOW VIEW, EVENT, TRIGGER ON *.* TO 'repl'@'10.10.20.%';
GRANT SELECT, LOCK TABLES, SHOW VIEW, EVENT, TRIGGER ON *.* TO 'backup'@'10.10.40.10';
-- Zabbix agent (OS user zabbix, no password: unix socket) may only read the replication state
CREATE USER IF NOT EXISTS 'zabbix'@'localhost' IDENTIFIED VIA unix_socket;
GRANT REPLICATION CLIENT, SLAVE MONITOR ON *.* TO 'zabbix'@'localhost';
-- every network account must use TLS (the local zabbix account uses the unix socket)
ALTER USER 'web'@'10.10.60.%' REQUIRE SSL;
ALTER USER 'app'@'10.10.20.%' REQUIRE SSL;
ALTER USER 'repl'@'10.10.20.%' REQUIRE SSL;
ALTER USER 'backup'@'10.10.40.10' REQUIRE SSL;
FLUSH PRIVILEGES;
SQL
}

mariadb_up() {   # $1 = server-id, $2 = read_only (0|1)
  tls_files db; chgrp mysql /etc/ssl/dc/db.key
  cat > /etc/mysql/mariadb.conf.d/60-ha.cnf <<CNF
[mysqld]
server-id         = $1
log_bin           = mysql-bin
binlog_format     = ROW
log_slave_updates = ON
read_only         = $2
skip_name_resolve = ON          # no reverse-DNS lookup per client: fast logins, also during failover
ssl_cert          = /etc/ssl/dc/db.crt   # TLS: required for every network account (REQUIRE SSL)
ssl_key           = /etc/ssl/dc/db.key
ssl_ca            = /etc/ssl/dc/db.crt
tls_version       = TLSv1.2,TLSv1.3
CNF
  mkdir -p /run/mysqld && chown mysql:mysql /run/mysqld
  mysqld_safe --bind-address=0.0.0.0 </dev/null >/var/log/mysqld_safe.log 2>&1 &
  for i in $(seq 1 30); do mariadb -e 'select 1' >/dev/null 2>&1 && break; sleep 1; done
}

start_db() {          # db01: primary, owns the shop data
  mariadb_up 1 0
  { cat <<'SQL'
CREATE DATABASE IF NOT EXISTS shop;
USE shop;
CREATE TABLE IF NOT EXISTS products (id INT PRIMARY KEY AUTO_INCREMENT, name VARCHAR(64), price DECIMAL(8,2));
INSERT INTO products (name, price) SELECT * FROM (SELECT 'Rack 42U', 1200.00) t WHERE NOT EXISTS (SELECT 1 FROM products);
INSERT INTO products (name, price) SELECT 'UPS 10kVA', 3500.00 FROM DUAL WHERE (SELECT COUNT(*) FROM products) < 2;
SQL
    db_users_sql; } | mariadb
}

start_db_replica() {  # db02: copy of db01, then live replication from it
  local primary=10.10.20.30 r="-u repl -p$DB_REPL_PASS"
  mariadb_up 2 1
  { echo "SET sql_log_bin=0;"; db_users_sql; } | mariadb
  for i in $(seq 1 90); do
    mariadb -h $primary $r -N -e 'select count(*) from shop.products' 2>/dev/null | grep -q '[1-9]' && break; sleep 2
  done
  # consistent snapshot + the GTID position it corresponds to, then replicate from there
  mariadb-dump -h $primary $r --single-transaction --gtid --master-data=1 --databases shop >/tmp/seed.sql 2>/var/log/db-seed.log
  { echo "SET sql_log_bin=0;"; cat /tmp/seed.sql; } | mariadb
  mariadb -e "CHANGE MASTER TO MASTER_HOST='$primary', MASTER_USER='repl', MASTER_PASSWORD='$DB_REPL_PASS',
              MASTER_USE_GTID=slave_pos, MASTER_CONNECT_RETRY=1, MASTER_SSL=1; START SLAVE;"
}

start_keepalived() {  # $1 = VRRP priority (db01 110, db02 100); nopreempt = no automatic failback
  install -m 755 /lab/scripts/db-promote.sh /usr/local/sbin/db-promote.sh
  cat > /etc/keepalived/keepalived.conf <<CONF
global_defs { enable_script_security; script_user root }
vrrp_script chk_mariadb {
    script "/usr/bin/mariadb-admin --connect-timeout=1 ping"
    interval 1
    timeout 2
    fall 2
    rise 2
}
vrrp_instance DB {
    state BACKUP
    nopreempt
    interface eth1
    virtual_router_id 35
    priority $1
    advert_int 1
    virtual_ipaddress { $DB_VIP/24 dev eth1 }
    track_script { chk_mariadb }
    notify_master "/usr/local/sbin/db-promote.sh"
}
CONF
  keepalived -f /etc/keepalived/keepalived.conf </dev/null >/dev/null 2>&1
}

start_syslog() {
  sed -i 's/^module(load="imklog"/#&/' /etc/rsyslog.conf
  mkdir -p /var/log/remote
  id syslog >/dev/null 2>&1 && chown syslog:adm /var/log/remote   # rsyslog may drop privileges
  cat > /etc/rsyslog.d/10-remote.conf <<'CONF'
module(load="imudp")
input(type="imudp" port="514")
template(name="PerHost" type="string" string="/var/log/remote/%HOSTNAME%.log")
if $fromhost-ip != '127.0.0.1' then {
    action(type="omfile" dynaFile="PerHost")
    stop
}
CONF
  rsyslogd </dev/null >/dev/null 2>&1
}

start_app() {  # API: Python on 127.0.0.1:8080, published only through nginx TLS on 8443
  tls_files app
  cat > /etc/nginx/sites-enabled/default <<'CONF'
server {
    listen 8443 ssl default_server;
    server_name app.dc.lab;
    ssl_certificate     /etc/ssl/dc/app.crt;
    ssl_certificate_key /etc/ssl/dc/app.key;
    ssl_protocols TLSv1.2 TLSv1.3;
    location / { proxy_pass http://127.0.0.1:8080; }
}
CONF
  nginx </dev/null >/dev/null 2>&1
  mkdir -p /srv/app
  echo "{\"service\":\"$H\",\"status\":\"ok\",\"db\":\"db.dc.lab (10.10.20.35):3306\"}" > /srv/app/index.json
  nohup python3 -m http.server 8080 --bind 127.0.0.1 --directory /srv/app </dev/null >/var/log/app.log 2>&1 &
}

# Network administrators' logins on the switches: RADIUS (FreeRADIUS) on ad01, reached over the OOB network.
# The Arista-AVPair gives privilege 15; logins and accounting go to syslog -> both NOC collectors.
start_radius() {
  local R=/etc/freeradius/3.0
  cat > $R/clients.conf <<CONF
client oob-switches {
    ipaddr = 10.10.10.0/24
    secret = $RADIUS_SECRET
}
CONF
  cat > $R/mods-config/files/authorize <<CONF
$SWITCH_USER Cleartext-Password := "$SWITCH_PASS"
        Arista-AVPair = "shell:priv-lvl=15"
CONF
  sed -i 's/^\(\s*destination = \).*/\1syslog/; s/^\(\s*auth = \)no/\1yes/; s/^\(\s*auth_badpass = \)no/\1yes/' $R/radiusd.conf
  mkdir -p /run/freeradius && chown freerad:freerad /run/freeradius
  freeradius </dev/null >/dev/null 2>&1
}

start_bms() {  # building management system simulator (power + cooling sensors for Zabbix)
  nohup bash /lab/scripts/facility.sh run </dev/null >/dev/null 2>&1 &
}

start_backup() {  # nightly backup job + first run a few minutes after deploy (scripts/backup.sh)
  nohup bash /lab/scripts/backup.sh schedule </dev/null >/dev/null 2>&1 &
}

# ---- Host firewall (defense in depth) ---------------------------------------
# Every server and PC drops incoming connections by default and only opens the ports its role
# needs, so a compromised PC or DMZ host cannot reach services the network would let through.
# eth0 = out-of-band management network (Zabbix, admins) is always allowed.
SERVERS=10.10.20.0/24 USERS=10.10.50.0/24 NOC=10.10.70.0/24 DMZ=10.10.60.0/24 BACKUP01=10.10.40.10
role_fw() {
  local allow
  case "$H" in
    web0[12])    allow="tcp dport { 80, 443 } ip saddr { $SERVERS, $USERS, $NOC } accept
                        ip protocol 112 ip saddr $SERVERS accept" ;;
    app0[12])    allow="tcp dport 8443 ip saddr { $SERVERS, $USERS, $NOC } accept
                        ip protocol 112 ip saddr $SERVERS accept" ;;
    dns01|ad01)  allow="meta l4proto { tcp, udp } th dport 53 ip saddr 10.10.0.0/16 accept
                        udp dport 123 ip saddr 10.10.0.0/16 accept" ;;
    db01|db02)   allow="tcp dport 3306 ip saddr { 127.0.0.1, $SERVERS, $DMZ, $BACKUP01 } accept
                        ip protocol 112 ip saddr $SERVERS accept" ;;
    syslog01|noc-ws) allow="udp dport 514 ip saddr 10.10.0.0/16 accept" ;;
    web-dmz0[12]) allow="tcp dport { 80, 443 } accept
                        tcp dport 8080 ip saddr $DMZ accept
                        ip protocol 112 ip saddr $DMZ accept" ;;
    *)           allow="" ;;   # backup01, PCs: no inbound service
  esac
  nft -f - <<NFT
flush ruleset
table inet host {
    chain input {
        type filter hook input priority filter; policy drop;
        iif "lo" accept
        ct state established,related accept
        ct state invalid drop
        iifname "eth0" accept comment "OOB management"
        ip protocol icmp accept
        $allow
        counter comment "dropped by host firewall"
    }
}
NFT
}

# Hosts exposed to untrusted users (DMZ, PCs) must not keep the lab folder, which holds lab.env and
# the private keys: unmount it once the role is set up.
# Logs to the collectors, NTP, Zabbix agent (scripts/init-ops.sh) - every role except admin-pc
ops() { sh /lab/scripts/init-ops.sh; }

# -l (lazy): this very script is read from /lab, a normal umount would fail with "target is busy".
drop_lab_folder() { ops; umount -l /lab && log "lab folder unmounted (no secrets on this host)"; }

[ -n "$1" ] && { "$1" "${@:2}"; exit; }   # run a single function (see header)

case "$H" in
  # ---- Salle serveurs 1 (TOR-01) ------------------------------------------
  # intranet.dc.lab = 10.10.20.12 (web01 / web02), app.dc.lab = 10.10.20.22 (app01 / app02): one server per rack
  web01)     addr eth1 10.10.20.10/24; gw 10.10.20.1; use_dc_dns; web_page "Internal intranet (VLAN 20)" "#2f6fb3"; start_web
             start_vip INTRANET 21 10.10.20.12/24 110 "/usr/bin/curl -skf -o /dev/null --max-time 1 https://127.0.0.1/" ;;
  app01)     addr eth1 10.10.20.20/24; gw 10.10.20.1; use_dc_dns; start_app; start_vip APP 22 10.10.20.22/24 110 "/usr/bin/curl -skf -o /dev/null --max-time 1 https://127.0.0.1:8443/index.json" ;;
  dns01)     addr eth1 10.10.20.40/24; gw 10.10.20.1; start_dns primary; use_dc_dns ;;
  db02)      addr eth1 10.10.20.31/24; gw 10.10.20.1; use_dc_dns; start_db_replica; role_fw; sleep 5; start_keepalived 100 ;;
  # ---- Salle serveurs 2 (TOR-02) ------------------------------------------
  db01)      addr eth1 10.10.20.30/24; gw 10.10.20.1; addr eth2 10.10.30.30/24; use_dc_dns; start_db; role_fw; start_keepalived 110 ;;
  ad01)      addr eth1 10.10.20.50/24; gw 10.10.20.1; start_dns secondary; use_dc_dns; start_radius ;;
  web02)     addr eth1 10.10.20.11/24; gw 10.10.20.1; use_dc_dns; web_page "Internal intranet (VLAN 20)" "#1f5596"; start_web
             start_vip INTRANET 21 10.10.20.12/24 100 "/usr/bin/curl -skf -o /dev/null --max-time 1 https://127.0.0.1/" ;;
  app02)     addr eth1 10.10.20.21/24; gw 10.10.20.1; use_dc_dns; start_app; start_vip APP 22 10.10.20.22/24 100 "/usr/bin/curl -skf -o /dev/null --max-time 1 https://127.0.0.1:8443/index.json" ;;
  backup01)  addr eth1 10.10.40.10/24; gw 10.10.40.1; addr eth2 10.10.30.40/24; use_dc_dns; start_backup ;;
  # ---- DMZ -----------------------------------------------------------------
  web-dmz01) addr eth1 10.10.60.10/24; gw 10.10.60.1; use_dc_dns; web_page "Public website www.dc.lab - served by web-dmz01" "#c2336a"
             start_dmz_web 110; role_fw; drop_lab_folder ;;
  web-dmz02) addr eth1 10.10.60.11/24; gw 10.10.60.1; use_dc_dns; web_page "Public website www.dc.lab - served by web-dmz02" "#9c1f4f"
             start_dmz_web 100; role_fw; drop_lab_folder ;;
  # ---- Batiment logistique -------------------------------------------------
  noc-ws)    addr eth1 10.10.70.10/24; gw 10.10.70.1; use_dc_dns; start_syslog ;;   # second log collector
  syslog01)  addr eth1 10.10.70.20/24; gw 10.10.70.1; use_dc_dns; start_syslog ;;
  pc-01)     addr eth1 10.10.50.101/24; gw 10.10.50.1; use_dc_dns; role_fw; drop_lab_folder ;;
  pc-02)     addr eth1 10.10.50.102/24; gw 10.10.50.1; use_dc_dns; role_fw; drop_lab_folder ;;
  bms01)     start_bms ;;   # OOB only: Zabbix reads its sensors over the management network
  admin-pc)  : ;;   # lives only on the OOB management network
  *)         log "no role defined" ;;
esac
case "$H" in admin-pc|pc-0[12]|web-dmz0[12]|db0[12]) ;; *) role_fw ;; esac   # the others already did
case "$H" in admin-pc|pc-0[12]|web-dmz0[12]) ;; *) ops ;; esac              # the others ran it before umount
log "done"
