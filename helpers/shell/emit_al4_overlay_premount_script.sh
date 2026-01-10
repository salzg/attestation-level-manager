#!/bin/sh
PREREQ=""
prereqs() { echo "$PREREQ"; }
case "$1" in prereqs) prereqs; exit 0;; esac

. /scripts/functions

panic_shell() {
  echo "AL4 overlay premount function failed; debug shell. Type 'reboot -f' to exit." >&2
  sh
  # If shell exits, do NOT continue
  echo "Shell exited; halting." >&2
  while true; do sleep 60; done
}

CONF="/etc/alman/boot-guard.conf"

# Defaults (can be overridden by CONF)
UPPER_DEV="/dev/vdc"
AL4_UPPER_MODE="disk"     # disk|tmpfs
AL4_TMPFS_SIZE="0"        # e.g. 512M, 1G

if [ -r "$CONF" ]; then . "$CONF" || true; fi

modprobe overlay 2>/dev/null || true

# rootmnt is the already-mounted RO verity root
[ -d "${rootmnt}" ] || panic_shell

mkdir -p /mnt/overlayroot

if [ "${AL4_UPPER_MODE}" = "tmpfs" ]; then
  # RAM-only upper/work; ephemeral across reboots
  mkdir -p /run/alman-overlay

  if [ -z "${AL4_TMPFS_SIZE}" ] || [ "${AL4_TMPFS_SIZE}" = "0" ]; then
    AL4_TMPFS_SIZE="1024M"
  fi

  mount -t tmpfs -o "mode=0755,size=${AL4_TMPFS_SIZE}" tmpfs /run/alman-overlay || panic_shell

  mkdir -p /run/alman-overlay/upper /run/alman-overlay/work
  mount -t overlay overlay -o "lowerdir=${rootmnt},upperdir=/run/alman-overlay/upper,workdir=/run/alman-overlay/work" /mnt/overlayroot || panic_shell
else
  # Disk-backed upper/work; persistent
  mkdir -p /mnt/uppermnt
  mount -t ext4 "$UPPER_DEV" /mnt/uppermnt || panic_shell
  mkdir -p /mnt/uppermnt/upper /mnt/uppermnt/work
  mount -t overlay overlay -o "lowerdir=${rootmnt},upperdir=/mnt/uppermnt/upper,workdir=/mnt/uppermnt/work" /mnt/overlayroot || panic_shell
fi

mount --move /mnt/overlayroot "${rootmnt}" || panic_shell
echo "[AL4] overlay mounted on top of verity root (mode=${AL4_UPPER_MODE})."
