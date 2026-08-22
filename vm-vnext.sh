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

# --- Prerequisites ---

if [[ $EUID -ne 0 ]]; then
    echo "ERROR: this script must be run as root" >&2
    exit 1
fi

# --- Cleanup ---

vm_cleanup() {
    trap - EXIT INT TERM

    kill ${vm_pids[@]+"${vm_pids[@]}"} 2>/dev/null || true
    wait 2>/dev/null || true

    ip netns del "ns-${vm_name}" 2>/dev/null || true
}

# --- WireGuard / network namespace ---

vm_setup_wireguard() {
    ip netns del "ns-${vm_name}" 2>/dev/null || true
    ip link del "wg-${vm_name}" 2>/dev/null || true

    ip netns add "ns-${vm_name}"
    ip link add "wg-${vm_name}" type wireguard
    wg setconf "wg-${vm_name}" "/ssd/vm/ns-${vm_name}.conf"
    ip link set "wg-${vm_name}" netns "ns-${vm_name}"

    ip -n "ns-${vm_name}" addr add 10.67.69.2/24 dev "wg-${vm_name}"
    ip -n "ns-${vm_name}" link set "wg-${vm_name}" up
    ip -n "ns-${vm_name}" route add default via 10.67.69.1 dev "wg-${vm_name}"
}

# --- Helpers ---

vm_pids=()

vm_track_pid() {
    vm_pids+=($!)
}

vm_wait_socket() {
    for _ in {1..500}; do
        [[ -S "$vm_socket" ]] && return
        sleep 0.01
    done

    echo "ERROR: socket did not appear: $vm_socket" >&2
    return 1
}

# --- Bubblewrap sandbox ---
# Shared bwrap baseline: --unshare-all --cap-drop ALL --die-with-parent
# --new-session --clearenv. NixOS runtime closure and exact binds per-program.

_bwrap_base=()
_bwrap_base+=(
    --unshare-all
    --cap-drop ALL
    --die-with-parent
    --new-session
    --clearenv
    --ro-bind /nix/store /nix/store
)

# --- passt (vhost-user networking) ---

vm_add_passt() {
    rm -f "$vm_socket"
    # passt needs the host network namespace (--share-net) to use the prepared
    # WireGuard interface. Binds: /proc, runtime closure, socket dir, passt bin.

    ip netns exec "ns-${vm_name}" bwrap "${_bwrap_base[@]}" \
        --share-net \
        --dev-bind /dev /dev \
        --ro-bind /proc /proc \
        --bind "$(dirname "$vm_socket")" "$(dirname "$vm_socket")" \
        --ro-bind "$(which passt)" "$(which passt)" \
        passt \
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
    vm_track_pid

    vm_wait_socket
    vm_args+=(
        -chardev "socket,id=net0,path=${vm_socket}"
        -netdev "vhost-user,chardev=net0,id=net"
        -device "virtio-net-pci,netdev=net,mac=${vm_mac},romfile="
    )
}

# --- virtiofsd (shared filesystem) ---

vm_add_virtiofsd() {
    rm -f "$vm_socket"
    # virtiofsd only needs its shared dir, a socket to listen on, and /proc.
    # RO binds for shared sources; RW only for writable shares.

    _virtiofsd_bin="$(which virtiofsd)"

    if ((vm_ro)); then
        bwrap "${_bwrap_base[@]}" \
            --ro-bind "$vm_src" "$vm_src" \
            --bind "$(dirname "$vm_socket")" "$(dirname "$vm_socket")" \
            --ro-bind /proc /proc \
            --ro-bind "$_virtiofsd_bin" "$_virtiofsd_bin" \
            virtiofsd --socket-path="$vm_socket" --shared-dir="$vm_src" --readonly &
    else
        bwrap "${_bwrap_base[@]}" \
            --bind "$vm_src" "$vm_src" \
            --bind "$(dirname "$vm_socket")" "$(dirname "$vm_socket")" \
            --ro-bind /proc /proc \
            --ro-bind "$_virtiofsd_bin" "$_virtiofsd_bin" \
            virtiofsd --socket-path="$vm_socket" --shared-dir="$vm_src" &
    fi
    vm_track_pid

    vm_wait_socket
    vm_args+=(
        -chardev "socket,id=${id},path=${vm_socket}"
        -device "vhost-user-fs-pci,chardev=${id},tag=${vm_dst}"
    )
}

# --- QEMU ---

