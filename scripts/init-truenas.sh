#!/bin/bash
# exec for storage01: TrueNAS SCALE as a KVM virtual machine inside the container.
#   - eth1 (SAN cable to storage-sw) is bridged to the VM's 1st NIC -> TrueNAS owns 10.10.30.10
#   - 2nd NIC = QEMU user network: web UI on container :443 (published as https://localhost:8443)
#   - VM console in a browser: http://localhost:6080/vnc.html
#   - disks live in /lab/truenas (= ./truenas in the lab folder, not in git)
# First deploy: the boot disk is empty, so the VM boots the ISO -> install TrueNAS from the console
# (README, section "TrueNAS"). Next deploys boot the installed system.
D=/lab/truenas
RAM=${TRUENAS_RAM:-8192}
ISO=$(ls $D/TrueNAS-SCALE-*.iso 2>/dev/null | sort -V | tail -1)
mkdir -p $D

for _ in $(seq 1 30); do [ -e /sys/class/net/eth1 ] && break; sleep 1; done
ip link add br0 type bridge 2>/dev/null
ip tuntap add tap0 mode tap 2>/dev/null
for p in eth1 tap0; do ip link set $p master br0; ip link set $p up; done
ip link set br0 up

[ -f $D/boot.qcow2 ]  || qemu-img create -q -f qcow2 $D/boot.qcow2 32G
[ -f $D/data1.qcow2 ] || qemu-img create -q -f qcow2 $D/data1.qcow2 20G
[ -f $D/data2.qcow2 ] || qemu-img create -q -f qcow2 $D/data2.qcow2 20G

CDROM=()
[ -n "$ISO" ] && CDROM=(-drive "file=$ISO,media=cdrom,if=none,id=cd,readonly=on" -device ide-cd,drive=cd,bootindex=2)

disk() { echo "-drive file=$D/$1.qcow2,if=none,id=$1,format=qcow2,cache=writeback -device virtio-blk-pci,drive=$1,serial=$2$3"; }

# shellcheck disable=SC2046
qemu-system-x86_64 -name truenas -machine q35,accel=kvm -cpu host -smp 2 -m "$RAM" \
  $(disk boot BOOT0001 ,bootindex=1) $(disk data1 DATA0001) $(disk data2 DATA0002) \
  "${CDROM[@]}" \
  -netdev tap,id=san,ifname=tap0,script=no,downscript=no -device virtio-net-pci,netdev=san,mac=52:54:00:30:00:10 \
  -netdev user,id=mgmt,hostfwd=tcp::443-:443,hostfwd=tcp::80-:80,hostfwd=tcp::2222-:22 \
  -device virtio-net-pci,netdev=mgmt,mac=52:54:00:10:01:07 \
  -vnc :0 -serial file:$D/serial.log -monitor unix:/run/qemu-monitor.sock,server,nowait \
  -daemonize -pidfile /run/truenas.pid </dev/null >$D/qemu.log 2>&1

websockify -D --web /usr/share/novnc 6080 localhost:5900 </dev/null >/dev/null 2>&1
echo "[init-truenas] VM started (RAM ${RAM} MB, ISO: ${ISO:-none}) - console http://localhost:6080/vnc.html"
