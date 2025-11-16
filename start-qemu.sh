#!/bin/sh
set -o errexit
#set -o pipefail

# Helper script for running FreeBSD under Qemu (multi-arch)
# Downloads images/ISOs from FreeBSD master site
# Maps in usb devices as desired to guest

#UI color/bold consts
RED="\\033[31m"
GREEN="\\033[32m"
BLUE="\\033[34m"
NO_COLOR="\\033[39m"

# Global constants
dl_uri="https://download.freebsd.org/releases/"
work_dir="."

# Qemu hardware config (adjust as desired)
memory="4g"
cpus="8"
bridge="bridge0"
disksize="45g"
serial_0_tcpport="4444"
serial_1_tcpport="4445"

# Check for root privs
idu="$(id -u)"
[ ${idu} != "0" ] && echo "You must be root (or sudo) to run $0" && exit 1

usage() { 
	echo "Usage:"
	echo " $0 [-a <arm64|riscv64|amd64|ppc64>] (required)"
	echo -e "    [-r <ALPHA|BETA|RC|${GREEN}RELEASE${NO_COLOR}>]" 
	echo -e "    [-t <ISO|${GREEN}VM${NO_COLOR}>]"
	echo "    [-T] (start tmux on vm launch)"
	echo "    [-u <USBDevice String>] (host-to-guest mapping)"
	echo ""
	echo " -a will select an architecture arm64|riscv64|amd64|ppc64 (required)"
	echo -e " -r will select the latest ALPHA|BETA|RC|${GREEN}RELEASE${NO_COLOR} version available for download"
	echo "    The latest version (e.g. 15.0 or 14.3) that matches -r will be used."
	echo -e " -t will select a ${GREEN}VM_IMAGE (Default)${NO_COLOR} or ISO (Install from scratch) for download"
	echo " -T will optionally enable tmux serial console and qemu-monitor in foreground"
	echo " -u will optionally enable passthrough of specific USB device from HOST to GUEST"
	echo ""
	exit 1
}

# If variable not defined, define default. 
r="RELEASE"
t="VM"

while getopts ":a:r:u:t:T" opt; do
	case "${opt}" in
		a)
			a=${OPTARG}
			[ ${a} = "arm64" -o ${a} = "riscv64" -o ${a} = "amd64" -o ${a} = "ppc64" ] || usage
			;;
		r)
			r=${OPTARG}
			# If it does not match BETA or ALPHA set to RELEASE
			[ ${r} = "BETA" -o ${r} = "ALPHA" -o ${r} = "RC" -o ${r} = "RELEASE" ] || usage 
			;;
		u)
			u=${OPTARG}
			;;
		t)
			t=${OPTARG}
			# Only support VM and ISO at the moment.
			[ ${t} = "VM" -o ${t} = "ISO" ] || t="VM"
			;;
		T)
			T="YES"
			pkg info tmux >/dev/null || pkg install -y tmux
			;;
		*)
			usage
			;;
	esac
done
shift $((OPTIND-1))

# Check for REQUIRED args
if [ -z "${a}" ]; then
	usage
fi

# Check to make sure qemu is installed
which qemu-system-x86_64 >/dev/null 2>&1 || pkg install -y qemu-nox11

# Check for qemu-ifup/ifdown scripts, and set reasonable defaults for bridge and tap
# Qemu will automatically create the tap interface at startup
[ ! -s /usr/local/etc/qemu-ifup ] && printf "#!/bin/sh\nifconfig ${bridge} addm \$1 up\nifconfig \$1 up\n" >/usr/local/etc/qemu-ifup && chmod +x /usr/local/etc/qemu-ifup
[ ! -s /usr/local/etc/qemu-ifdown ] && printf "#!/bin/sh\nifconfig \$1 down\nifconfig ${bridge} deletem \$1\n" >/usr/local/etc/qemu-ifdown && chmod +x /usr/local/etc/qemu-ifdown

