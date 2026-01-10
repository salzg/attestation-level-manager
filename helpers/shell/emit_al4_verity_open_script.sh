#!/bin/sh
PREREQ=""
prereqs() { echo "$PREREQ"; }
case "$1" in prereqs) prereqs; exit 0;; esac

. /scripts/functions

panic_shell() {
  echo "AL4 verity open failed; debug shell. Type 'reboot -f' to exit." >&2
  sh
  # If shell exits, do NOT continue
  echo "Shell exited; halting." >&2
  while true; do sleep 60; done
}

CONF="/etc/alman/boot-guard.conf"
ROOT_PART="/dev/vda2"
HASH_DEV="/dev/vdb"

if [ -r "$CONF" ]; then . "$CONF" || true; fi

CMDLINE="$(cat /proc/cmdline 2>/dev/null || true)"
ROOTHASH="$(printf '%s\n' "$CMDLINE" | sed -n 's/.*alman_roothash=\([0-9a-fA-F]\{64\}\).*/\1/p')"

[ -n "$ROOTHASH" ] || panic_shell

modprobe dm_mod 2>/dev/null || true
modprobe dm_verity 2>/dev/null || true

command -v veritysetup >/dev/null 2>&1 || panic_shell

# If the DM mapping already exists, treat as success
if dmsetup info -c --noheadings -o name vroot >/dev/null 2>&1; then
  echo "[AL4] vroot mapping already exists; skipping veritysetup open."
else
  if ! veritysetup open "$ROOT_PART" vroot "$HASH_DEV" "$ROOTHASH" 2>/tmp/verity.err; then
    # Some builds return non-zero with "Device <device> already exists" – treat that as success.
    if grep -qi "already exists" /tmp/verity.err 2>/dev/null; then
      echo "[AL4] vroot reported as already existing; continuing."
    else
      cat /tmp/verity.err >&2 || true
      panic_shell
    fi
  fi
fi

echo "[AL4] dm-verity mapping /dev/mapper/vroot ready."
