#!/bin/sh
# The attacker (kali) sits on the Internet, behind ISP A, with an ordinary public address. It gets no
# management access (eth0 down) and no copy of the lab folder (no secrets): only the outside view.
ip link set eth1 up
ip addr add 203.0.113.10/24 dev eth1 2>/dev/null
ip route replace default via 203.0.113.1 dev eth1
printf 'root\nadmin\npassword\n123456\ntoor\nletmein\nqwerty\nchangeme\n' > /root/passwords.txt
ip link set eth0 down
umount -l /lab
echo "[init-kali] attacker ready on 203.0.113.10 (behind ISP A)"
