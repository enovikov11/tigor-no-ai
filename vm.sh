#!/usr/bin/env bash
set -Eeuo pipefail
# Sandbox/hardening direction (comments only; not implemented below):
# - Keep the privileged launcher for netns/WireGuard/VFIO setup, but run passt,
#   virtiofsd and QEMU under dedicated *real host* UIDs before entering bwrap.
# - bwrap starts with an empty mount namespace/root: prefer exact
#   --ro-bind/--bind/--dev-bind allowances instead of --ro-bind / / + masking.
# - Useful flags where compatible: --die-with-parent --new-session --clearenv
#   --cap-drop ALL. --unshare-all is a good baseline, but user/cgroup use "try"
#   semantics; add explicit --unshare-user/--unshare-cgroup if failure must fail.
# - On NixOS, --ro-bind /nix/store /nix/store is a convenient initial runtime
#   closure; tighter per-program store closures can come later if worthwhile.
# - Treat inherited FDs as sandbox capabilities: use CLOEXEC for unrelated FDs
#   and audit /proc/$pid/fd for every guest-facing child after startup.

vm_cleanup() {
    trap - EXIT INT TERM

    kill $(jobs -pr) 2>/dev/null || true
    wait 2>/dev/null || true

    ip netns del "ns-${vm_name}" 2>/dev/null || true
}

vm_setup_wireguard() {
    ip netns del "ns-${vm_name}" 2>/dev/null || true
    ip link del "wg-${vm_name}" 2>/dev/null || true

    ip netns add "ns-${vm_name}"
    ip link add "wg-${vm_name}" type wireguard
    wg setconf "wg-${vm_name}" "/ssd/public/vm/hermes/user2.conf"
    ip link set "wg-${vm_name}" netns "ns-${vm_name}"

    ip -n "ns-${vm_name}" addr add 10.67.69.2/24 dev "wg-${vm_name}"
    ip -n "ns-${vm_name}" link set "wg-${vm_name}" up
    ip -n "ns-${vm_name}" route add default via 10.67.69.1 dev "wg-${vm_name}"
    # If passt becomes a real unprivileged host UID while keeping
    # --tcp-ports all/--udp-ports all, consider setting inside this netns:
    #   sysctl -w net.ipv4.ip_unprivileged_port_start=0
    # This avoids CAP_NET_BIND_SERVICE solely for ports <1024. If "all" inbound
    # ports are not intentional, prefer an explicit port allowlist.
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
    # bwrap:
    # ip netns exec "ns-${vm_name}" bwrap \\
    #     --unshare-all --share-net --cap-drop ALL --die-with-parent \\
    #     --ro-bind /nix/store /nix/store --dev-bind /dev /dev \\
    #     --ro-bind /proc /proc \\
    #     --bind "$(dirname "$vm_socket")" "$(dirname "$vm_socket")" \\
    #     --ro-bind "$(which passt)" "$(which passt)" \\
    #     passt \\

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
    # bwrap:
    # bwrap --unshare-all --cap-drop ALL --die-with-parent \\
    #     --ro-bind /nix/store /nix/store \\
    #     --ro-bind "$vm_src" "$vm_src" \\
    #     --bind "$(dirname "$vm_socket")" "$(dirname "$vm_socket")" \\
    #     --ro-bind /proc /proc \\
    #     --ro-bind "$(which virtiofsd)" "$(which virtiofsd)" \\
    #     virtiofsd --socket-path="$vm_socket" --shared-dir="$vm_src" --readonly &

    if ((vm_ro)); then
        virtiofsd --socket-path="$vm_socket" --shared-dir="$vm_src" --readonly &
    else
        virtiofsd --socket-path="$vm_socket" --shared-dir="$vm_src" &
    fi

    vm_wait_socket
    # NOTE: ${id} is consumed below with set -u enabled; each caller must set a
    # unique id before vm_add_virtiofsd or the script aborts here.
    vm_args+=(
        -chardev "socket,id=${id},path=${vm_socket}"
        -device "vhost-user-fs-pci,chardev=${id},tag=${vm_dst}"
    )
}

