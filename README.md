# Start-Qemu-FreeBSD
Example script to make it easy to spin up an alternate architecture qemu VM (FreeBSD host + FreeBSD guest) for testing. 

This shell script will:
* Download latest FreeBSD (ALPHA/BETA/RC/RELEASE) ISO files and/or VM images required for testing
* Use `pkg` to install dependancies for qemu and bios/firmware for supported architectures.
* Create qcow2 disk images and launch (default = 45G Disk, 4GB RAM, 4 CPU Cores)
* (Optionally) launch console via tmux
* (Optionally) map specific USB devices into guest from host

## Architectures
| Architecture  | ISO | VM Image |
| ------------- | --- | -- |
| arm64 | ✅ Yes | ✅ Yes |
| riscv64 | ✅ Yes | ✅ Yes |
| amd64 | ✅ Yes | ✅ Yes |
| ppc64 | ✅ Yes | ❌No |

## Dependancies
* Functional bridge interface (by default named `bridge0`)
* System with enough ram and proc for qemu to create and execute the VM
* Recent version of FreeBSD for Host (capable of running Qemu 10)

## Notes
* VM Images autodetected and downloaded from https://download.freebsd.org/releases/VM-IMAGES/
* ISO Images autodetected and downloaded from https://download.freebsd.org/releases/ISO-IMAGES/


## CLI Syntax
```
% sudo ./start-qemu.sh
Usage:
 ./start-qemu.sh [-a <arm64|riscv64|amd64|ppc64>] (required)
    [-r <ALPHA|BETA|RC|RELEASE>]
    [-t <ISO|VM>]
    [-T] (start tmux on vm launch)
    [-u <USBDevice String>] (host-to-guest mapping)

 -a will select an architecture arm64|riscv64|amd64|ppc64 (required)
 -r will select the latest ALPHA|BETA|RC|RELEASE version available for download
    The latest version (e.g. 15.0 or 14.3) that matches -r will be used.
 -t will select a VM_IMAGE (Default) or ISO (Install from scratch) for download
 -T will optionally enable tmux serial console and qemu-monitor in foreground
 -u will optionally enable passthrough of specific USB device from HOST to GUEST
```
