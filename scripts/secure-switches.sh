#!/usr/bin/env bash
# Hardens the four Arista switches with this machine's secrets (lab.env), so no password sits in configs/ceos:
#   - logins: RADIUS on ad01 (user netadmin, every login and command session accounted), local "admin" with a random
#     password as break-glass, used only when RADIUS does not answer
#   - SNMPv3 user "zabbix" (SHA authentication + AES encryption) replaces the v2c community "dclab"
# Run by deploy.sh after the deploy; safe to run again. Everything stays on the OOB management VRF.
cd "$(dirname "$0")/.."
. ./lab.env
P=clab-mini-dc
for sw in core-01 core-02 tor-01 tor-02; do
  for i in $(seq 60); do docker exec $P-$sw Cli -p 15 -c "show version" >/dev/null 2>&1 && break; sleep 5; done
  if docker exec $P-$sw Cli -p 15 -c "configure
username admin privilege 15 role network-admin secret $SWITCH_LOCAL_PASS
radius-server host 10.10.10.105 vrf MGMT key $RADIUS_SECRET
aaa group server radius NETADMIN
server 10.10.10.105 vrf MGMT
exit
aaa authentication login default group NETADMIN local
aaa authorization exec default group NETADMIN local
aaa accounting exec default start-stop group NETADMIN
aaa accounting commands all default start-stop group NETADMIN
snmp-server group ZBX v3 priv
snmp-server user zabbix ZBX v3 auth sha $SNMP_AUTH_PASS priv aes $SNMP_PRIV_PASS
no snmp-server community dclab
end" >/dev/null; then echo "  $sw: RADIUS login, SNMPv3, random local password"; else echo "  $sw: FAILED"; fi
done