# Handle the architecture specific variables and arguments
case "${a}" in
	amd64)
		arch="amd64"
		archvariant="amd64"
		bios="-bios /usr/local/share/edk2-qemu/QEMU_UEFI-x86_64.fd"
		qemu_bin="qemu-system-x86_64"
		machine="q35"
		pkg info edk2-qemu-x64 >/dev/null || pkg install -y edk2-qemu-x64
		;;
	arm64)
		arch="aarch64"
		archvariant="arm64-${arch}"
		bios="-bios edk2-aarch64-code.fd"
		qemu_bin="qemu-system-aarch64"
		machine="virt"
		;;
	riscv64)
		arch="riscv64"
		archvariant="riscv-${arch}"
		bios="-bios /usr/local/share/opensbi/lp64/generic/firmware/fw_jump.elf -kernel /usr/local/share/u-boot/u-boot-qemu-riscv64/u-boot.bin"
		qemu_bin="qemu-system-riscv64"
		machine="virt"
		pkg info opensbi >/dev/null || pkg install -y opensbi
		pkg info u-boot-qemu-riscv64 >/dev/null || pkg install -y u-boot-qemu-riscv64
		;;
	ppc64)
		arch="powerpc64"
		archvariant="powerpc-${arch}"
		# These disable flags are needed as per https://wiki.freebsd.org/powerpc/QEMU
		archflags="-vga none -nographic"
		# bios is null as there is a built-in ppc64 open firmware
		# https://qemu.readthedocs.io/en/v10.0.3/system/ppc/pseries.html
		bios=""
		qemu_bin="qemu-system-ppc64"
		machine="pseries,cap-cfpc=broken,cap-sbbc=broken,cap-ibs=broken"
		;;
esac

validate-sha512() {
	set +o errexit
	[ -z "${1}" -o ! -s ${1} ] && echo "No file ${1} for hash verification" && exit 1
	echo "Validating SHA512 CHECKSUM..."
	# We are cheating a bit and just using file globs so we don't need to pass in exact CHECKSUM filename
	expect_hash=$(grep ${1} CHECKSUM.SHA512* | cut -d "=" -f 2 | tr -d ' ')
	#echo "expect_hash: ${expect_hash}"
	actual_hash=$(sha512sum --quiet ${1} | tr -d ' ')
	#echo "actual_hash: ${actual_hash}"
	if [ "${expect_hash}" != "${actual_hash}" ] ; then
		printf "Failure validating hash on ${1}. \nExpect: ${expect_hash} \nActual: ${actual_hash}\n" 
		exit 1
	fi
	set -o errexit
}

fetch-image() {
	latest_version=$(curl -s ${dl_uri}VM-IMAGES/ \
		| grep -E -o -e "[0-9.]{3}[0-9]{1}-${r}[0-9]*/" | uniq | sort -gr | head -1 | tr -d '/')
	[ -z ${latest_version} ] && echo "Error: No VM files found matching cli parameters." && exit 1
	image_file="FreeBSD-${latest_version}-${archvariant}-ufs.qcow2"
	if [ ! -s ${image_file} ] ; then
		echo "Fetching VM Image: ${image_file}"
		if [ ${a} = "ppc64" ]; then
        		echo "Warning:  PowerPC 64 does not have a VM image for FreeBSD at this time (2025), looking anyway..."
			echo "Recommend using -t ISO for ppc64"
		fi
		fetch "${dl_uri}VM-IMAGES/${latest_version}/${arch}/Latest/${image_file}.xz" "${dl_uri}VM-IMAGES/${latest_version}/${arch}/Latest/CHECKSUM.SHA512"
		validate-sha512 ${image_file}.xz 
		unxz ${image_file}.xz
		qemu-img resize ${image_file} +${disksize}
	fi
}

