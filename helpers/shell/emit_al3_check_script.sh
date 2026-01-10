#!/bin/sh
PREREQ=""
prereqs() { echo "$PREREQ"; }
case "$1" in prereqs) prereqs; exit 0;; esac

# If verification fails, open an emergency shell
panic_shell() {
  echo "AL3 kernel-hash check failed; debug shell. Type 'reboot -f' to exit." >&2
  sh
  # If shell exits, do NOT continue
  echo "Shell exited; halting." >&2
  while true; do sleep 60; done;
}

CONF="/etc/alman/boot-guard.conf"
EXPECTED_KERNEL_SHA256=""
EXPECTED_INITRD_SHA256=""
if [ -r "$CONF" ]; then . "$CONF" || true; fi

# NOTE: This is a defense-in-depth policy gate (not standard AMD kernel-hashes measurement path)
# It can be left empty if you rely solely on kernelHashes measurement
if [ -n "$EXPECTED_KERNEL_SHA256" ]; then
  if [ -r /boot/vmlinuz ]; then
    ACTUAL="$(sha256sum /boot/vmlinuz | awk '{print $1}')"
    [ "$ACTUAL" = "$EXPECTED_KERNEL_SHA256" ] || panic_shell
  else
    panic_shell
  fi
fi
if [ -n "$EXPECTED_INITRD_SHA256" ]; then
  if [ -r /boot/initrd.img ]; then
    ACTUAL="$(sha256sum /boot/initrd.img | awk '{print $1}')"
    [ "$ACTUAL" = "$EXPECTED_INITRD_SHA256" ] || panic_shell
  else
    panic_shell
  fi
fi
echo "[AL3] kernel hashing check passed."
