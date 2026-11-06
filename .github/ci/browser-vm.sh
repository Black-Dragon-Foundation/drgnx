#!/usr/bin/env bash
# A Fedora 45 VM on an x64 CI runner, for the tests that need a kernel the runner lacks: the agent browser's layer needs
# Landlock ABI 9 (Linux 7.1), and GitHub's Ubuntu runners boot Linux 7.0 (ABI 8). Fedora 45's kernel has it, as the
# Fedora hosts drgnx supports do. The VM boots the pinned Fedora Cloud image (its sha256 checked) under QEMU, with KVM
# when the runner allows it, else emulated; cloud-init gives it a user `runner` with passwordless sudo and the key
# made here, reached over ssh on a forwarded loopback port.
#   browser-vm.sh up DIR             install QEMU, fetch and check the image, boot it, wait for ssh (DIR: its files)
#   browser-vm.sh put DIR PATH...    copy each absolute PATH (a file or a folder) to the same path in the VM, owned by
#                                    `runner` (a PATH under /usr stays root's: Gleipnir trusts only a root-owned bwrap)
#   browser-vm.sh run DIR CMD        CMD (one shell string) as `runner` in a login shell; its exit code is ours
#   browser-vm.sh down DIR           power it off
# Needs root or passwordless sudo, and apt (an Ubuntu runner). Exit 1 on a failure, 2 on a usage error.
# docs/develop/ci.md, "The browser rows in a VM"
set -eu -o pipefail

usage() { echo "usage: browser-vm.sh up|put|run|down DIR [ARGS...]" >&2; exit 2; }
[ $# -ge 2 ] || usage
cmd=$1 dir=$2; shift 2
root() { if [ "$(id -u)" = 0 ]; then "$@"; else sudo "$@"; fi; }
port=2222
ssh_vm() {
  ssh -F /dev/null -i "$dir/key" -o IdentitiesOnly=yes -o IdentityAgent=none -o BatchMode=yes \
    -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=5 \
    -p "$port" runner@127.0.0.1 "$@"
}

case "$cmd" in
  up)
    mkdir -p "$dir"
    rel=https://download.fedoraproject.org/pub/fedora/linux/releases/45/Cloud
    case "$(uname -m)" in
      x86_64)
        img=Fedora-Cloud-Base-Generic-45-1.4.x86_64.qcow2
        sha=50bdc5e70f6a24f540932d15411c1c6ae9fcfa40fb990d876d83c5cc823b2ad0
        url=$rel/x86_64/images/$img
        pkgs=(qemu-system-x86 qemu-utils cloud-image-utils openssh-client)
        qemu=(qemu-system-x86_64 -machine q35) ;;
      # no arm64 image: the arm runners have no KVM, and emulated the guest never answered (docs/develop/ci.md)
      *) echo "browser-vm.sh: no image for $(uname -m)" >&2; exit 1 ;;
    esac
    root apt-get update -q
    root env DEBIAN_FRONTEND=noninteractive apt-get install -y -q --no-install-recommends "${pkgs[@]}" >/dev/null
    curl -fsSL --retry 5 -o "$dir/base.qcow2" "$url"
    echo "$sha  $dir/base.qcow2" | sha256sum -c -
    qemu-img create -q -f qcow2 -b "$dir/base.qcow2" -F qcow2 "$dir/disk.qcow2" 20G
    ssh-keygen -q -t ed25519 -N '' -f "$dir/key"
    printf '%s\n' '#cloud-config' 'ssh_pwauth: false' 'users:' '  - name: runner' '    shell: /bin/bash' \
      "    sudo: 'ALL=(ALL) NOPASSWD:ALL'" '    ssh_authorized_keys:' "      - $(cat "$dir/key.pub")" \
      > "$dir/user-data"
    printf 'instance-id: drgnx-browser-vm\nlocal-hostname: drgnx-vm\n' > "$dir/meta-data"
    cloud-localds "$dir/seed.img" "$dir/user-data" "$dir/meta-data"
    # KVM when the runner gives it (GitHub's x64 runners do, to their own user after a chmod), else emulation; a
    # chmod that is refused (a device passed into a container) leaves the device as it is
    [ ! -e /dev/kvm ] || [ -w /dev/kvm ] || root chmod 0666 /dev/kvm || true
    if [ -w /dev/kvm ]; then accel=(-accel kvm -cpu host); else accel=(-accel "tcg,thread=multi" -cpu max); fi
    echo "browser-vm: ${qemu[0]} ${accel[*]}"
    "${qemu[@]}" "${accel[@]}" -m 4096 -smp "$(nproc)" -display none -daemonize -pidfile "$dir/qemu.pid" \
      -serial "file:$dir/console.log" \
      -drive "if=virtio,format=qcow2,file=$dir/disk.qcow2" -drive "if=virtio,format=raw,file=$dir/seed.img" \
      -netdev "user,id=n0,hostfwd=tcp:127.0.0.1:$port-:22" -device virtio-net-pci,netdev=n0,romfile=
    # cloud-init has made the user once ssh lets it in; emulated, the boot takes minutes
    deadline=$(( $(date +%s) + 1200 ))
    until ssh_vm true 2>/dev/null; do
      if [ "$(date +%s)" -ge "$deadline" ] || ! kill -0 "$(cat "$dir/qemu.pid")" 2>/dev/null; then
        echo "browser-vm.sh: the VM did not answer over ssh; its console:" >&2; tail -n 40 "$dir/console.log" >&2
        exit 1
      fi
      sleep 5
    done
    ssh_vm 'cloud-init status --wait >/dev/null; uname -r; cat /sys/kernel/security/lsm; echo'
    ;;
  put)
    [ $# -ge 1 ] || usage
    for p in "$@"; do case "$p" in /*) ;; *) echo "browser-vm.sh: $p is not absolute" >&2; exit 2 ;; esac; done
    rel=(); for p in "$@"; do rel+=("${p#/}"); done
    # as root on both sides, so owners and modes come along; then everything outside /usr is runner's
    root tar -C / -cf - "${rel[@]}" | ssh_vm 'sudo tar -C / -xpf -'
    for p in "$@"; do
      case "$p" in /usr/*) ;; *) ssh_vm "sudo chown -R runner: '$p'" ;; esac
    done
    ;;
  run)
    [ $# = 1 ] || usage
    ssh_vm "bash -lc $(printf '%q' "$1")"
    ;;
  down)
    ssh_vm 'sudo systemctl poweroff' 2>/dev/null || true
    pid=$(cat "$dir/qemu.pid" 2>/dev/null || true)
    if [ -n "$pid" ]; then
      for _ in $(seq 60); do kill -0 "$pid" 2>/dev/null || exit 0; sleep 1; done
      kill "$pid" 2>/dev/null || true
    fi
    ;;
  *) usage ;;
esac
