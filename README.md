# Attestation Level Manager (ALman)

The Attestation Level Manager (ALman) is a tooling component for building Confidential VM images and generating Reference Values. It explicitly builds upon the [Attestation Level framework developed by Scopelliti et al.](https://ieeexplore.ieee.org/document/10628910) and references the Reference Value Provider outlined in [RFC9334](https://www.ietf.org/rfc/rfc9334.html). Currently, ALman only supports AMD SEV-SNP.

It implements the image creation part of a larger Confidential Computing Workload Owner stack by enabling Workload Owners to:

- build VM images at explicit attestation levels
- includes [snp-guest](https://github.com/virtee/snpguest) utility into every VM image
- deterministically derive Reference Values for those images

ALman does not perform Attestation, verification, Policy evaluation, or secret release. You can check out my other repo [Simple Attestation Verifier Service (SAVS)](https://github.com/salzg/simple-attestation-verifier-service) for that or use community tools like [Trustee](https://github.com/confidential-containers/trustee).

ALman is designed as a security demonstrator rather than a production image builder.

---

## Motivation

In Confidential Computing, Attestation is only meaningful if there exist well-defined Reference Values describing a trustworthy workload. In practice, many CC deployments do not mitigate the threat of Workload Substitution sufficiently.

ALman exists to demonstrate that:

- Attestation guarantees depend on image construction choices
- different Attestation Levels correspond to different trust assumptions
- Reference Values generation can easily be integrated into image build pipelines

---

## Conceptual Background

### Attestation Levels

An Attestation Level (AL) (see [Scopelliti et al.](https://ieeexplore.ieee.org/document/10628910)) specifies how much of the VM boot chain is covered by Measurements. Higher ALs include more components and therefore support stronger trust assertions.

Distinctions:

| Attestation Level | Measurement Coverage |
|-------------------|----------------------|
| 1 | TEE execution only |
| 2 | Guest Firmware |
| 3 | AL2 + Kernel, initramfs and cmdline |
| 4 | AL3 + root file system |

ALman enforces these distinctions at image build time.

---

## Repository Structure

```text
.
├── alman.sh                    Main build script
├── alman.conf                  Build configuration
├── additional-build.sh         Optional hook for image customisation
├── cpu-types.json              Supported CPU / TEE configurations
├── legal-cpu-types.json        Allowed CPU types
├── expected-measurements.json  Generated reference values
├── helpers/                    Utility scripts
└── README.md
```
---

## Usage

### Setting up the host

This assumes an Ubuntu 24 or 25 host. Install prerequisites. The backports is because you need libvirt >=10.5 for sev-snp

```
sudo add-apt-repository ppa:canonical-server/server-backports
sudo apt update && sudo apt upgrade
sudo apt install -y gcc python3 python3-pip python3-sphinx python3-sphinx-rtd-theme \
    ninja-build pkg-config util-linux cmake nasm iasl libssl-dev qemu-utils \
    libglib2.0-dev parted libvirt-clients libvirt-daemon libvirt-daemon-system \
    virtinst debootstrap
sudo ln /usr/bin/python3 /usr/bin/python
sudo usermod -aG libvirt,kvm "$USER"
```

Clone and follow the instructions in AMD's [AMDESE/AMDSEV snp-latest branch](https://github.com/AMDESE/AMDSEV/tree/snp-latest) to set up your host firmware. You probably don't need to build the kernel as any 6.11+ kernel should suffice.  In particular, you want the OVMF and QEMU builds using the following commands. If your host kernel does not work for some reason, consider building one according to the repo's instructions. Depending on your setup you might need to sudo the commands.


```
mkdir ~/src
cd ~/src
git clone https://github.com/AMDESE/AMDSEV.git
git checkout snp-latest
./build.sh ovmf
./build.sh qemu
```

This has build the QEMU binary and the default OVMF Guest Firmware. Extract the build OVMF firmware to another directory.

```
mkdir ~/omvf
mkdir ~/ovmf/al12
cp ~/src/AMDSEV/usr/local/share/qemu/OVMF* ~/ovmf/al12/
```

You have build the Guest Firmware for AL1 and AL2. Now, you need to build Guest FW which enables kernel hashing, so that AL3 and AL4 can be reached.

Edit `common.sh` in the AMD repo on line 173 (as of time of writing) from 

```
BUILD_CMD="nice build -q --cmd-len=64436 -DDEBUG_ON_SERIAL_PORT=TRUE -n $(getconf _NPROCESSORS_ONLN) ${GCCVERS:+-t $GCCVERS} -a X64 -p OvmfPkg/OvmfPkgX64.dsc"
```

to 
```
BUILD_CMD="nice build -q --cmd-len=64436 -DDEBUG_ON_SERIAL_PORT=TRUE -n $(getconf _NPROCESSORS_ONLN) ${GCCVERS:+-t $GCCVERS} -a X64 -p OvmfPkg/AmdSev/AmdSevX64.dsc"
```

(you are changing the -p parameter from `OvmfPkg/OvmfPkgX64.dsc` to `OvmfPkg/AmdSev/AmdSevX64.dsc`). Commmands:

```
cd ~/src/AMDSEV
vim common.sh
touch ovmf/OvmfPkg/AmdSev/Grub/grub.efi
```

Build OVMF and extract the artefact.

```
./build.sh ovmf
mkdir ~/ovmf/al34
cp ~/src/AMDSEV/ovmf/Build/AmdSev/DEBUG_GCC5/FV/OVMF.fd ~/ovmf/al34/
```

Install [sev-snp-measure](https://github.com/virtee/sev-snp-measure)

```
cd ~/src
git clone https://github.com/virtee/sev-snp-measure
```

---

## Using ALman

Configure `alman.conf` to point to `sev-snp-measure.py`, your extracted OVMF versions and the QEMU binary, and make script executable.

```
cd ~/attestation-level-manager
chmod +x alman.sh
vim alman.conf
```

Check host setup, should say OK

```
sudo ./alman.sh host-check
```

### Build base image

You can build a default base image via

```
sudo ./alman.sh build-base
```

Optional args are

```
--force                            overwrite base image
--additional-cmds-file <path>      image customisation file, additional_commands.sh by default
--base-path <path>                 destination path of base image, defaults to ./cache/base-ubuntu-noble.qcow2
```

### Build specific VM images

Based on the base image, specific VM images are created as overlays to the base image. You can specify which AL those images are supposed to be.

Examples:
```
sudo ./alman.sh --al 2 --name some-AL2-VM
sudo ./alman.sh --al 0 --name no-AL-VM
sudo ./alman.sh --al 4 --name some AL4-VM
```

Optional Arguments

```
--base-path <path>                 path to base image to use, default ./cache/base-ubuntu-noble.qcow2
--size-gb <N>                      size of image to be created, default 12G
--ssh-pubkey <path-to-key>         path to ssh key to include
```

### Apply AL (AL3 & AL4 only)

This is only necessary for AL3 and AL4. Injects scripts into initramfs

```
sudo ./alman.sh apply-al --al 3 --name some-AL3-VM
sudo ./alman.sh apply-al --al 4 --name some-AL4-VM
```

### make verity (AL4 only)

Important for AL4. Sets up dm-verity over root disk. Stores roothash as ENV variable for next command

```
ROOTHASH=$(sudo ./alman.sh make-verity --al 4 --name some-AL4-VM)
```

### Define virsh domain

This defines a vish domain. If you do not intend to run the VM on the machine you are currently running ALman on, use the dry-run option to generate an XML which you can export together with the VM images. You could be running into AppArmor or virsh permission issues here, check the "Useful commands for troubleshooting" further below. On success, it virsh domains are defined and the expected measurements are written to `expected-measurements.json`

```
sudo ./alman.sh define --al 3 --name some-AL3-VM
sudo ./alman.sh define --al 4 --name some-AL4-VM
```

Optional commands
```
--mem-mb N          Memory in mb to provision
--vcpus N           Amount of vCPUs to provision
--dryrun            simply output the XML, don't define it on this machine

AL3/4:
--kernel <path>                     path to kernel, not required due to autoextraction
--initrd <path>                     path to initrd, not required due to autoextraction
--cmdline <string>                  kernel cmdline to use, gets overwritten for AL3 and AL4 for now
--no-auto-boot-artifacts            disables autoextraction, you need to provide --kernel and --initrd

AL4:
--al4-upper-mode disk|tmpfs         type of overlay to use, disk-backed or ram-backed
--al4-tmpfs-size 512M|1G|...        size of overlay

sev-snp-measure specifics
--sev-snp-measure-py PATH           path to sev-snp-measure.py, default from alman.conf
--cpu-types-json <path>             path to cpu-types.json, default ./cpu-types.json
--legal-cpu-types-json <path>       path to legal-cpu-types.json, default ./legal-cpu-types.json
--expected-measurements-json <path> path to expected-measurements.json, default ./expected-measurements.json
```

### virsh wrappers

ALman also wraps the following virsh commands: `start` (start your defined domain). `console` (console access to your domain), `destroy` (shutdown the domain), and `undefine` (remove the domain).

## Useful commands for troubleshooting

### virsh, QEMU and kvm hijinks
Some permission errors stem from weird QEMU/KVM permission alignments. This can be most likely fixed by editing `/etc/libvirt/qemu.conf` to use root.

```
vim /etc/libvirt/qemu.conf
```

Find `user=`, `group=`, and `dynamic_ownership=1` around line 530, and change (and uncomment) the lines to

```
user= "root"
group="0"
dynamic_ownership=1
```


### AppArmor

If you get "permission denied" on your QEMU binary when executing the virsh commands, check your `dmesg | tail`. If AppArmor is throwing a fit, you could add the right permission masks for e.g. the QEMU binary etc. Alternatively, and I would not recommend this, nuke AppArmor. On a completely unrelated note, the commands to nuke AppArmor are below.

Disabling the service
```
sudo systemctl stop apparmor
sudo systemctl disable apparmor
sudo aa-teardown
```
Killing it via adding `apparmor=0` to the cmdline
```
vim /etc/default/grub       # or /etc/default/grub.d/<file>, depending on your setup. Add "apparmor=0" to the cmdline
sudo update-grub
sudo reboot
```

---

## FAQ

### Can I use this in production?

~~Only if you scream "WITNESS ME!" while doing such a reckless stunt.~~ No. Why would you? Which part about nuking AppArmor or giving KVM/QEMU blank root made you go "by Jove, that would be just splendid in my prod system"? This is just a simple demo. Use at your own risk.
