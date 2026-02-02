#!/usr/bin/env bash
set -euo pipefail

# alman.sh
#
# AMD SEV-SNP Ubuntu VM builder/manager for Attestation Levels (AL) 0...4
# - Uses QEMU/KVM + libvirt/virsh
# - Assumes QEMU + OVMF built via AMDSEV snp-latest; pass via env or flags
# - Builds Ubuntu 24.04 (noble) images
# - Installs snpguest into the base image (and thus into all cloned VMs)
# - wraps some common virsh commands (define, start, console, undefine, destroy)
#
# AL split (per AMDESE instructions for kernel-hashes=on):
#   AL1/AL2: disk boot (OVMF -> bootloader -> kernel from guest disk).
#   AL3/AL4: direct kernel boot (<kernel>, <initrd>, <cmdline>) and launchSecurity kernelHashes='yes'
#            so kernel/initrd/cmdline are covered by SNP launch measurement
#
# For AL3/AL4, alman can automatically extract vmlinuz+initrd from the VM image into a host cache
# and use those paths during `define`, so you do not have to manually pass --kernel/--initrd.
#
# IMPORTANT:
# - Default loader type is 'rom': pflash seems wonky
# - For AL3/AL4 direct boot, cmdline MUST include a usable root=<some dev> parameter. Default is for AL3 is:
#     "root=/dev/vda2 rw rootwait console=ttyS0,115200n8"
#
# Commands:
#   host-check
#   build-base [--force] [--additional-cmds-file PATH]
#     - default additional cmds file: attestation-level-manager/additional-build.sh
#   build-vm --al N --name vm1 [--size-gb N] [--ssh-pubkey <key>]
#   apply-al --al 3|4 --name vm1
#   set-boot-guard --al 3|4 --name vm1
#   make-verity --al 4 --name vm1
#       returns a roothash, used for define, save as ROOTHASH (env) for convenience
#   define --al N --name vm1 [--mem-mb N] [--vcpus N] [--dryrun]
#       AL3/AL4: [--kernel PATH --initrd PATH] [--cmdline <string>] [--no-auto-boot-artifacts] [--al4-upper-mode disk|tmpfs] [--al4-tmpfs-size 512M|1G|...]
#       sev-snp-measure: [--sev-snp-measure-py PATH] [--cpu-types-json <path>] [--legal-cpu-types-json <path>] [--expected-measurements-json <path>]
#   start --name vm1
#   console --name vm1
#   undefine --name vm1
#
# Examples:
#   sudo ./alman.sh host-check
#   sudo ./alman.sh build-base
#   sudo ./alman.sh build-vm --al 2 --name al2vm
#   sudo ./alman.sh build-vm --al 4 --name al4vm
#   sudo ./alman.sh make-verity --name al4vm
#   sudo ./alman.sh apply-al --al 4 --name al4vm
#   sudo ./alman.sh define --al 4 --name al4vm --cpu-type-key milan
#   sudo ./alman.sh start --name al4vm
#   sudo ./alman.sh console --name al4vm
#   sudo ./alman.sh destroy --name al4vm
#   sudo ./alman.sh undefine --name al4vm

SCRIPT_NAME="$(basename "$0")"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"

# config file
CONFIG_FILE="${SCRIPT_DIR}/alman.conf"

load_config_file() {
  local cfg="$1"
  [[ -n "$cfg" ]] || return 0
  [[ -f "$cfg" ]] || die "Config file not found: $cfg"

  local line key val
  while IFS= read -r line || [[ -n "$line" ]]; do
    # strip leading/trailing whitespace
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"

    # skip blanks/comments
    [[ -z "$line" || "${line:0:1}" == "#" ]] && continue

    # allow "export KEY=VAL" or "KEY=VAL"
    if [[ "$line" =~ ^export[[:space:]]+ ]]; then
      line="${line#export }"
      line="${line#"${line%%[![:space:]]*}"}"
    fi

    # must be KEY=VALUE
    [[ "$line" == *"="* ]] || die "Invalid config line (expected KEY=VALUE): $line"

    key="${line%%=*}"
    val="${line#*=}"

    # trim whitespace around key
    key="${key%"${key##*[![:space:]]}"}"
    key="${key#"${key%%[![:space:]]*}"}"

    # trim whitespace around val
    val="${val#"${val%%[![:space:]]*}"}"
    val="${val%"${val##*[![:space:]]}"}"

    # strip quotes
    if [[ ( "${val:0:1}" == "'" && "${val: -1}" == "'" ) || ( "${val:0:1}" == '"' && "${val: -1}" == '"' ) ]]; then
      val="${val:1:${#val}-2}"
    fi

    case "$key" in
      QEMU_BIN|OVMF_CODE|OVMF_VARS|OVMF_AL2|OVMF_AL34|SEV_SNP_MEASURE_PY)
        printf -v "$key" '%s' "$val"
        ;;
      *)
        die "Unknown/unsupported key in config: $key"
        ;;
    esac
  done < "$cfg"
}


# subscripts directory (python/shell fragments)
HELPERS_DIR="${SCRIPT_DIR}/helpers"
PY_DIR="${HELPERS_DIR}/python"
SHELL_DIR="${HELPERS_DIR}/shell"

die() { echo "ERROR: $*" >&2; exit 1; }
log() { echo "[$SCRIPT_NAME] $*" >&2; }

