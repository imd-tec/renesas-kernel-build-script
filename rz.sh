#!/bin/bash
# Script to build and deploy Renesas RZV2H kernel and modules
# Usage: ./rz.sh [IP_ADDRESS | SSH_CONFIG_HOST] [SSH_PORT]
#   ./rz.sh                        # default target 172.16.30.100:22 as root
#   ./rz.sh 172.16.30.101 2222     # explicit IP and port, as root
#   ./rz.sh renesas-office         # a Host entry from ~/.ssh/config (HostName/User/Port taken from it)
#   ./rz.sh renesas-office 2222    # ...with the config's Port overridden
set -euo pipefail
set -x

# create aliases for scp and ssh to ignore host key checking. This avoids the issue of a newly flashed target having a different host key and scp/ssh refusing to connect.
# It also avoids polluting the known_hosts file on the host machine with entries for each new target.
scpa() { scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "$@"; }
ssha() { ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "$@"; }

TARGET="${1:-172.16.30.100}"
PORT_ARG="${2:-}"

# Resolve the target. A bare IP keeps the historic behaviour (root, port 22 unless given);
# anything else is treated as an ssh_config Host entry and its HostName/User/Port are used.
if [[ "$TARGET" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; then
	IP="$TARGET"
	SSH_TARGET="root@$TARGET"
	PORT="${PORT_ARG:-22}"
else
	# ssh -G prints the effective config for this host, including ~/.ssh/config entries
	SSH_CFG="$(ssh -G "$TARGET" 2>/dev/null || true)"
	if [[ -z "$SSH_CFG" ]]; then
		echo "ERROR: could not resolve '$TARGET' via ssh config." >&2
		exit 1
	fi
	CFG_HOSTNAME="$(awk '$1 == "hostname" { print $2; exit }' <<<"$SSH_CFG")"
	CFG_USER="$(awk '$1 == "user" { print $2; exit }' <<<"$SSH_CFG")"
	CFG_PORT="$(awk '$1 == "port" { print $2; exit }' <<<"$SSH_CFG")"

	IP="${CFG_HOSTNAME:-$TARGET}"
	PORT="${PORT_ARG:-${CFG_PORT:-22}}"
	# ssh -G falls back to the local login name when no User is set; deployment needs root.
	if [[ -z "$CFG_USER" || "$CFG_USER" == "$(id -un)" ]]; then
		CFG_USER="root"
	fi
	# Use the alias itself as the ssh destination so the rest of its config still applies.
	SSH_TARGET="${CFG_USER}@${TARGET}"
	echo "Using ssh config host '$TARGET' -> ${CFG_USER}@${IP}:${PORT}"
fi

MODULES_FOLDER="/tmp/rzv2h_modules"
CLONE_URL="git@github.com:imd-tec"
# Repo list
KERNEL="renesas-rz-linux-cip-dev"
KERNEL_MODULES=(
	kernel-module-nxp-wlan
	kernel-module-vspm
	kernel-module-vspmif
	kernel-module-mali
	kernel-module-mmngrbuf
	kernel-module-uvcs-drv
	kernel-module-edgecortix
)
# Use associative array for build directories
declare -A MODULE_BUILD_DIRS=(
	# NB: keep these subscripts quoted. Unquoted, the '-' is parsed as arithmetic
	# subtraction (and shell formatters rewrite them to [kernel - module - ...]),
	# which collapses every key to 0 and breaks every lookup in build_module.
	["kernel-module-nxp-wlan"]="kernel-module-nxp-wlan"
	["kernel-module-vspm"]="kernel-module-vspm/vspm-module/files/vspm/drv"
	["kernel-module-vspmif"]="kernel-module-vspmif/vspm_if-module/files/vspm_if/drv"
	["kernel-module-mali"]="kernel-module-mali/drivers/gpu/arm/midgard"
	["kernel-module-mmngrbuf"]="kernel-module-mmngrbuf/mmngr_drv/mmngrbuf/mmngrbuf-module/files/mmngrbuf/drv"
	["kernel-module-uvcs-drv"]="kernel-module-uvcs-drv/src/makefile"
	["kernel-module-edgecortix"]="kernel-module-edgecortix"
)

SCRIPT_DIR="$(pwd)"
OUTOFTREEFOLDER="${SCRIPT_DIR}/build/out_of_tree_modules"
# Export common variables
export KERNELSRC="${SCRIPT_DIR}/${KERNEL}"
export ARCH=arm64
export CROSS_COMPILE=aarch64-linux-gnu-
export INCSHARED="$(mktemp -d)"
export CP=cp
export OUTOFTREEFOLDER
# Create out-of-tree folder. Wipe it first: everything left here gets copied into
# the deployed tarball, so stale .ko files from earlier builds (or from modules no
# longer in KERNEL_MODULES) would otherwise ship to the target and fail to load.
rm -rf "$OUTOFTREEFOLDER"
mkdir -p "$OUTOFTREEFOLDER"
# Build kernel and modules
pushd "$KERNELSRC" >/dev/null
make defconfig

VERSIONS_STRING=$(make -s kernelrelease)
echo "Building kernel version: $VERSIONS_STRING"
INSTALL_MOD_PATH="$MODULES_FOLDER" DTC_FLAGS=-@ make -j 24 all modules_prepare
rm -rf "$MODULES_FOLDER"
popd >/dev/null

# Function to build a module
build_module() {
	local module_name="$1"
	local build_dir="${MODULE_BUILD_DIRS[$module_name]:-}"
	if [[ -z "$build_dir" ]]; then
		echo "Unknown module: $module_name" >&2
		return 1
	fi

	echo "Building $module_name in $build_dir"
	pushd "$build_dir" >/dev/null

	# Set KDIR and KERNELDIR for all modules
	export KDIR="$KERNELSRC"
	export KERNELDIR="$KERNELSRC"
	# These vendor trees trip warnings on a current GCC (implicit-fallthrough etc.)
	# that the kernel's CONFIG_WERROR=y turns fatal. We don't own this source, so
	# keep the warnings visible but non-fatal for out-of-tree modules only.
	export KCFLAGS="-Wno-error"

	# Per-module special logic
	if [[ "$module_name" == "kernel-module-vspm" ]]; then
		make -j "$(nproc)"
		make install
		cp Module.symvers "${KERNELSRC}/include/vspm.symvers"
	elif [[ "$module_name" == "kernel-module-mmngrbuf" ]]; then
		MMNGR_CFG="MMNGR_SALVATORX"
		export MMNGR_CONFIG=${MMNGR_CFG}
		export MMNGR_SSP_CONFIG="MMNGR_SSP_DISABLE"
		export MMNGR_IPMMU_MMU_CONFIG="IPMMU_MMU_DISABLE"
		export CP=cp
		make -j "$(nproc)"
		mkdir -p "$OUTOFTREEFOLDER/$module_name"
		cp *.ko "$OUTOFTREEFOLDER/$module_name/" 2>/dev/null || true
		# Also build mmngr
		popd >/dev/null
		pushd "${SCRIPT_DIR}/kernel-module-mmngrbuf/mmngr_drv/mmngr/mmngr-module/files/mmngr/drv" >/dev/null
		export KDIR="$KERNELSRC"
		export KERNELDIR="$KERNELSRC"
		make -j "$(nproc)"
	elif [[ "$module_name" == "kernel-module-uvcs-drv" ]]; then
		export UVCS_SRC=..
		export VCP4_SRC=..
		export UVCS_INC=../..
		make -j "$(nproc)"
	else
		make -j "$(nproc)"
	fi
	echo "Built $module_name"
	# Copy .ko files to out-of-tree folder
	mkdir -p "$OUTOFTREEFOLDER/$module_name"
	cp *.ko "$OUTOFTREEFOLDER/$module_name/" 2>/dev/null || true

	popd >/dev/null
}

# Build VSPM first as other modules depend on its symbols
build_module "kernel-module-vspm"

# Build the rest in parallel
pids=()
for MODULE in "${KERNEL_MODULES[@]}"; do
	if [ "$MODULE" != "kernel-module-vspm" ]; then
		build_module "$MODULE" &
		pids+=("$!")
	fi
done
# Wait for all background jobs
build_failed=0
for pid in "${pids[@]}"; do
	if ! wait "$pid"; then
		echo "ERROR: background build job (pid=$pid) failed" >&2
		build_failed=1
	fi
done
[[ $build_failed -eq 0 ]] || exit 1

echo "Finished building all modules"
# Install modules to staging folder
pushd "$KERNELSRC" >/dev/null
echo "Done building modules, installing to $MODULES_FOLDER"
INSTALL_MOD_PATH="$MODULES_FOLDER" make -j 24 modules_install

echo "Preparing kernel module deployment to $IP"
echo "Making tar of kernel modules"
rm -rf "$MODULES_FOLDER/lib/modules/"*/build "$MODULES_FOLDER/lib/modules/"*/source

# Copy out-of-tree modules
popd >/dev/null
cp -r "$OUTOFTREEFOLDER"/* "$MODULES_FOLDER/lib/modules/$VERSIONS_STRING/" || true
depmod -b "$MODULES_FOLDER" -a "$VERSIONS_STRING"
tar -czf /tmp/lib.tar.gz -C "$MODULES_FOLDER" lib

# Deploy to target
echo "Checking target $IP is reachable..."
# ICMP can be blocked (or the host only reachable through a ProxyJump), so fall back to an ssh probe.
if ! ping -c 1 -W 2 "$IP" >/dev/null 2>&1; then
	echo "Ping to $IP failed, trying ssh..."
	if ! ssha -p "$PORT" -o BatchMode=yes -o ConnectTimeout=5 "$SSH_TARGET" true >/dev/null 2>&1; then
		echo "ERROR: Target $SSH_TARGET ($IP:$PORT) is not reachable. Aborting deployment." >&2
		exit 1
	fi
fi

pushd "$KERNELSRC" >/dev/null
echo "Copying files to $SSH_TARGET"
scpa -P "$PORT" -O /tmp/lib.tar.gz "$SSH_TARGET":/tmp/
scpa -P "$PORT" -O arch/arm64/boot/dts/renesas/*imdt*.dtb "$SSH_TARGET":/boot/
scpa -P "$PORT" -O arch/arm64/boot/Image "$SSH_TARGET":/boot/Image-"$VERSIONS_STRING"
ssha -p "$PORT" "$SSH_TARGET" "ln -sf Image-${VERSIONS_STRING} /boot/Image && rm -Rf /lib/modules/5*/ && tar -xzf /tmp/lib.tar.gz -C / && sync"
echo "Deployment complete for $VERSIONS_STRING"
popd >/dev/null
