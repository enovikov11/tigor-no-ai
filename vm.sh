#!/usr/bin/env bash
set -Eeuo pipefail

# general

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
    wg setconf "wg-${vm_name}" "${vm_conf}"
    ip link set "wg-${vm_name}" netns "ns-${vm_name}"

    ip -n "ns-${vm_name}" addr add ${vm_ip}/${vm_mask} dev "wg-${vm_name}"
    ip -n "ns-${vm_name}" link set "wg-${vm_name}" up
    ip -n "ns-${vm_name}" route add default via ${vm_gateway} dev "wg-${vm_name}"
}

vm_wait_socket() {
    for _ in {1..100}; do
        [[ -S "$vm_socket" ]] && return
        sleep 0.01
    done

    echo "Socket did not appear: $vm_socket" >&2
    return 1
}

# qemu

qemu_kernel() {
    qemu_args+=(
        -kernel "${vm_kernel}"
    )
}

qemu_gpu() {
    qemu_args+=(
        -object "iommufd,id=iommufd0"
        -device "vfio-pci,host=0000:41:00.0,iommufd=iommufd0"
        -device "vfio-pci,host=0000:41:00.1,iommufd=iommufd0"
    )
}

qemu_vsock() {
    qemu_args+=(
        -device "vhost-vsock-pci,guest-cid=${vm_vsock}"
    )
}

qemu_disk() {
    qemu_args+=(
        -drive "file=${vm_disk},if=virtio,format=qcow2,discard=unmap"
    )
}

qemu_net() {
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
        --address ${vm_ip} \
        --netmask ${vm_mask} \
        --gateway ${vm_gateway} \
        -D ${vm_dns} \
        --no-map-gw \
        --map-host-loopback none \
        --map-guest-addr none \
        --tcp-ports ${vm_tcp} \
        --udp-ports ${vm_udp} &

    vm_wait_socket
    qemu_args+=(
        -chardev "socket,id=net0,path=${vm_socket}"
        -netdev "vhost-user,chardev=net0,id=net"
        -device "virtio-net-pci,netdev=net,mac=${vm_mac},romfile="
    )
}

qemu_share() {
    rm -f "$vm_socket"

    if ((vm_ro)); then
        virtiofsd --socket-path="$vm_socket" --shared-dir="$vm_src" --readonly &
    else
        virtiofsd --socket-path="$vm_socket" --shared-dir="$vm_src" &
    fi

    vm_wait_socket

    qemu_args+=(
        -chardev "socket,id=${vm_fs_id},path=${vm_socket}"
        -device "vhost-user-fs-pci,chardev=${vm_fs_id},tag=${vm_dst}"
    )
}

qemu_run() {
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
        "${qemu_args[@]}"
}

# cloud

cloud_boot() {
    cloud_args+=(
        --disk "path=${vm_boot},image_type=raw,readonly=on"
    )
}

cloud_gpu() {
    cloud_args+=(
        --device "path=/sys/bus/pci/devices/0000:41:00.0" "path=/sys/bus/pci/devices/0000:41:00.1"
    )
}

cloud_usb() {
    dev=0000:04:00.3

    echo "$dev" > /sys/bus/pci/devices/$dev/driver/unbind
    echo vfio-pci > /sys/bus/pci/devices/$dev/driver_override
    echo "$dev" > /sys/bus/pci/drivers_probe

    cloud_args+=(
        --device "path=/sys/bus/pci/devices/0000:04:00.3"
    )
}

cloud_vsock() {
    cloud_args+=(
        --vsock "cid=${vm_vsock},socket=/run/${vm_name}-vsock.sock"
    )
}

cloud_disk() {
    cloud_args+=(
        --disk "path=${vm_disk},image_type=qcow2,backing_files=on,sparse=on"
    )
}

cloud_iso() {
    cloud_args+=(
        --disk "path=${vm_iso},image_type=raw,readonly=on"
    )
}

cloud_net() {
    cloud_args+=(
        --net "vhost_user=true,socket=${vm_socket},vhost_mode=client,mac=${vm_mac},num_queues=2,queue_size=256"
    )
}

cloud_share() {
    cloud_args+=(
        --fs "socket=${vm_socket},tag=${vm_dst},id=${vm_fs_id}"
    )
}

cloud_run() {
    cloud-hypervisor \
        --cpus "boot=${vm_cpu}" \
        --memory "size=${vm_ram}G,shared=on,hugepages=on,hugepage_size=1G" \
        --platform iommufd=on,vfio_p2p_dma=off \
        --firmware "${CLOUDHV_FIRMWARE}" \
        --rng src=/dev/urandom \
        --serial tty \
        --console off \
        --seccomp true \
        "${cloud_args[@]}"
}

run_vm1() {
    vm_name="vm1"
    trap vm_cleanup EXIT INT TERM

    cloud_args=()
    cloud_gpu
    cloud_usb

    vm_iso="/root/vm1.iso" cloud_iso
    vm_disk="/hdd/private/rw-img/vm1.qcow2" cloud_disk

    vm_ram="32" vm_cpu="32" cloud_run
    vm_cleanup
}

# vms

run_hermes() {
    vm_name="hermes"
    trap vm_cleanup EXIT INT TERM

    qemu_args=()
    vm_kernel="/ssd/public/uki/vm-r114-nvda-pods-vsock-pub-BOOTX64.efi" qemu_kernel

    qemu_gpu
    vm_vsock="3" qemu_vsock

    vm_disk="/ssd/public/cache-img/hermes.qcow2" qemu_disk
    vm_disk="/hdd/public/rw-img/hermes.qcow2" qemu_disk

    vm_ip="10.67.69.2"
    vm_mask="24"
    vm_gateway="10.67.69.1"

    vm_conf="/hdd/root/keys/user2.conf" vm_setup_wireguard
    vm_dns="8.8.8.8" vm_tcp="all" vm_udp="all" vm_mac="52:54:00:a9:f5:da" vm_socket="/run/${vm_name}-passt.sock" qemu_net

    vm_fs_id="fs-ssd-internet" vm_src="/ssd/public/ro/internet" vm_dst="/ssd/public/ro/internet" vm_ro="1" vm_socket="/run/${vm_name}-ssd-internet.sock" qemu_share
    vm_fs_id="fs-hdd-internet" vm_src="/hdd/public/ro/internet" vm_dst="/hdd/public/ro/internet" vm_ro="1" vm_socket="/run/${vm_name}-hdd-internet.sock" qemu_share
    
    vm_ram="256" vm_cpu="128" qemu_run
    vm_cleanup
}
