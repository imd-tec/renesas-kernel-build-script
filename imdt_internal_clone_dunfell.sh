# !/bin/bash
# This script is for IMDT internal use only
set -euo pipefail
echo "Cloning repositories..."
KERNEL_MODULES=(
  kernel-nxp-wlan
  kernel-module-vspm
  kernel-module-vspmif
  kernel-module-mali
  kernel-module-udmabuf
  kernel-module-mmngrbuf
)
KERNEL="renesas-rz-linux-cip-dev"
CLONE_URL="git@github.com:imd-tec"
clone_repo() {
  local repo="$1"
  local branch="$2"
  if [ ! -d "$repo" ]; then
    git clone -b "$branch" "$CLONE_URL/renesas-$repo.git" $repo
  fi
}
clone_repo "$KERNEL" "rzv2-5.10.y"
for MODULE in "${KERNEL_MODULES[@]}"; do
   # Clone dunfell branch for each module
  clone_repo "$MODULE" "dunfell" "$MODULE"
done