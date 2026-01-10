#!/bin/sh
set -e
PREREQ=""
prereqs() { echo "$PREREQ"; }
case "$1" in prereqs) prereqs; exit 0;; esac
. /usr/share/initramfs-tools/hook-functions
SRC="/etc/alman/boot-guard.conf"
DSTDIR="${DESTDIR}/etc/alman"
mkdir -p "$DSTDIR"
if [ -f "$SRC" ]; then
  cp -a "$SRC" "${DSTDIR}/boot-guard.conf"
else
  : > "${DSTDIR}/boot-guard.conf"
fi
