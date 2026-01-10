#!/bin/sh
# /etc/initramfs-tools/hooks/alman_include_veritysetup
set -e
PREREQ=""
prereqs() { echo "$PREREQ"; }
case "$1" in
  prereqs) prereqs; exit 0;;
esac

. /usr/share/initramfs-tools/hook-functions

# Find veritysetup in the rootfs
V="$(command -v veritysetup 2>/dev/null || true)"
if [ -z "$V" ]; then
  for p in /usr/sbin/veritysetup /sbin/veritysetup /bin/veritysetup; do
    [ -x "$p" ] && V="$p" && break
  done
fi

if [ -z "$V" ] || [ ! -x "$V" ]; then
  echo "alman: veritysetup not found in rootfs; ensure cryptsetup-bin is installed" >&2
  exit 0
fi

# copy_exec copies the binary AND required shared libraries into the initramfs
copy_exec "$V" /sbin
