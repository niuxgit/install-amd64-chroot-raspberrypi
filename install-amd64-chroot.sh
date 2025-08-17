#!/usr/bin/env bash
# install-amd64-chroot.sh
# Bootstraps an amd64 Debian rootfs and installs a safer helper to enter it.

set -euo pipefail

ROOT=/opt/amd64-root
DIST=bookworm                   # change to "stable", "testing", etc.
MIRROR=http://deb.debian.org/debian
SHARED_HOST=/mnt/shared         # host side shared dir

if [[ $EUID -ne 0 ]]; then
  echo "[*] Please run as root (use sudo)." >&2
  exit 1
fi

echo "[*] Installing prerequisites..."
apt update
apt install -y debootstrap qemu-user-static binfmt-support

echo "[*] Creating root directory at $ROOT"
mkdir -p "$ROOT"
mkdir -p "$SHARED_HOST"

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

echo "[*] Installing amd64-chroot helper (safer, non-root by default)..."
cat > /usr/local/bin/amd64-chroot <<'EOS'
#!/usr/bin/env bash
# amd64-chroot: mount & enter an amd64 debootstrap chroot safely (non-root by default)
# Usage:
#   amd64-chroot              # mount + enter as non-root user (svc by default)
#   amd64-chroot enter        # same as above
#   amd64-chroot root         # mount + enter as root (interactive)
#   amd64-chroot root -- CMD  # run one-off root CMD inside and exit
#   amd64-chroot mount        # just mount required filesystems
#   amd64-chroot umount       # unmount bind mounts
#   amd64-chroot status       # show what's mounted and user info

set -euo pipefail

# --- config (override via env) ---
ROOT="${ROOT:-/opt/amd64-root}"
SHARED_HOST="${SHARED_HOST:-/mnt/shared}"
SHARED_GUEST="${SHARED_GUEST:-/mnt/shared}"
CHROOT_USER="${CHROOT_USER:-svc}"            # username inside chroot
MAP_HOST_IDS="${MAP_HOST_IDS:-1}"            # 1 = map to invoking host UID:GID
EXTRA_GROUPS="${EXTRA_GROUPS:-}"             # e.g. "audio,video,plugdev"
USE_SHARED="${USE_SHARED:-1}"

# --- self-elevate for mounts/chroot ---
if [[ $EUID -ne 0 ]]; then
  exec sudo --preserve-env=ROOT,SHARED_HOST,SHARED_GUEST,CHROOT_USER,MAP_HOST_IDS,EXTRA_GROUPS,USE_SHARED "$0" "$@"
fi

msg(){ printf '[*] %s\n' "$*"; }
err(){ printf '[!] %s\n' "$*" >&2; }

need_root_exists(){
  [[ -d "$ROOT" ]] || { err "ROOT '$ROOT' does not exist. Run the installer first."; exit 1; }
}

mount_if_needed(){
  local target="$1" type="$2" src="$3"
  install -d -m0755 "$target"
  mountpoint -q "$target" && return 0
  if [[ "$type" == "bind" ]]; then
    install -d -m0755 "$src"
    mount --bind "$src" "$target"
  else
    mount -t "$type" "$src" "$target"
  fi
}

mount_all(){
  need_root_exists
  mount_if_needed "$ROOT/proc"     proc  proc
  mount_if_needed "$ROOT/sys"      sysfs sysfs
  mount_if_needed "$ROOT/dev"      bind  /dev
  mount_if_needed "$ROOT/dev/pts"  bind  /dev/pts
  mount_if_needed "$ROOT/run"      bind  /run
  if [[ "$USE_SHARED" -eq 1 ]]; then
    install -d -m0755 "$SHARED_HOST" "$ROOT$SHARED_GUEST"
    mountpoint -q "$ROOT$SHARED_GUEST" || mount --bind "$SHARED_HOST" "$ROOT$SHARED_GUEST"
  fi
}

umount_all(){
  # unmount in reverse order
  local paths=(
    "$ROOT$SHARED_GUEST"
    "$ROOT/dev/pts"
    "$ROOT/dev"
    "$ROOT/run"
    "$ROOT/proc"
    "$ROOT/sys"
  )
  for p in "${paths[@]}"; do
    mountpoint -q "$p" && umount -l "$p" || true
  done
}

# run a command inside the chroot as root
xin(){ chroot "$ROOT" /bin/bash -lc "$*"; }

