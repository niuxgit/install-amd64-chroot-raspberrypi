#!/usr/bin/env bash
# install-amd64-chroot.sh
# Bootstraps an amd64 Debian rootfs and installs a helper to enter it.

set -euo pipefail

ROOT=/opt/amd64-root
DIST=bookworm         # change to "stable", "testing", or "noble" (Ubuntu) if you like
MIRROR=http://deb.debian.org/debian

if [[ $EUID -ne 0 ]]; then
  echo "[*] Please run as root (use sudo)." >&2
  exit 1
fi

echo "[*] Installing prerequisites..."
apt update
apt install -y debootstrap qemu-user-static binfmt-support

echo "[*] Creating root directory at $ROOT"
mkdir -p "$ROOT"

echo "[*] Bootstrapping $DIST amd64 into $ROOT..."
debootstrap --arch=amd64 "$DIST" "$ROOT" "$MIRROR"

echo "[*] Copying qemu-x86_64-static into chroot..."
cp /usr/bin/qemu-x86_64-static "$ROOT/usr/bin/"

echo "[*] Writing basic config files..."
echo "nameserver 1.1.1.1" > "$ROOT/etc/resolv.conf"
cat > "$ROOT/etc/fstab" <<EOF
proc    /proc   proc    defaults 0 0
sysfs   /sys    sysfs   defaults 0 0
EOF

echo "[*] Installing amd64-chroot helper..."
cat > /usr/local/bin/amd64-chroot <<'EOS'
#!/usr/bin/env bash
# amd64-chroot helper script
set -euo pipefail

ROOT=/opt/amd64-root
SHARED_HOST=/mnt/shared
SHARED_GUEST=/mnt/shared

mount_if_needed() {
  local target="$1" type="$2" src="$3"
  install -d -m 0755 "$target"
  if ! mountpoint -q "$target"; then
    if [[ "$type" == "bind" ]]; then
      install -d -m 0755 "$src"
      mount --bind "$src" "$target"
    else
      mount -t "$type" "$src" "$target"
    fi
  fi
}

mount_all() {
  mount_if_needed "$ROOT/proc" proc proc
  mount_if_needed "$ROOT/sys" sysfs sysfs
  mount_if_needed "$ROOT/dev" bind /dev
  mount_if_needed "$ROOT/dev/pts" bind /dev/pts
  mount_if_needed "$ROOT/run" bind /run
  install -d -m 0755 "$SHARED_HOST" "$ROOT$SHARED_GUEST"
  mount_if_needed "$ROOT$SHARED_GUEST" bind "$SHARED_HOST"
}

umount_all() {
  for p in "$ROOT$SHARED_GUEST" "$ROOT/dev/pts" "$ROOT/dev" "$ROOT/run" "$ROOT/proc" "$ROOT/sys"; do
    mountpoint -q "$p" && umount -l "$p" || true
  done
}

case "${1:-enter}" in
  enter|"")
    mount_all
    echo "[*] Entering amd64 chroot at $ROOT"
    chroot "$ROOT" /bin/bash
    ;;
  mount) mount_all ;;
  umount|unmount) umount_all ;;
  status)
    for p in "$ROOT/proc" "$ROOT/sys" "$ROOT/dev" "$ROOT/dev/pts" "$ROOT/run" "$ROOT$SHARED_GUEST"; do
      [[ -e "$p" ]] || continue
      if mountpoint -q "$p"; then echo "[mounted] $p"; else echo "[not mounted] $p"; fi
    done
    ;;
  *) echo "Usage: $0 [enter|mount|umount|status]" >&2; exit 2 ;;
esac
EOS

chmod +x /usr/local/bin/amd64-chroot

echo "[*] Done!"
echo "    Enter the environment with: amd64-chroot"
echo "    Inside, run 'uname -m' → should say x86_64"
