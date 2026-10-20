# storage01: runs TrueNAS SCALE as a KVM virtual machine inside the container.
# QEMU for the VM, noVNC/websockify for the VM console in a browser.
FROM debian:bookworm-slim
RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      qemu-system-x86 qemu-utils iproute2 iputils-ping procps socat novnc python3-websockify \
 && rm -rf /var/lib/apt/lists/*
CMD ["sleep", "infinity"]