ensure_tools_inside(){
  # Usually present, but just in case on minimal bootstraps
  xin "command -v getent >/dev/null || (apt-get update && apt-get install -y libc-bin)"
  xin "command -v useradd >/dev/null || (apt-get update && apt-get install -y passwd)"
}

ensure_user_inside(){
  ensure_tools_inside

  local host_uid host_gid group_opt=""
  if [[ "${MAP_HOST_IDS}" -eq 1 ]]; then
    if [[ -n "${SUDO_UID-}" && -n "${SUDO_GID-}" ]]; then
      host_uid="$SUDO_UID"; host_gid="$SUDO_GID"
    else
      host_uid=0; host_gid=0
    fi
    [[ "$host_uid" -ne 0 ]] && group_opt="-g $host_gid -u $host_uid"
  fi

  # if user already exists, we're done
  xin "getent passwd ${CHROOT_USER} >/dev/null" && return 0

  msg "Creating user '${CHROOT_USER}' inside chroot…"
  if [[ -n "$group_opt" ]]; then
    xin "getent group $host_gid >/dev/null || groupadd -g $host_gid ${CHROOT_USER}"
    xin "id -u ${CHROOT_USER} >/dev/null 2>&1 || useradd -m -s /bin/bash -u $host_uid -g $host_gid ${CHROOT_USER}"
  else
    xin "id -u ${CHROOT_USER} >/dev/null 2>&1 || useradd -m -s /bin/bash ${CHROOT_USER}"
  fi

  if [[ -n "$EXTRA_GROUPS" ]]; then
    xin "for g in ${EXTRA_GROUPS//,/ }; do getent group \"\$g\" >/dev/null || groupadd \"\$g\"; done"
    xin "usermod -a -G ${EXTRA_GROUPS} ${CHROOT_USER}"
  fi

  xin "chsh -s /bin/bash ${CHROOT_USER} >/dev/null 2>&1 || true"
}

enter_as_user(){
  ensure_user_inside
  local uid gid home
  uid="$(xin "id -u ${CHROOT_USER}")"
  gid="$(xin "id -g ${CHROOT_USER}")"
  home="$(xin "getent passwd ${CHROOT_USER} | cut -d: -f6")"
  exec chroot --userspec="${uid}:${gid}" "$ROOT" /usr/bin/env -i \
    HOME="${home}" USER="${CHROOT_USER}" LOGNAME="${CHROOT_USER}" \
    SHELL="/bin/bash" PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
    /bin/bash -l
}

enter_as_root(){ exec chroot "$ROOT" /bin/bash -l; }

status_all(){
  echo "ROOT: $ROOT"
  echo "USER inside: ${CHROOT_USER} (map host ids: ${MAP_HOST_IDS})"
  echo "Shared: host '$SHARED_HOST' -> guest '$SHARED_GUEST' (enabled: $USE_SHARED)"
  for p in "$ROOT/proc" "$ROOT/sys" "$ROOT/dev" "$ROOT/dev/pts" "$ROOT/run" "$ROOT$SHARED_GUEST"; do
    [[ -e "$p" ]] || continue
    if mountpoint -q "$p"; then echo "[mounted] $p"; else echo "[not mounted] $p"; fi
  done
  [[ -f "$ROOT/etc/passwd" ]] && xin "getent passwd ${CHROOT_USER} || true"
}

case "${1:-enter}" in
  enter|"")
    mount_all
    msg "Entering amd64 chroot at $ROOT as user '${CHROOT_USER}'"
    enter_as_user
    ;;
  root)
    mount_all
    shift
    if [[ $# -gt 0 ]]; then
      # run one-off command as root inside the chroot
      xin "$*"
    else
      msg "Entering amd64 chroot at $ROOT as ROOT"
      enter_as_root
    fi
    ;;
  mount)  mount_all ;;
  umount|unmount) umount_all ;;
  status) status_all ;;
  *) err "Usage: $0 [enter|root [-- CMD]|mount|umount|status]"; exit 2 ;;
esac
EOS

chmod +x /usr/local/bin/amd64-chroot

echo "[*] Done!"
echo "    Enter as unprivileged user:   amd64-chroot"
echo "    Admin shell as root:          amd64-chroot root"
echo "    One-off root command:         amd64-chroot root -- 'apt update && apt -y install sudo'"
echo "    Inside, 'uname -m' should show: x86_64"