need_root() { [[ "${EUID}" -eq 0 ]] || die "Run as root."; }
cmd_exists() { command -v "$1" >/dev/null 2>&1; }
require_cmds() {
  local m=()
  for c in "$@"; do cmd_exists "$c" || m+=("$c"); done
  ((${#m[@]}==0)) || die "Missing commands: ${m[*]}"
}

# ---------------- Defaults ----------------
AL_DEFAULT="2"                              # numeric: 0..4 (AL0 = no SNP)
VM_NAME_DEFAULT="sev-snp-ubuntu"
VCPUS_DEFAULT="2"
RAM_MB_DEFAULT="4096"
LIBVIRT_NET_DEFAULT="default"

# Suite defaults
UBUNTU_SUITE_DEFAULT="noble"
UBUNTU_MIRROR_DEFAULT="http://archive.ubuntu.com/ubuntu"

# VM user defaults (used if no ssh key)
DEFAULT_USER="ubuntu"
DEFAULT_PASS="ubuntu"

# Caching
WORKDIR_DEFAULT="${SCRIPT_DIR}/work"
DISK_DIR_DEFAULT="${WORKDIR_DEFAULT}/disks"
CACHE_DIR_DEFAULT="${WORKDIR_DEFAULT}/cache"
XML_DIR_DEFAULT="${WORKDIR_DEFAULT}/xml"
DEBOOTSTRAP_CACHE_DEFAULT="${CACHE_DIR_DEFAULT}/debootstrap"
APT_CACHE_DEFAULT="${CACHE_DIR_DEFAULT}/apt"
CARGO_CACHE_DEFAULT="${CACHE_DIR_DEFAULT}/cargo"
RUSTUP_CACHE_DEFAULT="${CACHE_DIR_DEFAULT}/rustup"
BOOT_ARTIFACTS_CACHE_DEFAULT="${CACHE_DIR_DEFAULT}/boot"   # host-side vmlinuz/initrd cache per VM

# Base image (cached)
BASE_IMG_DEFAULT="${CACHE_DIR_DEFAULT}/base-ubuntu-${UBUNTU_SUITE_DEFAULT}.qcow2"

# loader type, stick with rom for now
LOADER_TYPE_DEFAULT="rom"

# Additional build commands file (next to alman.sh by default)
BUILD_ADDITIONAL_CMDS_DEFAULT="${SCRIPT_DIR}/additional-build.sh"

# Initialized to empty, config loader will set them.
QEMU_BIN=""
OVMF_CODE=""
OVMF_VARS=""
OVMF_AL2=""
OVMF_AL34=""

# AL4 overlay upper behavior:
#   disk  = current behavior: /dev/vdc ext4 holds overlay upper/work (persistent)
#   tmpfs = RAM-only upper/work in initramfs (ephemeral across reboots)
AL4_UPPER_MODE_DEFAULT="tmpfs"   # disk|tmpfs
AL4_TMPFS_SIZE_DEFAULT="1024M"      # e.g. "512M", "1G"

# JSONs are next to alman.sh by default
CPU_TYPES_JSON_DEFAULT="${SCRIPT_DIR}/cpu-types.json"
LEGAL_CPU_TYPES_JSON_DEFAULT="${SCRIPT_DIR}/legal-cpu-types.json"
EXPECTED_MEASUREMENTS_JSON_DEFAULT="${SCRIPT_DIR}/expected-measurements.json"


normalize_al() {
  case "$AL" in
    0|1|2|3|4) : ;;
    *) die "Invalid --al '${AL}'. Use 0|1|2|3|4." ;;
  esac
}

al_ge() { [[ "$AL" -ge "$1" ]]; }

set_image_paths() {
  ROOT_IMG="${DISK_DIR}/${VM_NAME}-root.qcow2"
  HASH_IMG="${DISK_DIR}/${VM_NAME}-hash.img"
  UPPER_IMG="${DISK_DIR}/${VM_NAME}-upper.img"

  # build-time metadata (used to decide whether to attach vdc in domain XML, rambacked vs diskbacked overlayfs)
  UPPER_MODE_FILE="${DISK_DIR}/${VM_NAME}-upper.mode"
}

ensure_dirs() {
  need_root
  mkdir -p \
    "$DISK_DIR" "$CACHE_DIR" "$DEBOOTSTRAP_CACHE" "$APT_CACHE/archives" "$CARGO_CACHE" "$RUSTUP_CACHE" \
    "$BOOT_ARTIFACTS_CACHE"
}

# ---------------- Helpers: disk mounts, nbd etc. ----------------
attach_qcow2() {
  local img="$1"
  require_cmds qemu-nbd modprobe lsblk partprobe
  modprobe nbd max_part=16 >/dev/null 2>&1 || true

  local dev=""
  for d in /dev/nbd{0..15}; do
    [[ -b "$d" ]] || continue

    local bn; bn="$(basename "$d")"

    # If device or any partition is mounted: busy
    if lsblk -n -o MOUNTPOINTS "$d" 2>/dev/null | grep -q .; then
      continue
    fi

    # If device has any holders in sysfs: busy
    if [[ -d "/sys/block/${bn}/holders" ]] && find "/sys/block/${bn}/holders" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null | grep -q .; then
      continue
    fi

    # Try to connect: successful? taking it
    if qemu-nbd --connect "$d" "$img" >/dev/null 2>&1; then
      dev="$d"
      break
    fi

  done

  [[ -n "$dev" ]] || die "No free /dev/nbdX found (0..15) or connect failed."

  partprobe "$dev" >/dev/null 2>&1 || true

  if command -v udevadm >/dev/null 2>&1; then udevadm settle || true; fi
  echo "$dev"
}

detach_qcow2() {
  local dev="$1"
  [[ -b "$dev" ]] || return 0

  # Try to ensure nothing is mounted from this device
  umount "${dev}"p* >/dev/null 2>&1 || true

  qemu-nbd --disconnect "$dev" >/dev/null 2>&1 || true

  # Clear partition table / wait for udev to remove nbdXp* nodes
  partprobe "$dev" >/dev/null 2>&1 || true
  if command -v udevadm >/dev/null 2>&1; then udevadm settle || true; fi
}

mount_rootp() {
  local img="$1" mnt="$2"
  local dev rootp
  dev="$(attach_qcow2 "$img")"
  rootp="${dev}p2"
  for _ in 1 2 3 4 5; do [[ -b "$rootp" ]] && break; sleep 0.2; done
  [[ -b "$rootp" ]] || { detach_qcow2 "$dev"; die "Root partition not found on $img via $dev"; }
  mkdir -p "$mnt"
  mount "$rootp" "$mnt"
  echo "$dev"
}

mount_rootp_ro() {
  local img="$1" mnt="$2"
  local dev rootp
  dev="$(attach_qcow2 "$img")"
  rootp="${dev}p2"
  for _ in 1 2 3 4 5; do [[ -b "$rootp" ]] && break; sleep 0.2; done
  [[ -b "$rootp" ]] || { detach_qcow2 "$dev"; die "Root partition not found on $img via $dev"; }
  mkdir -p "$mnt"
  mount -o ro,noload "$rootp" "$mnt"
  echo "$dev"
}


umount_rootp() {
  local mnt="$1" dev="$2"
  umount "$mnt" >/dev/null 2>&1 || true
  detach_qcow2 "$dev"
}

# ---------------- Boot artifacts extraction (AL3/AL4 direct kernel boot) ----------------
# Extract latest /boot/vmlinuz-* and /boot/initrd.img-* from VM qcow2 into host cache.
# Outputs two lines: KERNEL_PATH and INITRD_PATH.
extract_boot_artifacts() {
  need_root
  require_cmds cp ls sort stat

  [[ -f "$ROOT_IMG" ]] || die "Missing ROOT_IMG: $ROOT_IMG"

  local cache_vm="${BOOT_ARTIFACTS_CACHE}/${VM_NAME}"
  mkdir -p "$cache_vm"

  local mnt="/mnt/${VM_NAME}-bootart"
  local dev=""

  cleanup() {
    [[ -n "$dev" ]] && umount_rootp "$mnt" "$dev"
  }
  trap cleanup EXIT

  dev="$(mount_rootp_ro "$ROOT_IMG" "$mnt")"

  local krel irel
  krel="$(ls -1 "$mnt/boot"/vmlinuz-* 2>/dev/null | sort -V | tail -n 1 || true)"
  irel="$(ls -1 "$mnt/boot"/initrd.img-* 2>/dev/null | sort -V | tail -n 1 || true)"

  [[ -z "$krel" && -e "$mnt/boot/vmlinuz" ]] && krel="$mnt/boot/vmlinuz"
  [[ -z "$irel" && -e "$mnt/boot/initrd.img" ]] && irel="$mnt/boot/initrd.img"

  [[ -n "$krel" && -n "$irel" ]] || die "Could not locate kernel/initrd in image under /boot."

  local kname iname kout iout
  kname="$(basename "$krel")"
  iname="$(basename "$irel")"
  kout="${cache_vm}/${kname}"
  iout="${cache_vm}/${iname}"

  # copy while mounted
  if [[ ! -f "$kout" ]] || [[ "$(stat -c%s "$kout" 2>/dev/null || echo 0)" != "$(stat -c%s "$krel")" ]]; then
    cp -f "$krel" "$kout"
  fi
  if [[ ! -f "$iout" ]] || [[ "$(stat -c%s "$iout" 2>/dev/null || echo 0)" != "$(stat -c%s "$irel")" ]]; then
    cp -f "$irel" "$iout"
  fi

  cleanup
  trap - EXIT

  echo "$kout"
  echo "$iout"
}


# ---------------- host-check ----------------
host_check() {
  need_root
  require_cmds virsh uuidgen awk grep sed sha256sum dd mount umount chroot git \
               qemu-img qemu-nbd parted losetup partprobe mkfs.vfat mkfs.ext4 debootstrap blkid rsync \
               curl pkg-config

  [[ -x "$QEMU_BIN" ]] || die "QEMU binary not found/executable: $QEMU_BIN"
  [[ -f "$OVMF_CODE" ]] || die "OVMF code not found: $OVMF_CODE"
  [[ -f "$OVMF_VARS" ]] || die "OVMF vars not found: $OVMF_VARS"

  if [[ "$AL" -eq 4 ]]; then
    require_cmds veritysetup
  fi

  log "Host-check OK:"
  log "  AL=$AL"
  log "  Suite=$UBUNTU_SUITE"
  log "  QEMU_BIN=$QEMU_BIN"
  log "  OVMF_CODE=$OVMF_CODE"
  log "  OVMF_VARS=$OVMF_VARS"
}

# ---------------- Build base image (cached) ----------------
build_base() {
  need_root
  parse_common_args "$@"
  ensure_dirs
  require_cmds qemu-img debootstrap chroot mount umount curl

  local force="0"
  local additional_cmds_file="${BUILD_ADDITIONAL_CMDS_DEFAULT}"

  # Parse build-base specific args
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --force) force="1"; shift;;
      --additional-cmds-file)
        [[ -n $2  ]] || die "--additional-cmds-file requires a path"
        additional_cmds_file="$2"; shift 2;;
      *) shift;;
    esac
  done

  if [[ -f "$BASE_IMG" && "$force" != "1" ]]; then
    log "Base image already exists: $BASE_IMG"
    return 0
  fi

  require_cmds truncate parted losetup partprobe mkfs.vfat mkfs.ext4 debootstrap mount umount chroot blkid rsync qemu-img curl

  local raw_tmp="${CACHE_DIR}/.base-${UBUNTU_SUITE}.raw"
  local size_gb="12"

  log "Building base (suite=${UBUNTU_SUITE}) as raw then converting to qcow2..."
  rm -f "$raw_tmp" "$BASE_IMG"
  truncate -s "${size_gb}G" "$raw_tmp"

  parted -s "$raw_tmp" mklabel gpt
  parted -s "$raw_tmp" mkpart ESP fat32 1MiB 513MiB
  parted -s "$raw_tmp" set 1 esp on
  parted -s "$raw_tmp" mkpart root ext4 513MiB 100%

  local loopdev esp rootp
  loopdev="$(losetup -Pf --show "$raw_tmp")"
  if command -v udevadm >/dev/null 2>&1; then udevadm settle || true; fi
  partprobe "$loopdev" || true

  esp="${loopdev}p1"
  rootp="${loopdev}p2"
  for _ in 1 2 3 4 5; do [[ -b "$esp" && -b "$rootp" ]] && break; sleep 0.2; done
  [[ -b "$esp" && -b "$rootp" ]] || {
    lsblk "$loopdev" || true
    losetup -d "$loopdev" || true
    die "Loop partitions not created correctly for base build."
  }

  mkfs.vfat -F 32 -n ESP "$esp" >/dev/null
  mkfs.ext4 -F -L "root" "$rootp" >/dev/null

  local mnt="/mnt/alman-base-${UBUNTU_SUITE}"
  mkdir -p "$mnt"
  mount "$rootp" "$mnt"
  mkdir -p "$mnt/boot/efi"
  mount "$esp" "$mnt/boot/efi"

  debootstrap --arch=amd64 --cache-dir="$DEBOOTSTRAP_CACHE" "$UBUNTU_SUITE" "$mnt" "$UBUNTU_MIRROR"

  local root_uuid esp_uuid
  root_uuid="$(blkid -s UUID -o value "$rootp")"
  esp_uuid="$(blkid -s UUID -o value "$esp")"
  cat >"$mnt/etc/fstab" <<EOF
