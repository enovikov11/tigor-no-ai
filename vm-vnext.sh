#!/usr/bin/env bash
set -Eeuo pipefail

vm_cleanup() {
    trap - EXIT INT TERM

    kill $(jobs -pr) 2>/dev/null || true
    wait 2>/dev/null || true

    ip netns del "ns-${vm_name}" 2>/dev/null || true
    ip link del "wg-${vm_name}" 2>/dev/null || true
}

vm_setup_wireguard() {
    ip netns del "ns-${vm_name}" 2>/dev/null || true
    ip link del "wg-${vm_name}" 2>/dev/null || true

    ip netns add "ns-${vm_name}"
    ip link add "wg-${vm_name}" type wireguard
    wg setconf "wg-${vm_name}" "/hdd/root/keys/user2.conf"
    ip link set "wg-${vm_name}" netns "ns-${vm_name}"

    ip -n "ns-${vm_name}" addr add 10.67.69.2/24 dev "wg-${vm_name}"
    ip -n "ns-${vm_name}" link set "wg-${vm_name}" up
    ip -n "ns-${vm_name}" route add default via 10.67.69.1 dev "wg-${vm_name}"
}

vm_wait_socket() {
    for _ in {1..100}; do
        [[ -S "$vm_socket" ]] && return
        sleep 0.01
    done

    echo "Socket did not appear: $vm_socket" >&2
    return 1
}

vm_add_passt() {
    rm -f "$vm_socket"

    ip netns exec "ns-${vm_name}" passt \
        --foreground \
        --vhost-user \
        --socket "$vm_socket" \
        --repair-path none \
        --interface "wg-${vm_name}" \
        --outbound-if4 "wg-${vm_name}" \
        --ipv4-only \
        --mtu 1420 \
        --address 10.67.69.2 \
        --netmask 24 \
        --gateway 10.67.69.1 \
        -D 8.8.8.8 \
        --no-map-gw \
        --map-host-loopback none \
        --map-guest-addr none \
        --tcp-ports all \
        --udp-ports all &

    vm_wait_socket
    vm_args+=(
        --net "vhost_user=true,socket=${vm_socket},vhost_mode=client,mac=${vm_mac},num_queues=2,queue_size=256"
    )
}

vm_add_virtiofsd() {
    rm -f "$vm_socket"

    if ((vm_ro)); then
        virtiofsd --socket-path="$vm_socket" --shared-dir="$vm_src" --readonly &
    else
        virtiofsd --socket-path="$vm_socket" --shared-dir="$vm_src" &
    fi

    vm_wait_socket

    vm_args+=(
        --fs "socket=${vm_socket},tag=${vm_dst},id=${id}"
    )
}

vm_add_disk() {
    vm_args+=(
        --disk "path=${vm_disk},image_type=qcow2,backing_files=on,sparse=on"
    )
}

vm_add_gpu() {
    vm_args+=(
        --device path=/sys/bus/pci/devices/0000:41:00.0 path=/sys/bus/pci/devices/0000:41:00.1
    )
}

vm_add_vsock() {
    vm_args+=(
        --vsock "cid=${vm_vsock},socket=/run/${vm_name}-vsock.sock"
    )
}

vm_add_kernel() {
    vm_args+=(
        --disk "path=${vm_kernel},image_type=raw,readonly=on"
    )
}

vm_run_qemu() {
    cloud-hypervisor \
        --cpus "boot=${vm_cpu}" \
        --memory "size=${vm_ram}G,shared=on,hugepages=on,hugepage_size=1G" \
        --platform iommufd=on,vfio_p2p_dma=off \
        --firmware "/etc/tigor/CLOUDHV.fd" \
        --rng src=/dev/urandom \
        --serial tty \
        --console off \
        --seccomp true \
        "${vm_args[@]}"
}

vm_hermes() {
    vm_name="hermes"
    trap vm_cleanup EXIT INT TERM

    vm_args=()
    vm_kernel="/ssd/public/uki/vm-r114-nvda-pods-vsock-pub-BOOTX64.efi" vm_add_kernel

    vm_add_gpu
    vm_vsock="3" vm_add_vsock

    vm_disk="/ssd/public/cache-img/hermes.qcow2" vm_add_disk
    vm_disk="/hdd/public/rw-img/hermes.qcow2" vm_add_disk

    vm_setup_wireguard
    vm_mac="52:54:00:a9:f5:da" vm_socket="/run/${vm_name}-passt.sock" vm_add_passt

    id="fs-ssd-internet" vm_src="/ssd/public/ro/internet" vm_dst="/ssd/public/ro/internet" vm_ro="1" vm_socket="/run/${vm_name}-ssd-internet.sock" vm_add_virtiofsd
    id="fs-hdd-internet" vm_src="/hdd/public/ro/internet" vm_dst="/hdd/public/ro/internet" vm_ro="1" vm_socket="/run/${vm_name}-hdd-internet.sock" vm_add_virtiofsd
    
    vm_ram="256" vm_cpu="128" vm_run_qemu
    vm_cleanup
}
