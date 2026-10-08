# After boot

mnt
vim vm.sh
tmux
. vm.sh
run_hermes
tmux a -t 0

# vm

cd tigor-ai
podman compose up -d