UUID=${root_uuid}  /         ext4  defaults  0 1
UUID=${esp_uuid}   /boot/efi vfat  umask=0077  0 1
EOF

  echo "alman-base-${UBUNTU_SUITE}" >"$mnt/etc/hostname"
  cat >"$mnt/etc/hosts" <<EOF
127.0.0.1 localhost
127.0.1.1 alman-base-${UBUNTU_SUITE}
EOF

  mkdir -p "$mnt/etc/netplan"
  cat >"$mnt/etc/netplan/01-netcfg.yaml" <<EOF
network:
 version: 2
 renderer: networkd
 ethernets:
  net0:
   match:
    driver: virtio_net
   set-name: eth0
   dhcp4: true
   dhcp-identifier: mac
EOF

  mount -t proc none "$mnt/proc"
  mount -t sysfs none "$mnt/sys"
  mount -o bind /dev "$mnt/dev"
  mount -o bind /run "$mnt/run" || true

  mkdir -p "$mnt/var/cache/apt/archives" "$mnt/root/.cargo" "$mnt/root/.rustup"
  mount --bind "$APT_CACHE/archives" "$mnt/var/cache/apt/archives"
  mount --bind "$CARGO_CACHE" "$mnt/root/.cargo"
  mount --bind "$RUSTUP_CACHE" "$mnt/root/.rustup"

  # If additonal commands file exists, copy into chroot and execute it.
  local additional_chroot="/root/alman-additional-build.sh"
  local run_additional="0"
  if [[ -n "$additional_cmds_file" && -f "$additional_cmds_file" ]]; then
    cp -f "$additional_cmds_file" "$mnt${additional_chroot}"
    chmod 0700 "$mnt${additional_chroot}"
    run_additional="1"
    log "Will run additional build commands inside chroot: ${additional_cmds_file}"
  else
    if [[ "$additional_cmds_file" != "${BUILD_ADDITIONAL_CMDS_DEFAULT}" ]]; then
      die "Additional build commands file not found: ${additional_cmds_file}"
    fi
    log "No additional build commands file found at default path (${BUILD_ADDITIONAL_CMDS_DEFAULT}); continuing."
  fi

  chroot "$mnt" /bin/bash -lc "
    set -euo pipefail
    export DEBIAN_FRONTEND=noninteractive
    export HOME=/root

    apt-get update
    apt-get install -y --no-install-recommends \
      linux-image-generic initramfs-tools linux-modules-extra-6.8.0-31-generic \
      grub-efi-amd64 efibootmgr \
      netplan.io  \
      systemd-sysv \
      openssh-server sudo \
      ca-certificates curl git \
      vim nano \
      build-essential pkg-config libssl-dev \
      cryptsetup-bin \

    # Serial console via GRUB (applies to AL2 disk boot)
    sed -i 's/^GRUB_CMDLINE_LINUX=.*/GRUB_CMDLINE_LINUX=\"console=ttyS0,115200n8\"/' /etc/default/grub || true
    update-grub

    grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=ubuntu --recheck
    update-grub
    systemctl enable ssh

    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal --default-toolchain stable
    . \"\$HOME/.cargo/env\"

    rm -rf /opt/snpguest
    git clone https://github.com/virtee/snpguest /opt/snpguest
    cd /opt/snpguest
    cargo build -r
    install -m 0755 target/release/snpguest /usr/local/bin/snpguest

    # enable networking
    systemctl enable systemd-networkd
    systemctl enable systemd-resolved
    ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf

    # Enable MSR access for snpguest by loading msr module at boot
    echo "msr" > /etc/modules-load.d/msr.conf

    if [[ \"${run_additional}\" == \"1\" ]]; then
      echo \"[alman] Running additional build commands: ${additional_chroot}\"
      /bin/bash -lc \"${additional_chroot}\"
      rm -f \"${additional_chroot}\" || true
    fi
  "

  umount "$mnt/var/cache/apt/archives" || true
  umount "$mnt/root/.cargo" || true
  umount "$mnt/root/.rustup" || true

  umount "$mnt/proc" || true
  umount "$mnt/sys" || true
  umount "$mnt/dev" || true
  umount "$mnt/run" || true

  umount "$mnt/boot/efi"
  umount "$mnt"
  losetup -d "$loopdev"

  qemu-img convert -f raw -O qcow2 "$raw_tmp" "$BASE_IMG"
  rm -f "$raw_tmp"

  log "Base built and cached: $BASE_IMG"
}

# ---------------- Build VM (fast clone from base) ----------------
build_vm() {
  need_root
  parse_common_args "$@"
  set_image_paths
  ensure_dirs
  require_cmds qemu-img mount umount chroot

  local size_gb="12"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --size-gb) size_gb="$2"; shift 2;;
      *) shift;;
    esac
  done

  [[ -f "$BASE_IMG" ]] || die "Base image missing: $BASE_IMG. Run: sudo ${SCRIPT_NAME} build-base"

  mkdir -p "$DISK_DIR"
  rm -f "$ROOT_IMG"

  qemu-img create -f qcow2 -F qcow2 -b "$BASE_IMG" "$ROOT_IMG" >/dev/null
  if [[ "$size_gb" != "12" ]]; then
    qemu-img resize "$ROOT_IMG" "${size_gb}G" >/dev/null
  fi

  local mnt="/mnt/${VM_NAME}-rootfs"
  local dev

  cleanup() {
    [[ -n "$dev" ]] && umount_rootp "$mnt" "$dev"
  }

  trap cleanup EXIT

  dev="$(mount_rootp "$ROOT_IMG" "$mnt")"

  echo "$VM_NAME" >"$mnt/etc/hostname"
  cat >"$mnt/etc/hosts" <<EOF
