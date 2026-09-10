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
        -chardev "socket,id=net0,path=${vm_socket}"
        -netdev "vhost-user,chardev=net0,id=net"
        -device "virtio-net-pci,netdev=net,mac=${vm_mac},romfile="
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
        -chardev "socket,id=${id},path=${vm_socket}"
        -device "vhost-user-fs-pci,chardev=${id},tag=${vm_dst}"
    )
}

vm_add_disk() {
    vm_args+=(
        -drive "file=${vm_disk},if=virtio,format=qcow2,discard=unmap"
    )
}

vm_add_gpu() {
    vm_args+=(
        -object "iommufd,id=iommufd0"
        -device "vfio-pci,host=0000:41:00.0,iommufd=iommufd0"
        -device "vfio-pci,host=0000:41:00.1,iommufd=iommufd0"
    )
}

vm_add_vsock() {
    vm_args+=(
        -device "vhost-vsock-pci,guest-cid=${vm_vsock}"
    )
}

vm_add_kernel() {
    vm_args+=(
        -kernel "${vm_kernel}"
    )
}

vm_run_qemu() {
    qemu-system-x86_64 \
        -nodefaults \
        -no-user-config \
        -machine pc-q35-10.2,memory-backend=ram,usb=off,vmport=off,smm=off,dump-guest-core=off \
        -accel kvm \
        -cpu host,migratable=off \
        -object memory-backend-memfd,id=ram,size=${vm_ram}G,share=on,hugetlb=on,hugetlbsize=1G \
        -smp ${vm_cpu} \
        -rtc base=utc \
        -drive if=pflash,format=raw,readonly=on,file=/run/libvirt/nix-ovmf/edk2-x86_64-code.fd \
        -sandbox on,obsolete=deny,elevateprivileges=deny,spawn=deny,resourcecontrol=deny \
        -object rng-random,id=rng,filename=/dev/urandom \
        -device virtio-rng-pci,rng=rng \
        -serial stdio \
        -display none \
        -monitor none \
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
