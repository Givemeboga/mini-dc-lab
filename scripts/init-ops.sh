#!/bin/sh
# Operations layer, run at boot by init-host.sh and init-router.sh on every server, firewall and edge:
#   - log forwarding: everything this node logs goes to both collectors (syslog01, noc-ws) over the OOB network
#   - NTP: chrony, dns01/ad01 serve time to the others (servers only; see below)
#   - Zabbix agent: passive, listens on the OOB address only, with this role's custom checks (UserParameter)
# Only the role-specific checks live here; Zabbix items, triggers and the dashboard: scripts/zabbix-setup.py.
H=$(hostname)
OOB=$(ip -4 -o addr show eth0 | awk '{print $4}' | cut -d/ -f1)
COLLECTORS="10.10.10.110 10.10.10.111"      # syslog01, noc-ws (OOB addresses)

logs() {
  [ -x "$(command -v rsyslogd)" ] || return
  sed -i 's/^module(load="imklog"/#&/' /etc/rsyslog.conf 2>/dev/null    # no kernel log in a container
  mkdir -p /etc/rsyslog.d
  for c in $COLLECTORS; do echo "*.* @$c:514"; done > /etc/rsyslog.d/90-forward.conf
  pkill -x rsyslogd
  while pidof rsyslogd >/dev/null; do sleep 0.1; done
  rsyslogd </dev/null >/dev/null 2>&1
}

# Containers share the WSL kernel's clock, so chrony runs with -x (measure only, never set the clock): it
# still syncs to the time servers and reports its offset, which Zabbix checks. On real servers drop -x.
ntp() {
  [ -x "$(command -v chronyd)" ] || return
  case "$H" in
    dns01|ad01) printf '%s\n' "pool pool.ntp.org iburst maxsources 3" "allow 10.10.0.0/16" "local stratum 10" ;;
    *)          printf '%s\n' "server 10.10.20.40 iburst" "server 10.10.20.50 iburst" ;;
  esac > /etc/chrony/chrony.conf
  printf '%s\n' "driftfile /var/lib/chrony/chrony.drift" "makestep 1 3" >> /etc/chrony/chrony.conf
  pkill -x chronyd; sleep 0.5
  chronyd -x -f /etc/chrony/chrony.conf </dev/null >/dev/null 2>&1
}

agent() {
  [ -x "$(command -v zabbix_agentd)" ] || return
  mkdir -p /etc/zabbix /run/zabbix /var/log/zabbix
  chown zabbix /run/zabbix /var/log/zabbix
  {
    echo "Server=10.10.10.50"
    echo "ListenIP=$OOB"
    echo "Hostname=$H"
    echo "PidFile=/run/zabbix/zabbix_agentd.pid"
    echo "LogFile=/var/log/zabbix/zabbix_agentd.log"
    echo "Timeout=5"
    # which virtual IPs this node owns right now (1/0): www, intranet, app, db, DMZ gateway
    echo 'UserParameter=dc.vip[*],ip -4 -o addr show | grep -c " $1/"'
    [ -x "$(command -v chronyc)" ] && cat <<'EOF'
UserParameter=dc.ntp.offset,chronyc -c tracking 2>/dev/null | cut -d, -f5
UserParameter=dc.ntp.synced,chronyc -c tracking 2>/dev/null | awk -F, '{print ($NF=="Normal") ? 1 : 0}'
EOF
    case "$H" in
      db01|db02) cat <<'EOF'
UserParameter=dc.mysql.alive,mariadb-admin -u zabbix ping 2>/dev/null | grep -c alive
UserParameter=dc.mysql.readonly,mariadb -u zabbix -N -e 'select @@read_only' 2>/dev/null || echo -1
UserParameter=dc.mysql.repl,mariadb -u zabbix -e 'show slave status\G' 2>/dev/null | awk '/Slave_(IO|SQL)_Running:/ {n += ($2 == "Yes"); f = 1} END {print f ? n : -1}'
UserParameter=dc.mysql.lag,mariadb -u zabbix -e 'show slave status\G' 2>/dev/null | awk '/Seconds_Behind_Master/ {print ($2 == "NULL") ? -1 : $2; f = 1} END {if (!f) print -1}'
EOF
      ;;
      backup01) cat <<'EOF'
# -1 = no backup yet (the first one runs 6 min after deploy)
UserParameter=dc.backup.age,f=$(ls -1t /srv/backup/db/*.sql.gz 2>/dev/null | head -1); if [ -n "$f" ]; then echo $(( $(date +%s) - $(stat -c %Y "$f") )); else echo -1; fi
UserParameter=dc.backup.ok,if [ -f /var/log/dc-backup.log ]; then grep '== Backup' /var/log/dc-backup.log | tail -1 | grep -c ' OK'; else echo -1; fi
EOF
      ;;
      syslog01|noc-ws) echo 'UserParameter=dc.syslog.sources,ls /var/log/remote 2>/dev/null | wc -l' ;;
      fw-0[12]|edge-r[12]) cat <<'EOF'
UserParameter=dc.ospf.full,vtysh -c 'show ip ospf neighbor' 2>/dev/null | grep -c Full
UserParameter=dc.bfd.up,vtysh -c 'show bfd peers brief' 2>/dev/null | grep -ci ' up '
UserParameter=dc.ct.count,cat /proc/sys/net/netfilter/nf_conntrack_count
EOF
      ;;
      bms01) echo 'UserParameter=bms.sensor[*],cat /var/lib/bms/$1 2>/dev/null || echo -1' ;;
    esac
  } > /etc/zabbix/dc-agent.conf
  # read-only vtysh for the agent: the FRR sockets belong to group frr, the vty access to frrvty
  case "$H" in fw-0[12]|edge-r[12]) addgroup zabbix frrvty 2>/dev/null; addgroup zabbix frr 2>/dev/null ;; esac
  pkill -x zabbix_agentd; sleep 0.5
  zabbix_agentd -c /etc/zabbix/dc-agent.conf </dev/null >/dev/null 2>&1
}

[ -n "$1" ] && { "$1"; exit; }
logs; ntp; agent
echo "[init-ops] $H: logs -> $COLLECTORS, ntp, zabbix agent on $OOB:10050"