127.0.0.1 localhost
127.0.1.1 ${VM_NAME}
EOF

  local ssh_key_payload=""
  if [[ -n "$SSH_PUBKEY" ]]; then
    [[ -f "$SSH_PUBKEY" ]] || { umount_rootp "$mnt" "$dev"; die "--ssh-pubkey file not found: $SSH_PUBKEY"; }
    ssh_key_payload="$(cat "$SSH_PUBKEY")"
  fi

  mount -t proc none "$mnt/proc"
  mount -t sysfs none "$mnt/sys"
  mount -o bind /dev "$mnt/dev"
  mount -o bind /run "$mnt/run" || true

  chroot "$mnt" /bin/bash -lc "
    set -euo pipefail
    export DEBIAN_FRONTEND=noninteractive

    id -u ${DEFAULT_USER} >/dev/null 2>&1 || useradd -m -s /bin/bash ${DEFAULT_USER}
    usermod -aG sudo ${DEFAULT_USER}

    if [ -n \"${ssh_key_payload}\" ]; then
      mkdir -p /home/${DEFAULT_USER}/.ssh
      echo \"${ssh_key_payload}\" > /home/${DEFAULT_USER}/.ssh/authorized_keys
      chown -R ${DEFAULT_USER}:${DEFAULT_USER} /home/${DEFAULT_USER}/.ssh
      chmod 700 /home/${DEFAULT_USER}/.ssh
      chmod 600 /home/${DEFAULT_USER}/.ssh/authorized_keys
      passwd -l ${DEFAULT_USER} || true
    else
      echo '${DEFAULT_USER}:${DEFAULT_PASS}' | chpasswd
    fi
  "

  umount "$mnt/proc" || true
  umount "$mnt/sys" || true
  umount "$mnt/dev" || true
  umount "$mnt/run" || true
  umount_rootp "$mnt" "$dev"

  cleanup
  trap - EXIT

  if [[ "$AL" -eq 4 ]]; then
    require_cmds truncate mkfs.ext4
    rm -f "$HASH_IMG" "$UPPER_IMG"
    truncate -s "512M" "$HASH_IMG"
    truncate -s "4G" "$UPPER_IMG"
    mkfs.ext4 -F -L "${VM_NAME}-upper" "$UPPER_IMG" >/dev/null
  else
    rm -f "$HASH_IMG" "$UPPER_IMG" 2>/dev/null || true
  fi

  log "VM root disk created: $ROOT_IMG"
  [[ "$AL" -eq 4 ]] && log "AL4 disks: HASH_IMG=$HASH_IMG, UPPER_IMG=$UPPER_IMG"
  [[ -z "$SSH_PUBKEY" ]] && log "WARNING: no --ssh-pubkey provided; user '${DEFAULT_USER}' password '${DEFAULT_PASS}'."
}

# ---------------- emiters read from helper scripts (AL3/AL4 policy check; embedded config) ----------------
emit_initramfs_hook_copy_conf() {
  cat "${SHELL_DIR}/emit_initramfs_hook_copy_conf.sh"
}

emit_al3_check_script() {
  cat "${SHELL_DIR}/emit_al3_check_script.sh"
}

emit_initramfs_modules_al4() {
  cat "${SHELL_DIR}/emit_initramfs_modules_al4.txt"
}

emit_initramfs_hook_include_veritysetup() {
  cat "${SHELL_DIR}/emit_initramfs_hook_include_veritysetup.sh"
}

emit_al4_verity_open_script() {
  cat "${SHELL_DIR}/emit_al4_verity_open_script.sh"
}

emit_al4_overlay_premount_script() {
  cat "${SHELL_DIR}/emit_al4_overlay_premount_script.sh"
}

