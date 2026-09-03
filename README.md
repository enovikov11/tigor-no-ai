# Tigor no AI Monorepo

> **Note:** Tigor AI Monorepo is autonomously edited by an AI agent under human direction and self-feedback loops. It is not a security boundary or source of truth. Control is primarily retroactive, with traceability enforced by linear git history.

> **Note:** Tigor no AI Monorepo requires human review for all commits. It contains authoritative specifications and security-critical code enforcing compartmentalization, virtualization, ACLs and specifications to build AI code upon.

See also https://github.com/enovikov11/tigor-ai

| Domain  | Internet     | Virtualization | Cache encrypted | File sharing     |
| ------- | ------------ | -------------- | --------------- | ---------------- |
| Public  | Unrestricted | KVM            | No              | Public           |
| Private | Data diode   | KVM            | No              | Public + Private |
| Secret  | No           | KVM + SEV-ES   | Yes             | No               |

## Build

cd /etc/tigor/

diff flake.nix flake.nix.bak
diff vm.sh vm.sh.bak
diff vm.xsl vm.xsl.bak

nix build .#vm
cp ./result/vm-*-BOOTX64.efi /ssd/public/vm/kernels/
echo -e '\a'

nix build .#host
mkdir /root/mnt
mount /dev/sde1 /root/mnt
df -h /root/mnt
mv /root/mnt/EFI/BOOT/BOOTX64.efi /root/mnt/EFI/BOOT/"$(date '+%Y-%m-%d_%H-%M-%S')_BOOTX64.efi"
cp ./result/host-*-BOOTX64.efi /root/mnt/EFI/BOOT/BOOTX64.efi
echo -e '\a'

sync && reboot now

## Code

find . -type f -exec sha256sum {} +
find . -type d -name .cache -prune -exec rm -rf {} +

cd /hdd/public/internet
cd /ssd/public/internet
find ./huggingface* -mindepth 2 -maxdepth 2 -type d -exec du -sh {} +
> /ssd/public/vm/hermes/data/hdd-sizes.txt

ssh box
ssh -J box root@127.0.0.1 -p 2222

ssh-keygen -R vm
ssh -o 'ProxyCommand=ssh box socat - VSOCK-CONNECT:3:22' root@vm

qemu-img create -f qcow2 /ssd/vm/hermes.qcow2 500G
mkfs.ext4 -L data /dev/vda
chown -R nixos:users /home/nixos

nixos-rebuild switch --flake .#vm --override flake.nix '{ modules = [{ networking.firewall.enable = true; }]; }'

sshfs nixos@10.67.69.2:/home/nixos /home/nixos -o Port=2222,reconnect
echo o > /proc/sysrq-trigger
nft flush ruleset

codeberg.org/forgejo/forgejo:16
podman pull docker.io/vllm/vllm-openai:nightly
podman save docker.io/vllm/vllm-openai:nightly | gzip > /home/nixos/vllm.tar.gz
gunzip -c vllm.tar.gz | podman load

cd /ssd/internet
chown -R nixos:users .
find . -type d -exec chmod 2775 {} +
find . -type f -exec chmod 664 {} +

podman load < result
ls /run/netns
virsh undefine hermes --nvram
xsltproc --nonet vm.xsl vm.xsl

chmod 777 /run/user/1000/podman/podman.sock

podman run -it --rm --name hf-downloader -v /ssd/public/internet/huggingface.co-temp:/data docker.io/library/python:3.12-slim bash
pip install -q huggingface_hub
hf auth login
model="primitive-ai/Qwen3.8-Flash-Next-NVFP4"
hf download $model --local-dir "/data/$model"

## TODO

Gateway: matrix, element.io X/Web, Synapse, mattermost
Memory: https://github.com/plastic-labs/honcho honcho.dev, qdrant, graphify

need_restart Gpu burn & telegraf
need_restart vm.sh: compare with qemu libvirt command
need_review Networking: vpn-vnext.sh, https://github.com/enovikov11/tigor-ai/pull/33

vm.sh: non-root + premade sockets by root
vm.sh: make all args
vm.sh: test bubblewrap (need nested)

LLM config/benchmark on context, model and hardware

Data diode

Minimax H3
Snapshots for img
Load pods on demand
N8n

Autonomous semi-isolated task api: 1 message/call = agent spawn
Secrets scanning
Sec invariants check
Secureboot + tpm
Gpu reset
Make a commits scanner with memory and gateway
Experiment with Dflash
Independent builder
Reject GPG unverified
Git scan: license
Git scan: commits summary and digest
Nixos config compartmentalization, less privileged code
Simplify nix on amount of hidden options, shown via full eval
Better hash algo: mkpasswd -m yescrypt -R 11
ai-isolation.md
lto.md
hash-fs.md
anti-overengineering.md
power-infra.md
firecracker
Cloud init ssh host key
vm.sh: control plane via tg/web
Mullvad + DO
Stream VM log with tee
Better internet search
Token count and model used reporting in commits
Delete obsolete experiments from tigor-ai
Tigor-vps

### Data diode & data hoarding /internet

Docker images
Telegram proxy
Nix copy
Git clone

"https://github.com", "https://gitlab.com",
"https://codeload.github.com", "https://raw.githubusercontent.com",
"https://registry.npmjs.org", "https://files.pythonhosted.org",
"https://pypi.org", "https://cache.nixos.org",
"https://registry-1.docker.io", "https://ghcr.io", "https://quay.io",

### Better hermes

https://honcho.dev/docs/v3/guides/integrations/hermes
Хранение сессий, проектов и извлечение релевантного контекста перед ответом

https://github.com/qdrant/qdrant
Qdrant как векторное хранилище для semantic search / RAG внутри Hermes
Коллекции, embeddings, индексацию документов и API поиска для инструментов

https://graphify.net
Graphify как knowledge graph skill, извлечение графа из кода, документов и заметок, а также запросы к графу

### Invariants to check via tests

- VM cannot send or receieve any packages outside of wg tunnel
- VM cannot execute any code at host, cannot read its memory via DMA on GPU
- VM cannot login to 10.67.69.1

### Misc

Dump rtx pro Nvidia chip dump for backup
SEV ES & nvidia-smi conf-compute -q
Reproducible builds verifyer for other projects
Libreboot image with disc encryption
Denominations simulator - cash economy math model game
Jetkvm
Move to Xen from KVM
Buy CMP 170HX cluster

## .env example

TERMINAL_MODAL_IMAGE=nikolaik/python-nodejs:python3.11-nodejs20
OPENROUTER_API_KEY=
TELEGRAM_BOT_TOKEN=
TELEGRAM_ALLOWED_USERS=
TELEGRAM_HOME_CHANNEL=
GITHUB_TOKEN=

## Learnings

Memory can be encrypted with TSME, but it hurts perf
Numa, prefetcher, cpu timings, ram timings, boot guard
UMAF inspect
Editing chmod -x on all made vllm non executable and crashed inference and forgejo
