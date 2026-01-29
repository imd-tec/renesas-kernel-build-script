
#!/bin/bash
# Script to build and deploy Renesas RZV2H kernel and modules
# Usage: ./rz.sh [IP_ADDRESS] [SSH_PORT]
set -euo pipefail

IP="${1:-172.16.30.100}"
PORT="${2:-22}"
MODULES_FOLDER="/tmp/rzv2h_modules"
CLONE_URL="git@github.com:imd-tec"
# Repo list
KERNEL="renesas-rz-linux-cip-dev"
KERNEL_MODULES=(
  kernel-nxp-wlan
  kernel-module-vspm
  kernel-module-vspmif
  kernel-module-mali
  kernel-module-udmabuf
  kernel-module-mmngrbuf
  kernel-module-uvcs-drv
)
# Use associative array for build directories
declare -A MODULE_BUILD_DIRS=(
  [kernel-nxp-wlan]="kernel-nxp-wlan/mxm_wifiex/wlan_src"
  [kernel-module-vspm]="kernel-module-vspm/vspm-module/files/vspm/drv"
  [kernel-module-vspmif]="kernel-module-vspmif/vspm_if-module/files/vspm_if/drv"
  [kernel-module-mali]="kernel-module-mali/drivers/gpu/arm/midgard"
  [kernel-module-udmabuf]="kernel-module-udmabuf"
  [kernel-module-mmngrbuf]="kernel-module-mmngrbuf/mmngr_drv/mmngrbuf/mmngrbuf-module/files/mmngrbuf/drv"
  [kernel-module-uvcs-drv]="kernel-module-uvcs-drv/src/makefile"
)

SCRIPT_DIR="$(pwd)"
OUTOFTREEFOLDER="${SCRIPT_DIR}/build/out_of_tree_modules"
# Source Yocto environment
. /opt/poky/3.1.33/environment-setup-aarch64-poky-linux
# Export common variables
export KERNELSRC="${SCRIPT_DIR}/${KERNEL}"
export ARCH=arm64
export INCSHARED="$(mktemp -d)"
export CP=cp
export OUTOFTREEFOLDER
# Create out-of-tree folder
mkdir -p "$OUTOFTREEFOLDER"
# Build kernel and modules
pushd "$KERNELSRC" > /dev/null
make defconfig
VERSIONS_STRING=$(make -s kernelrelease)
echo "Building kernel version: $VERSIONS_STRING"
INSTALL_MOD_PATH="$MODULES_FOLDER" DTC_FLAGS=-@ make -j 24 all modules_prepare
rm -rf "$MODULES_FOLDER"
popd > /dev/null

# Function to build a module
build_module() {
  local module_name="$1"
  local build_dir="${MODULE_BUILD_DIRS[$module_name]:-}"
  if [[ -z "$build_dir" ]]; then
    echo "Unknown module: $module_name" >&2
    return 1
  fi

  echo "Building $module_name in $build_dir"
  pushd "$build_dir" > /dev/null

  # Set KDIR and KERNELDIR for all modules
  export KDIR="$KERNELSRC"
  export KERNELDIR="$KERNELSRC"

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
    popd > /dev/null
    pushd "kernel-module-mmngrbuf/mmngr_drv/mmngr/mmngr-module/files/mmngr/drv" > /dev/null
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

  popd > /dev/null
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
for pid in "${pids[@]}"; do
  wait "$pid"
done

echo "Finished building all modules"
# Install modules to staging folder
pushd "$KERNELSRC" > /dev/null
echo "Done building modules, installing to $MODULES_FOLDER"
INSTALL_MOD_PATH="$MODULES_FOLDER" make -j 24 modules_install

echo "Preparing kernel module deployment to $IP"
echo "Making tar of kernel modules"
rm -rf "$MODULES_FOLDER/lib/modules/"*/build "$MODULES_FOLDER/lib/modules/"*/source
# Copy out-of-tree modules
popd > /dev/null
cp -r "$OUTOFTREEFOLDER"/* "$MODULES_FOLDER/lib/modules/$VERSIONS_STRING/" || true
depmod -b "$MODULES_FOLDER" -a "$VERSIONS_STRING"
tar -czf /tmp/lib.tar.gz -C "$MODULES_FOLDER" lib
# Deploy to target
pushd "$KERNELSRC" > /dev/null
echo "Copying files to $IP"
scp -P "$PORT" -O /tmp/lib.tar.gz root@"$IP":/tmp/
scp -P "$PORT" -O arch/arm64/boot/dts/renesas/*imdt*.dtb arch/arm64/boot/Image root@"$IP":/boot/
ssh -p "$PORT" root@"$IP" "rm -Rf /lib/modules/5*/ && tar -xzf /tmp/lib.tar.gz -C / && sync"
echo "Deployment complete for $VERSIONS_STRING"
popd > /dev/null