inject_initramfs_artifacts() {
  # Args: mnt al
  local mnt="$1"; shift
  local al="$1"; shift

  mkdir -p "$mnt/etc/initramfs-tools/hooks" \
           "$mnt/usr/share/initramfs-tools/scripts/init-premount" \
           "$mnt/usr/share/initramfs-tools/scripts/local-top" \
           "$mnt/usr/share/initramfs-tools/scripts/local-premount" \
           "$mnt/usr/share/initramfs-tools/scripts/local-bottom"

  emit_initramfs_hook_copy_conf >"$mnt/etc/initramfs-tools/hooks/alman_boot_guard_conf"
  chmod +x "$mnt/etc/initramfs-tools/hooks/alman_boot_guard_conf"

  if [[ "$al" -ge 3 ]]; then
    emit_al3_check_script >"$mnt/usr/share/initramfs-tools/scripts/init-premount/alman_al3_kernel_hash_gate"
    chmod +x "$mnt/usr/share/initramfs-tools/scripts/init-premount/alman_al3_kernel_hash_gate"
  fi

  if [[ "$al" -ge 4 ]]; then
    # Remove legacy/duplicate AL4 initramfs scripts in case there is some caching issue
    rm -f \
      "$mnt/usr/share/initramfs-tools/scripts/local-top/alman_al4_verity_overlay" \
      "$mnt/usr/share/initramfs-tools/scripts/local-top/alman_al4_verity_open" \
      "$mnt/usr/share/initramfs-tools/scripts/local-premount/alman_al4_overlay" \
      "$mnt/usr/share/initramfs-tools/scripts/local-bottom/alman_al4_overlay"

    # split open and premount
    emit_al4_verity_open_script >"$mnt/usr/share/initramfs-tools/scripts/local-top/alman_al4_verity_open"
    chmod +x "$mnt/usr/share/initramfs-tools/scripts/local-top/alman_al4_verity_open"

    emit_al4_overlay_premount_script >"$mnt/usr/share/initramfs-tools/scripts/local-bottom/alman_al4_overlay"
    chmod +x "$mnt/usr/share/initramfs-tools/scripts/local-bottom/alman_al4_overlay"

    # ensure veritysetup (and libs) are in initramfs
    emit_initramfs_hook_include_veritysetup >"$mnt/etc/initramfs-tools/hooks/alman_include_veritysetup"
    chmod +x "$mnt/etc/initramfs-tools/hooks/alman_include_veritysetup"

    # ensure required kernel modules are included in initramfs
    mkdir -p "$mnt/etc/initramfs-tools"
    touch "$mnt/etc/initramfs-tools/modules"
    while read -r mod; do
      [[ -z "$mod" || "$mod" =~ ^# ]] && continue
      grep -qxF "$mod" "$mnt/etc/initramfs-tools/modules" || echo "$mod" >>"$mnt/etc/initramfs-tools/modules"
    done < <(emit_initramfs_modules_al4)
  fi
}

apply_al() {
  need_root
  parse_common_args "$@"
  set_image_paths
  al_ge 3 || die "apply-al requires --al 3 or 4."

  require_cmds python3 qemu-nbd lsblk partprobe mount umount chroot

  [[ -f "$ROOT_IMG" ]] || die "Missing ROOT_IMG: $ROOT_IMG"

  local dev=""

  cleanup() {
    [[ -n "$dev" ]] && umount_rootp "$mnt" "$dev"
  }

  local mnt="/mnt/${VM_NAME}-al"


  local al4_upper_mode="${AL4_UPPER_MODE}"
  local al4_tmpfs_size="${AL4_TMPFS_SIZE}"

  if [[ "$AL" -eq 4 ]]; then
    case "$al4_upper_mode" in
      disk|tmpfs) : ;;
      *) die "apply-al --al 4: --al4-upper-mode must be disk|tmpfs (got: $al4_upper_mode)";;
    esac
  fi

  trap cleanup EXIT

  dev="$(mount_rootp "$ROOT_IMG" "$mnt")"

  mkdir -p "$mnt/etc/alman"

  # boot guard config (placeholder)
  cat >"$mnt/etc/alman/boot-guard.conf" <<EOF
# alman boot guard config (embedded into initramfs)
EXPECTED_KERNEL_SHA256=""
EXPECTED_INITRD_SHA256=""
ROOT_PART="/dev/vda2"
HASH_DEV="/dev/vdb"
UPPER_DEV="/dev/vdc"

# AL4 overlay upper mode:
#   disk: mount UPPER_DEV as ext4 and use it as overlay upper/work (persistent)
#   tmpfs: use RAM-only tmpfs upper/work (ephemeral across reboots)
AL4_UPPER_MODE="${al4_upper_mode}"
AL4_TMPFS_SIZE="${al4_tmpfs_size}"
EOF

  # Inject initramfs scripts
  inject_initramfs_artifacts "$mnt" "$AL"

  # update initramfs
  mount -t proc none "$mnt/proc"
  mount -t sysfs none "$mnt/sys"
  mount -o bind /dev "$mnt/dev"

  log "Updating initramfs inside guest..."

  chroot "$mnt" /bin/bash -lc "SOURCE_DATE_EPOCH=1234 && update-initramfs -u"
  umount "$mnt/proc" || true
  umount "$mnt/sys" || true
  umount "$mnt/dev" || true
  umount_rootp "$mnt" "$dev"

  cleanup
  trap - EXIT

  if [[ "$AL" -eq 4 ]]; then
    echo "${al4_upper_mode}" > "${UPPER_MODE_FILE}"
  else
    rm -f "${UPPER_MODE_FILE}" 2>/dev/null || true
  fi

  log "apply-al done for ${VM_NAME} (AL${AL})."

}

set_boot_guard() {
  need_root
  parse_common_args "$@"
  set_image_paths
  al_ge 3 || die "set-boot-guard requires --al 3 or 4."

  [[ -f "$ROOT_IMG" ]] || die "Missing ROOT_IMG: $ROOT_IMG"

  require_cmds qemu-nbd lsblk partprobe mount umount sha256sum

  local expected_kernel=""
  local expected_initrd=""
  local roothash=""
  local root_part="/dev/vda2"
  local hash_dev="/dev/vdb"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --expected-kernel-sha256) expected_kernel="$2"; shift 2;;
      --expected-initrd-sha256) expected_initrd="$2"; shift 2;;
      --roothash) roothash="$2"; shift 2;;
      --root-part) root_part="$2"; shift 2;;
      --hash-dev) hash_dev="$2"; shift 2;;
      --upper-dev) upper_dev="$2"; shift 2;;
      *) shift;;
    esac
  done

  roothash="$(echo "$roothash" | tr -d '[:space:]')"

  local mnt="/mnt/${VM_NAME}-cfg"
  local dev

  cleanup() {
    [[ -n "$dev" ]] && umount_rootp "$mnt" "$dev"
  }

  trap cleanup EXIT

  dev="$(mount_rootp "$ROOT_IMG" "$mnt")"

  mkdir -p "$mnt/etc/alman"
  cat >"$mnt/etc/alman/boot-guard.conf" <<EOF
# Generated by alman set-boot-guard
EXPECTED_KERNEL_SHA256="${expected_kernel}"
EXPECTED_INITRD_SHA256="${expected_initrd}"
ROOT_PART="${root_part}"
HASH_DEV="${hash_dev}"
EOF

  mount -t proc none "$mnt/proc"
  mount -t sysfs none "$mnt/sys"
  mount -o bind /dev "$mnt/dev"
  chroot "$mnt" /bin/bash -lc "update-initramfs -u"
  umount "$mnt/proc" || true
  umount "$mnt/sys" || true
  umount "$mnt/dev" || true
  umount_rootp "$mnt" "$dev"

  cleanup
  trap - EXIT

  log "Updated /etc/alman/boot-guard.conf and rebuilt initramfs (AL${AL})."
}

# ---------------- dm-verity (AL4 only) ----------------
make_verity() {
  need_root
  parse_common_args "$@"
  set_image_paths
  [[ "$AL" -eq 4 ]] || die "make-verity is only valid for --al 4."
  [[ -f "$ROOT_IMG" ]] || die "Missing ROOT_IMG: $ROOT_IMG"
  [[ -f "$HASH_IMG" ]] || die "Missing HASH_IMG: $HASH_IMG (build-vm --al 4 creates it)."

  require_cmds veritysetup qemu-nbd lsblk partprobe mount umount awk

  local dev rootp out roothash
  dev=""

  cleanup() {
    if [[ -n "$dev" ]]; then
      qemu-nbd --disconnect "$dev" >/dev/null 2>&1 || true
    fi
  }
  trap cleanup EXIT

  dev="$(attach_qcow2 "$ROOT_IMG")"
  rootp="${dev}p2"
  for _ in 1 2 3 4 5; do [[ -b "$rootp" ]] && break; sleep 0.2; done
  [[ -b "$rootp" ]] || { detach_qcow2 "$dev"; die "Root partition not found for verity format."; }

  # Fixed salt for now as dynamically changing salt proves to be a headache for now
  out="$(veritysetup format --salt=0000000000000000000000000000000000000000000000000000000000000000 "$rootp" "$HASH_IMG" 2>&1)" || {
    detach_qcow2 "$dev"
    echo "$out" >&2
    die "veritysetup format failed (HASH_IMG too small?)"
  }

  roothash="$(printf "%s\n" "$out" | awk '/Root hash:/ {
    if (match($0, /[0-9a-fA-F]{64}/)) {
      print substr($0, RSTART, RLENGTH); exit
    }
  }')"

  if ! [[ "$roothash" =~ ^[0-9a-fA-F]{64}$ ]]; then
    die "Parsed ROOTHASH is not 64 hex chars: '$roothash'"
  fi
  [[ -n "$roothash" ]] || { detach_qcow2 "$dev"; die "Could not parse roothash."; }

  detach_qcow2 "$dev"
  cleanup
  trap - EXIT

  cat >"${DISK_DIR}/${VM_NAME}-verity.meta" <<EOF
