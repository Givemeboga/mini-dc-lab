#!/bin/sh
# keepalived notify_master hook (installed as /usr/local/sbin/db-promote.sh on db01 / db02):
# this node now owns the database virtual IP 10.10.20.35 -> make it a writable primary.
mariadb -e "STOP SLAVE; RESET SLAVE ALL" 2>/dev/null
mariadb -e "SET GLOBAL read_only = OFF"
echo "$(date +%T.%3N) $(hostname) promoted to primary (VIP 10.10.20.35)" >> /var/log/db-promote.log