vm_run_qemu() {
    # bwrap:
    # bwrap --unshare-all --cap-drop ALL --die-with-parent \\
    #     --ro-bind /nix/store /nix/store \\
    #     --dev-bind /dev/kvm /dev/kvm \\
    #     --dev-bind /dev/urandom /dev/urandom \\
    #     --dev-bind /dev/iommu /dev/iommu \\
    #     --dev-bind /dev/vfio/vfio /dev/vfio/vfio \\
    #     --dev-bind /dev/vfio/XX /dev/vfio/XX \\
    #     --ro-bind "/ssd/vm/${vm_name}.qcow2" "/ssd/vm/${vm_name}.qcow2" \\
    #     --ro-bind /run/libvirt/nix-ovmf/edk2-x86_64-code.fd /run/libvirt/nix-ovmf/edk2-x86_64-code.fd \\
    #     --ro-bind /ssd/public/vm/kernels/vm-r73-nvda-pods-vsock-public-BOOTX64.efi /ssd/public/vm/kernels/vm-r73-nvda-pods-vsock-public-BOOTX64.efi \\
    #     --bind /run /run \\
    #     --ro-bind "$(which qemu-system-x86_64)" "$(which qemu-system-x86_64)" \\
    #     qemu-system-x86_64 \\
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
        -kernel ${vm_kernel} \
        -sandbox on,obsolete=deny,elevateprivileges=deny,spawn=deny,resourcecontrol=deny \
        -object rng-random,id=rng,filename=/dev/urandom \
        -device virtio-rng-pci,rng=rng \
        -display none \
        -device vhost-vsock-pci,guest-cid=3 \
        -serial stdio \
        -monitor none \
        -drive file="${vm_disk}",if=virtio,format=qcow2,discard=unmap \
        -object iommufd,id=iommufd0 \
        -device vfio-pci,host=0000:41:00.0,iommufd=iommufd0 \
        -device vfio-pci,host=0000:41:00.1,iommufd=iommufd0 \
        "${vm_args[@]}"
}

vm_start_hermes() {
    vm_name="hermes"

    trap vm_cleanup EXIT INT TERM

    vm_args=()
    # Prefer /run/tigor-vm/${vm_name}/ with separate helper subdirectories and
    # ownership. QEMU only needs search/connect access; helpers should not share
    # one writable socket directory.
    vm_kernel="/ssd/public/vm/kernels/vm-r73-nvda-pods-vsock-public-BOOTX64.efi"
    vm_disk="/ssd/public/vm/hermes/hermes.qcow2"
    vm_cpu="128"
    vm_ram="256"
    vm_gpu="1"
    vm_vsock="1"
    vm_ui="1"

    vm_setup_wireguard
    vm_mac="52:54:00:a9:f5:da" vm_socket="/run/${vm_name}-passt.sock" vm_add_passt

    id="fs-ssd-internet" vm_src="/ssd/public/internet" vm_dst="/ssd/public/internet" vm_ro="1" vm_socket="/run/${vm_name}-ssd-internet.sock" vm_add_virtiofsd
    id="fs-hdd-internet" vm_src="/hdd/public/internet" vm_dst="/hdd/public/internet" vm_ro="1" vm_socket="/run/${vm_name}-hdd-internet.sock" vm_add_virtiofsd
    id="fs-hermes" vm_src="/ssd/public/vm/hermes/data" vm_dst="/ssd/public/vm/hermes/data" vm_ro="0" vm_socket="/run/${vm_name}-hermes.sock" vm_add_virtiofsd
    id="fs-telegraf" vm_src="/ssd/public/vm/hermes/telegraf" vm_dst="/ssd/public/telegraf" vm_ro="0" vm_socket="/run/${vm_name}-telegraf.sock" vm_add_virtiofsd

    # vm_wait_socket proves only that the pathname became a socket. Consider
    # retaining each helper PID and failing if it exits before/while QEMU starts;
    # cleanup can then kill known PIDs instead of every background shell job.
    vm_run_qemu

    vm_cleanup
}

vm_start_hermes