VM_NAME=${VM_NAME}
ROOT_IMG=${ROOT_IMG}
HASH_IMG=${HASH_IMG}
UPPER_IMG=${UPPER_IMG}
ROOTHASH=${roothash}
EOF

  echo "$roothash"
}

# ---------------- sev-snp-measure integration ----------------
resolve_sev_snp_measure_py() {
  if [[ -n "${SEV_SNP_MEASURE_PY}" ]]; then
    [[ -f "${SEV_SNP_MEASURE_PY}" ]] || die "SEV_SNP_MEASURE_PY not executable: ${SEV_SNP_MEASURE_PY}"
    echo "${SEV_SNP_MEASURE_PY}"
    return 0
  fi
  if command -v sev-snp-measure.py >/dev/null 2>&1; then
    command -v sev-snp-measure.py
    return 0
  fi
  die "sev-snp-measure.py not found. Set SEV_SNP_MEASURE_PY=/path/to/sev-snp-measure.py in config (or use --sev-snp-measure-py)."
}

calc_expected_snp_measurements() {
  # Args:
  #   $1 al
  #   $2 vm_title
  #   $3 ovmf_path
  #   $4 kernel_path   (only used for AL3/AL4)
  #   $5 initrd_path   (only used for AL3/AL4)
  #   $6 append/cmdline (only used for AL3/AL4)
  #   $7 vcpus

  local al="$1" vm_title="$2" ovmf_path="$3" kernel_path="$4" initrd_path="$5" append="$6" vcpus="$7"

  require_cmds python3

  [[ -d "${PY_DIR}" ]] || die "Missing subscripts directory: ${PY_DIR}"
  [[ -f "${PY_DIR}/expected_measurements.py" ]] || die "Missing expected_measurements.py: ${PY_DIR}/expected_measurements.py"
  [[ -f "${PY_DIR}/validate_cpu_types.py" ]] || die "Missing validate_cpu_types.py: ${PY_DIR}/validate_cpu_types.py"

  [[ -f "${CPU_TYPES_JSON}" ]] || die "cpu-types.json not found: ${CPU_TYPES_JSON}"
  [[ -f "${LEGAL_CPU_TYPES_JSON}" ]] || die "legal-cpu-types.json not found: ${LEGAL_CPU_TYPES_JSON}"

  # Validate CPU types config:
  #     string entries must be present in legal-cpu-types.json
  #     family/model/stepping and vcpu-sig entries are checked for form, but are passed through without explicit legality checks
  python3 "${PY_DIR}/validate_cpu_types.py" \
    --cpu-types "${CPU_TYPES_JSON}" \
    --legal-cpu-types "${LEGAL_CPU_TYPES_JSON}" \
    >/dev/null

  local measure_py; measure_py="$(resolve_sev_snp_measure_py)"

  # expected_measurements.py prints computed measurements as:
  #   <cpu_spec>  <measurement_hex>
  python3 "${PY_DIR}/expected_measurements.py" \
    --out-json "${EXPECTED_MEASUREMENTS_JSON}" \
    --al "${al}" \
    --vm-title "${vm_title}" \
    --ovmf "${ovmf_path}" \
    --kernel "${kernel_path}" \
    --initrd "${initrd_path}" \
    --append "${append}" \
    --vcpus "${vcpus}" \
    --types-path "${CPU_TYPES_JSON}" \
    --measure-py "${measure_py}"
}