fetch-iso() {
	toplevel_version=$(curl -s ${dl_uri}VM-IMAGES/ \
		| grep -E -o -e "[0-9.]{3}[0-9]{1}-${r}[0-9]*/" | uniq | sort -gr | \
		head -1 | tr -d '/' | sed s/-${r}[0-9]*//1)
	#echo "toplevel_version: ${toplevel_version}"
	latest_version=$(curl -s ${dl_uri}ISO-IMAGES/${toplevel_version}/ \
		| grep -E -o -e "[0-9.]{3}[0-9]{1}-${r}[0-9]*" | uniq | sort -gr | head -1 | tr -d '/')
	[ -z ${latest_version} ] && echo "Error: No ISO files found matching cli parameters." && exit 1
	#echo "latest_version: ${latest_version}"
	iso_file="FreeBSD-${latest_version}-${archvariant}-bootonly.iso"
	echo "Getting ready to fetch and/or start ${iso_file}"
	iso_boot_cli="-boot order=d -cdrom ${iso_file}"
	image_file="FreeBSD-${latest_version}-${archvariant}-ufs.qcow2"
	iso_dl_uri="${dl_uri}ISO-IMAGES/${toplevel_version}/${iso_file}"
	checksum_dl_uri="${dl_uri}ISO-IMAGES/${toplevel_version}/CHECKSUM.SHA512-FreeBSD-${latest_version}-${archvariant}"

	# The bootindex variable and other bootorder only works with x86_64 (amd64) as of 10.1.x
	#iso_boot_cli="-boot once=d -drive file=${iso_dl_uri},if=none,id=cdrom0,media=cdrom -device virtio-blk-pci,drive=cdrom0,bootindex=1"

	if [ ! -s ${iso_file} ] ; then
		fetch "${iso_dl_uri}.xz" "${checksum_dl_uri}"
		validate-sha512 ${iso_file}.xz 
		unxz ${iso_file}.xz
	fi
	if [ ! -s ${image_file} ] ; then
		qemu-img create -f qcow2 ${image_file} ${disksize} 
	else
		read -p "You selected ISO Install with an existing disk image ${image_file}.  Do you wish to remove the existing file and recreate a blank disk file ? (y/n): " overwrite
		if [ "${overwrite}" = "y" -o "${overwrite}" = "Y" ] ; then
			rm ${image_file} 
			qemu-img create -f qcow2 ${image_file} ${disksize} 
		fi
	fi
	validate-sha512 ${iso_file}
}

setup-usb-passthrough() {
	echo "Attempting to passthrough usb host device based on query string: ${u}"
	usb_map_count=$(usbconfig | grep -cie ${u})
	[ ${usb_map_count} -ne 1 ] && \
		echo "Total devices matched: ${usb_map_count} is not equal to 1, please refine." && \
		usbconfig && exit 1
	usb_map=$(usbconfig | grep -ie ${u} | grep -E -o -e "[0-9]+\.[0-9]+")
	#echo "usb_map: ${usb_map}"
	usb_map_bus=$(echo ${usb_map} | grep -E -o -e "^[0-9]+")
	usb_map_addr=$(echo ${usb_map} | grep -E -o -e "[0-9]+$")
	usb_qemu_cli="-device usb-host,hostbus=${usb_map_bus},hostaddr=${usb_map_addr},id=${u}"
	echo "Mapping usb device $(usbconfig | grep -ie ${u}) into the guest."
	#echo "usb_qemu_cli = ${usb_qemu_cli}"
	echo -n "In qemu monitor, you can inspect attached usb guest devices with \"info usb\" "
	echo "command, or delete the usb device mapping with \"device_del ${u}\""
}

start-tmux() {
	tmux new-session -d -s qemu-monitor "telnet localhost ${serial_1_tcpport}" 
	tmux new-session -d -s ${image_file} "telnet localhost ${serial_0_tcpport}"
	tmux attach
}

[ ${t} = "VM" ] && fetch-image
[ ${t} = "ISO" ] && fetch-iso
[ ! -z "${u}" ] && setup-usb-passthrough

# Safety check.
set +o errexit
if [ ! -z "$(pgrep qemu-system)" ]; then
	echo "Qemu is already running. Attach to existing console or shutdown the guest."
	# Dynamically see if there is a telnet running under a tmux using pgrep
	tmux_pid=$(pgrep tmux || echo 0)
	if [ $(pgrep -P ${tmux_pid} -l | grep -c telnet) -gt 0 ]; then 
		echo "Try: tmux attach"
	else
		echo "Try: telnet localhost ${serial_0_tcpport} or telnet localhost ${serial_1_tcpport}"
	fi
	exit 1
fi

# Cleanup tap0 interfaces that are not in use anymore.
ifconfig tap0 2>/dev/null | grep -cq -e "Opened by PID" || ifconfig tap0 destroy 2>/dev/null || true
set -o errexit
echo "Starting Qemu in background..."

${qemu_bin} -m ${memory} -cpu max -smp cpus=${cpus} -M ${machine} \
	${bios} \
	${iso_boot_cli} \
	${archflags} \
	-serial telnet:localhost:${serial_0_tcpport},mux=on,server,wait=off \
	-monitor telnet:localhost:${serial_1_tcpport},mux=on,server,wait=off \
	-display none \
	-drive if=none,file=${work_dir}/${image_file},id=hd0 \
	-device virtio-blk-pci,drive=hd0 \
	-device virtio-net-pci,netdev=net0 \
	-netdev tap,id=net0 \
	-usb \
	-device qemu-xhci,id=xhci \
	${usb_qemu_cli} \
	-daemonize

if [ "${t}" = "ISO" -a -z "${T}" ] ; then
	telnet localhost ${serial_0_tcpport} 
elif [ "${T}" ] ; then
	start-tmux
else
	echo "Connect to guest console (telnet localhost ${serial_0_tcpport}), or qemu monitor (telnet localhost ${serial_1_tcpport})"
fi