vm_run_qemu() {
    # QEMU gets the tightest bwrap profile: no network namespace (AF_UNIX only),
    # exact device nodes for KVM/VFIO/IOMMU, disk image, kernel, firmware, and
    # helper sockets. /dev is not exposed broadly — only specific nodes.

    bwrap "${_bwrap_base[@]}" \
        --dev-bind /dev/kvm /dev/kvm \
        --dev-bind /dev/urandom /dev/urandom \
        --dev-bind /dev/iommu /dev/iommu \
        --dev-bind /dev/vfio/vfio /dev/vfio/vfio \
        --dev-bind "/dev/vfio/$(ls /dev/vfio/ | grep -v vfio)" "/dev/vfio/$(ls /dev/vfio/ | grep -v vfio)" \
        --ro-bind "/ssd/vm/${vm_name}.qcow2" "/ssd/vm/${vm_name}.qcow2" \
        --ro-bind /run/libvirt/nix-ovmf/edk2-x86_64-code.fd /run/libvirt/nix-ovmf/edk2-x86_64-code.fd \
        --ro-bind /ssd/vm/vm-r37-nvda-pods-vsock-BOOTX64.efi /ssd/vm/vm-r37-nvda-pods-vsock-BOOTX64.efi \
        --bind /run /run \
        --ro-bind "$(which qemu-system-x86_64)" "$(which qemu-system-x86_64)" \
        qemu-system-x86_64 \
        -nodefaults \
        -no-user-config \
        -machine pc-q35-10.2,memory-backend=ram,usb=off,vmport=off,smm=off,dump-guest-core=off \
        -accel kvm \
        -cpu host,migratable=off \
        -object memory-backend-memfd,id=ram,size=256G,share=on,hugetlb=on,hugetlbsize=1G \
        -smp 128 \
        -rtc base=utc \
        -drive if=pflash,format=raw,readonly=on,file=/run/libvirt/nix-ovmf/edk2-x86_64-code.fd \
        -kernel /ssd/vm/vm-r37-nvda-pods-vsock-BOOTX64.efi \
        -sandbox on,obsolete=deny,elevateprivileges=deny,spawn=deny,resourcecontrol=deny \
        -object rng-random,id=rng,filename=/dev/urandom \
        -device virtio-rng-pci,rng=rng \
        -display none \
        -device vhost-vsock-pci,guest-cid=3 \
        -serial stdio \
        -monitor none \
        -drive file="/ssd/vm/${vm_name}.qcow2",if=virtio,format=qcow2,discard=unmap \
        -object iommufd,id=iommufd0 \
        -device vfio-pci,host=0000:41:00.0,iommufd=iommufd0 \
        -device vfio-pci,host=0000:41:00.1,iommufd=iommufd0 \
        ${vm_args[@]+"${vm_args[@]}"}}
}

# --- Entry point ---

vm_start_hermes() {
    vm_name="hermes"
    vm_pids=()

    trap vm_cleanup EXIT INT TERM

    vm_args=()
    vm_kernel="/ssd/vm/vm-r37-nvda-pods-vsock-BOOTX64.efi"
    vm_disk="/ssd/vm/hermes.qcow2"
    vm_cpu="128"
    vm_ram="256"
    vm_gpu="1"
    vm_vsock="1"
    vm_ui="1"
    # NOTE: vm_kernel/vm_disk/vm_cpu/vm_ram/... above are currently not consumed
    # by vm_run_qemu, which still hardcodes the corresponding QEMU arguments.

    vm_setup_wireguard
    vm_mac="52:54:00:a9:f5:da" vm_socket="/run/${vm_name}-passt.sock" vm_add_passt
    id="fs-internet"  vm_src="/ssd/internet"         vm_dst="/ssd/internet"         vm_ro="1" vm_socket="/run/${vm_name}-internet.sock"  vm_add_virtiofsd
    id="fs-kiwix"     vm_src="/hdd/internet/kiwix"   vm_dst="/hdd/internet/kiwix"   vm_ro="1" vm_socket="/run/${vm_name}-kiwix.sock"     vm_add_virtiofsd
    id="fs-wiki"      vm_src="/hdd/internet/wikipedia" vm_dst="/hdd/internet/wikipedia" vm_ro="1" vm_socket="/run/${vm_name}-wiki.sock" vm_add_virtiofsd
    id="fs-hermes"    vm_src="/ssd/vm/hermes"        vm_dst="/ssd/vm/hermes"        vm_ro="0" vm_socket="/run/${vm_name}-hermes.sock"    vm_add_virtiofsd
    id="fs-telegraf"  vm_src="/ssd/telegraf/hermes"  vm_dst="/ssd/telegraf/host"    vm_ro="0" vm_socket="/run/${vm_name}-telegraf.sock"  vm_add_virtiofsd
    # vm_wait_socket proves only that the pathname became a socket. Consider
    # retaining each helper PID and failing if it exits before/while QEMU starts;
    # cleanup can then kill known PIDs instead of every background shell job.
    vm_run_qemu

    vm_cleanup
}

vm_start_hermes