# ---------------- Define domain (AL split + auto-extract kernel/initrd for AL3/AL4) ----------------
define_domain() {
  need_root
  parse_common_args "$@"
  set_image_paths
  ensure_dirs
  require_cmds virsh uuidgen awk

  [[ -x "$QEMU_BIN" ]] || die "QEMU binary not found/executable: $QEMU_BIN"
  [[ -f "$ROOT_IMG" ]] || die "Missing ROOT_IMG: $ROOT_IMG"

  local VCPUS="${VCPUS_DEFAULT}"
  local RAM_MB="${RAM_MB_DEFAULT}"
  local LIBVIRT_NET="${LIBVIRT_NET_DEFAULT}"

  local dryrun="0"
  local cbitpos="${SEV_CBITPOS:-51}"
  local reduced_phys_bits="${SEV_REDUCED_PHYS_BITS:-1}"
  local policy="${SEV_POLICY:-0x00030000}"

  local loader_type="${LOADER_TYPE_DEFAULT}"   # default rom avoids pflash/kvm readonly memslot support dependency!
  local ovmf_vars_dest="/var/lib/libvirt/qemu/nvram/${VM_NAME}_VARS.fd"
  local ovmf_al2="$OVMF_AL2"
  local ovmf_al34="$OVMF_AL34"

  # Direct boot params (AL3/AL4)
  local kernel_path=""
  local initrd_path=""
  local cmdline=""
  if [[ "$AL" -eq 4 ]];then
    cmdline="root=/dev/mapper/vroot ro rootwait rootfstype=ext4 console=ttyS0,115200n8 fsck.mode=skip"
  else
    cmdline="root=/dev/vda2 rw rootwait console=ttyS0,115200n8"
  fi
  local auto_boot_artifacts="1"
  local al4_upper_mode="${AL4_UPPER_MODE}"   # disk|tmpfs (for domain device wiring only)
  local al4_tmpfs_size="${AL4_TMPFS_SIZE}"


  # sev-snp-measure options
  local cpu_type_key=""
  local cpu_types_json="${CPU_TYPES_JSON_DEFAULT}"
  local expected_meas_json="${EXPECTED_MEASUREMENTS_JSON_DEFAULT}"
  LEGAL_CPU_TYPES_JSON=${LEGAL_CPU_TYPES_JSON_DEFAULT}


  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dryrun) dryrun="1"; shift;;
      --cbitpos) cbitpos="$2"; shift 2;;
      --reduced-phys-bits) reduced_phys_bits="$2"; shift 2;;
      --policy) policy="$2"; shift 2;;

      --loader-type) loader_type="$2"; shift 2;;
      --ovmf-vars-dest) ovmf_vars_dest="$2"; shift 2;;
      --ovmf-al2) ovmf_al2="$2"; shift 2;;
      --ovmf-al34) ovmf_al34="$2"; shift 2;;

      --kernel) kernel_path="$2"; shift 2;;
      --initrd) initrd_path="$2"; shift 2;;
      --cmdline) cmdline="$2"; shift 2;;
      --no-auto-boot-artifacts) auto_boot_artifacts="0"; shift;;

      --vcpus) VCPUS="$2"; shift 2;;
      --ram-mb) RAM_MB="$2"; shift 2;;
      --net) LIBVIRT_NET="$2"; shift 2;;

      # sev-snp-measure
      --cpu-types-json) CPU_TYPES_JSON="$2"; shift 2 ;;
      --legal-cpu-types-json) LEGAL_CPU_TYPES_JSON="$2"; shift 2 ;;
      --expected-measurements-json) EXPECTED_MEASUREMENTS_JSON="$2"; shift 2 ;;
      --sev-snp-measure-py) SEV_SNP_MEASURE_PY="$2"; shift 2 ;;
      *) shift;;
    esac
  done

  CPU_TYPES_JSON="${cpu_types_json}"
  EXPECTED_MEASUREMENTS_JSON="${expected_meas_json}"

  case "$loader_type" in
    rom|pflash) : ;;
    *) die "Invalid --loader-type '$loader_type' (use rom|pflash)";;
  esac

  # Firmware selection
  local fw_path="$OVMF_CODE"
  if [[ "$AL" -le 2 ]]; then
    [[ -n "$ovmf_al2" ]] && fw_path="$ovmf_al2"
  else
    [[ -n "$ovmf_al34" ]] && fw_path="$ovmf_al34"
  fi
  [[ -f "$fw_path" ]] || die "Firmware not found: $fw_path (set --ovmf-code/--ovmf-al2/--ovmf-al34)"

  # pflash uses vars
  if [[ "$loader_type" == "pflash" ]]; then
    [[ -f "$OVMF_VARS" ]] || die "OVMF vars template not found: $OVMF_VARS (required for --loader-type pflash)"
    mkdir -p "$(dirname "$ovmf_vars_dest")"
    cp -f "$OVMF_VARS" "$ovmf_vars_dest"
  fi

  # AL3/AL4: require direct boot artifacts; auto-extract if not provided
  if [[ "$AL" -ge 3 ]]; then
    if [[ -z "$kernel_path" || -z "$initrd_path" ]]; then
      if [[ "$auto_boot_artifacts" == "1" ]]; then
        log "AL${AL}: auto-extracting vmlinuz/initrd from image into host cache..."
        mapfile -t paths < <(extract_boot_artifacts)
        (( ${#paths[@]} >= 2 )) || die "Boot artifact extraction returned ${#paths[@]} lines (expected 2)."
        kernel_path="${paths[0]}"
        initrd_path="${paths[1]}"
      else
        die "AL3/AL4 require --kernel and --initrd (or omit --no-auto-boot-artifacts to enable auto extraction)."
      fi
    fi
    [[ -f "$kernel_path" ]] || die "--kernel not found: $kernel_path"
    [[ -f "$initrd_path" ]] || die "--initrd not found: $initrd_path"

    # Ensure cmdline has a root= parameter; fail early if missing.
    if ! grep -qE '(^|[[:space:]])root=' <<<"$cmdline"; then
      die "AL3/AL4 cmdline must include root=... (current: '$cmdline')."
    fi
  fi

  # AL4: pass roothash as cmdline parameter
  if [[ "$AL" -eq 4 ]]; then
    local meta="${DISK_DIR}/${VM_NAME}-verity.meta"
    [[ -f "$meta" ]] || die "Missing verity meta: $meta (run make-verity first)"
    local roothash
    roothash="$(awk -F= '/^ROOTHASH=/ {print $2}' "$meta" | tr -cd '0-9a-fA-F')"
    [[ "$roothash" =~ ^[0-9a-fA-F]{64}$ ]] || die "Invalid ROOTHASH in meta: '$roothash'"
    cmdline="${cmdline} alman_roothash=${roothash}"
  fi

  local uuid; uuid="$(uuidgen)"
  local xml="/tmp/${VM_NAME}.xml"

  cat >"$xml" <<EOF
<domain type='kvm'>
  <name>${VM_NAME}</name>
  <uuid>${uuid}</uuid>

  <memory unit='MiB'>${RAM_MB}</memory>
  <currentMemory unit='MiB'>${RAM_MB}</currentMemory>
  <vcpu placement='static'>${VCPUS}</vcpu>
EOF

  if [[ "$AL" -ge 3 ]]; then
    # neccessary for SNP, does not interfere with AL0
    cat >>"$xml" <<EOF
  <memoryBacking>
    <source type='memfd'/>
    <access mode='shared'/>
  </memoryBacking>
EOF
  fi

  cat >>"$xml" <<EOF
  <os>
    <type arch='x86_64' machine='q35'>hvm</type>
EOF

  if [[ "$loader_type" == "rom" ]]; then
    cat >>"$xml" <<EOF
    <loader type='rom'>${fw_path}</loader>
EOF
  else
    cat >>"$xml" <<EOF
    <loader readonly='yes' type='pflash'>${fw_path}</loader>
    <nvram>${ovmf_vars_dest}</nvram>
EOF
  fi

  if [[ "$AL" -ge 3 ]]; then
    cat >>"$xml" <<EOF
    <kernel>${kernel_path}</kernel>
    <initrd>${initrd_path}</initrd>
    <cmdline>${cmdline}</cmdline>
EOF
  fi

  cat >>"$xml" <<EOF
  </os>

  <features>
    <acpi/>
    <apic/>
  </features>

  <cpu mode='host-passthrough' check='none'/>
EOF

  if [[ "$AL" -eq 0 ]]; then
   : # AL0: no SNP, no launchSecurity element at all
  elif [[ "$AL" -ge 3 ]]; then
    # AL3/AL4: SNP enabled, kernel hashing enabled
    cat >>"$xml" <<EOF
  <launchSecurity type='sev-snp' kernelHashes='yes'>
    <cbitpos>${cbitpos}</cbitpos>
    <reducedPhysBits>${reduced_phys_bits}</reducedPhysBits>
    <policy>${policy}</policy>
  </launchSecurity>
EOF
  else
  # AL1/AL2: SNP enabled but no kernelHashes measurement
    cat >>"$xml" <<EOF
  <launchSecurity type='sev-snp'>
    <cbitpos>${cbitpos}</cbitpos>
    <reducedPhysBits>${reduced_phys_bits}</reducedPhysBits>
    <policy>${policy}</policy>
  </launchSecurity>
EOF
  fi

  cat >>"$xml" <<EOF
  <devices>
    <emulator>${QEMU_BIN}</emulator>

    <disk type='file' device='disk'>
      <driver name='qemu' type='qcow2'/>
      <source file='${ROOT_IMG}'/>
      <target dev='vda' bus='virtio'/>
    </disk>
EOF

  if [[ "$AL" -eq 4 ]]; then
    [[ -f "$HASH_IMG" ]] || die "AL4 missing HASH_IMG: $HASH_IMG"

    # Always attach hash device (vdb)
    cat >>"$xml" <<EOF
    <disk type='file' device='disk'>
      <driver name='qemu' type='raw' cache='none' io='threads'/>
      <source file='${HASH_IMG}'/>
      <target dev='vdb' bus='virtio'/>
    </disk>
EOF

    # Attach vdc only if upper mode is disk-backed
    if [[ "$al4_upper_mode" == "disk" ]]; then
      [[ -f "$UPPER_IMG" ]] || die "AL4 missing UPPER_IMG: $UPPER_IMG"
      cat >>"$xml" <<EOF
    <disk type='file' device='disk'>
      <driver name='qemu' type='raw' cache='none' io='threads'/>
      <source file='${UPPER_IMG}'/>
      <target dev='vdc' bus='virtio'/>
    </disk>
EOF
    else
      log "AL4 upper mode tmpfs: not attaching vdc."
    fi
  fi

  cat >>"$xml" <<EOF
    <interface type='network'>
      <source network='${LIBVIRT_NET}'/>
      <model type='virtio'/>
    </interface>

    <serial type='pty'>
      <target type='isa-serial' port='0'/>
    </serial>

    <console type='pty'>
      <target type='serial' port='0'/>
    </console>

    <video>
      <model type='none'/>
    </video>
    <audio id='1' type='none'/>
  </devices>
</domain>
EOF

  if [[ "$dryrun" -eq 1 ]]; then
    cp -a "$xml" "$XML_DIR/$VM_NAME.xml"
    cat "$xml"
    log "Dry-run: XML written to $XML_DIR/$VM_NAME.xml (not defining domain)."
    return 0
  fi

  # calculate expected SNP measurements (AL2/AL3/AL4 only; AL0/AL1: no measurement by definition)
  if [[ "$AL" -ge 2 ]]; then
    if [[ "$AL" -eq 2 ]]; then
      log "Computing expected SEV-SNP measurement for AL2 via sev-snp-measure.py (ovmf-only)..."
    else
      log "Computing expected SEV-SNP measurement for AL${AL} via sev-snp-measure.py (includes kernel/initrd/cmdline; includes alman_roothash for AL4 if present)..."
    fi

    local measurements=""
    measurements="$(calc_expected_snp_measurements "${AL}" "${VM_NAME}" "${fw_path}" "${kernel_path:-}" "${initrd_path:-}" "${cmdline:-}" "${VCPUS}" "${cpu_type_key}")"
    [[ -n "${measurements}" ]] || die "Expected measurement(s) not produced; check sev-snp-measure.py path/config."
    log "Expected measurements: ${measurements}"
    log "Expected measurements JSON updated: ${EXPECTED_MEASUREMENTS_JSON}"
  fi

  virsh define "$xml"
  log "Defined '${VM_NAME}' (AL${AL})."

  if [[ "$AL" -ge 3 ]]; then
    log "AL${AL} direct boot artifacts:"
    log "  kernel=$kernel_path"
    log "  initrd=$initrd_path"
    log "  cmdline=$cmdline"
  fi
}

# virsh wrappers
start_vm()    { need_root; require_cmds virsh; virsh start "$VM_NAME"; }
destroy_vm()  { need_root; require_cmds virsh; virsh destroy "$VM_NAME"; }
console_vm()  { need_root; require_cmds virsh; virsh console "$VM_NAME"; }
undefine_vm() { need_root; require_cmds virsh; virsh undefine "$VM_NAME" --nvram || virsh undefine "$VM_NAME" || true; }

parse_common_args() {
  AL="${AL_DEFAULT}"
  VM_NAME="${VM_NAME_DEFAULT}"


  UBUNTU_SUITE="${UBUNTU_SUITE_DEFAULT}"
  UBUNTU_MIRROR="${UBUNTU_MIRROR_DEFAULT}"

  WORKDIR="${WORKDIR_DEFAULT}"
  DISK_DIR="${DISK_DIR_DEFAULT}"
  CACHE_DIR="${CACHE_DIR_DEFAULT}"
  XML_DIR="${XML_DIR_DEFAULT}"
  DEBOOTSTRAP_CACHE="${DEBOOTSTRAP_CACHE_DEFAULT}"
  APT_CACHE="${APT_CACHE_DEFAULT}"
  CARGO_CACHE="${CARGO_CACHE_DEFAULT}"
  RUSTUP_CACHE="${RUSTUP_CACHE_DEFAULT}"
  BOOT_ARTIFACTS_CACHE="${BOOT_ARTIFACTS_CACHE_DEFAULT}"

  BASE_IMG="${BASE_IMG_DEFAULT}"

  SSH_PUBKEY=""

  AL4_UPPER_MODE="${AL4_UPPER_MODE_DEFAULT}"
  AL4_TMPFS_SIZE="${AL4_TMPFS_SIZE_DEFAULT}"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --al) AL="$2"; shift 2;;
      --name) VM_NAME="$2"; shift 2;;
      --disk-dir) DISK_DIR="$2"; shift 2;;

      --base-path) BASE_IMG="$2"; shift 2;;

      --qemu-bin) QEMU_BIN="$2"; shift 2;;
      --ovmf-code) OVMF_CODE="$2"; shift 2;;
      --ovmf-vars) OVMF_VARS="$2"; shift 2;;

      --ubuntu-suite) UBUNTU_SUITE="$2"; shift 2;;
      --ubuntu-mirror) UBUNTU_MIRROR="$2"; shift 2;;

      --ssh-pubkey) SSH_PUBKEY="$2"; shift 2;;

      --al4-upper-mode) AL4_UPPER_MODE="$2"; shift 2 ;;
      --al4-tmpfs-size) AL4_TMPFS_SIZE="$2"; shift 2 ;;
      *) shift;;
    esac
  done

  [[ -n "$VM_NAME" ]] || die "Missing --name"
  normalize_al

  if [[ "$AL" -eq 4 ]]; then
    case "$AL4_UPPER_MODE" in
      disk|tmpfs) : ;;
      *) die "--al4-upper-mode must be disk|tmpfs (got: $AL4_UPPER_MODE)" ;;
    esac
  fi
}

