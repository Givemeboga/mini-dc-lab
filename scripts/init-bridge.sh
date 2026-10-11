#!/bin/sh
# Turns a plain container into a simple L2 switch (Linux bridge).
# Usage: init-bridge.sh [stp]
#   stp  -> enable Spanning Tree (needed when the switch is dual-homed to
#           both cores, e.g. noc-sw and user-sw in the logistics building)
STP=0; [ "$1" = "stp" ] && STP=1
ip link add br0 type bridge stp_state $STP forward_delay 400 2>/dev/null
for p in $(ls /sys/class/net | grep -E '^eth[1-9][0-9]*$'); do
  ip link set "$p" master br0
  ip link set "$p" up
done
ip link set br0 up
echo "[init-bridge] $(hostname): br0 up, STP=$STP, ports: $(ls /sys/class/net/br0/brif | tr '\n' ' ')"