# Parse a VM name either as first positional arg or via --name.
# Usage: parse_vm_name_arg "$@"
# If first arg is not an option, treat it as VM_NAME, otherwise accept --name <vm>.
parse_vm_name_arg() {
  if [[ $# -gt 0 && "${1:-}" != --* ]]; then
    VM_NAME="$1"
    shift || true
  fi
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --name) VM_NAME="$2"; shift 2;;
      *) shift;;
    esac
  done
}

usage() {
  cat <<EOF
Usage:
  ${SCRIPT_NAME} <command> [options]

Commands:
  host-check
  build-base [--force] [--additional-cmds-file PATH] [--base-path PATH]
  build-vm --al N --name vm1 [--size-gb N] [--ssh-pubkey <key>] [--base-path PATH]
  apply-al --al 3|4 --name vm1
  set-boot-guard --al 3|4 --name vm1
  make-verity --al 4 --name vm1
  define --al N --name vm1 [--mem-mb N] [--vcpus N] [--dryrun]
         AL3/AL4: [--kernel PATH --initrd PATH] [--cmdline <string>] [--no-auto-boot-artifacts] [--al4-upper-mode disk|tmpfs] [--al4-tmpfs-size 512M|1G|...]
         sev-snp-measure: [--sev-snp-measure-py PATH] [--cpu-types-json ${CPU_TYPES_JSON_DEFAULT}] [--legal-cpu-types-json ${LEGAL_CPU_TYPES_JSON_DEFAULT}] [--expected-measurements-json ${EXPECTED_MEASUREMENTS_JSON_DEFAULT}]
  start vm1 | --name vm1
  console vm1 | --name vm1
  undefine vm1 | --name vm1
  destroy vm1 | --name vm1

Global defaults:
  WORKDIR_DEFAULT=${WORKDIR_DEFAULT}
  DISK_DIR_DEFAULT=${DISK_DIR_DEFAULT}
  CACHE_DIR_DEFAULT=${CACHE_DIR_DEFAULT}
  XML_DIR_DEFAULT=${XML_DIR_DEFAULT}
  OVMF_CODE=${OVMF_CODE}
  OVMF_VARS=${OVMF_VARS}

Shell helpers directory:
  ${SHELL_DIR}

Python helpers
  ${PY_DIR}

${SCRIPT_NAME} <command> [args]

Notes:
- For sev-snp-measure.py, either:
    add it to config as SEV_SNP_MEASURE_PY="/path/to/sev-snp-measure.py
  or:
    pass it as --snp-snp-measure-py
EOF
}


main() {
  # Always load config (must exist)
  load_config_file "$CONFIG_FILE"

  # Validate required entries immediately
  [[ -n "$QEMU_BIN" ]] || die "alman.conf missing QEMU_BIN"
  [[ -n "$OVMF_CODE" ]] || die "alman.conf missing OVMF_CODE"
  # OVMF_VARS, OVMF_AL2 / OVMF_AL34 are optional (may be empty)


  local cmd="${1:-}"; shift || true

  case "$cmd" in
    host-check) parse_common_args "$@"; host_check ;;
    build-base) build_base "$@";;
    build-vm) build_vm "$@";;
    apply-al) apply_al "$@";;
    set-boot-guard) set_boot_guard "$@";;
    make-verity) make_verity "$@";;
    define) define_domain "$@";;
    start)
      parse_vm_name_arg "$@"
      start_vm
      ;;
    destroy)
      parse_vm_name_arg "$@"
      destroy_vm
      ;;
    console)
      parse_vm_name_arg "$@"
      console_vm
      ;;
    undefine)
      parse_vm_name_arg "$@"
      undefine_vm
      ;;
    ""|-h|--help) usage;;
    *) die "Unknown command: $cmd";;
  esac
}

main "$@"
