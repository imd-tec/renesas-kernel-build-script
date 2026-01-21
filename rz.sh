CLONE_URL=git@github.com:imd-tec
KERNEL='renesas-rz-linux-cip-dev'
KERNEL_MODULES='renesas-kernel-nxp-wlan  renesas-kernel-module-vspm renesas-kernel-module-vspmif renesas-kernel-module-mali reneas-kernel-module-udmabuf renesas-kernel-module-mmngrbuf'
IP=172.16.30.100
CROSS_COMPILE=aarch64-linux-gnu-
PORT=22
MODULES_FOLDER=/tmp/rzv2h_modules
START_DIR=$(pwd)
. /opt/poky/3.1.33/environment-setup-aarch64-poky-linux 
# Clone kernel and modules
if [ ! -d renesas-rz-linux-cip-dev ]; then
  git clone $CLONE_URL/$KERNEL.git
fi
for MODULE in ${KERNEL_MODULES[@]}; do
  if [ ! -d $MODULE ]; then
    git clone $CLONE_URL/$MODULE.git
  fi
done
# Build kernel and modules
cd renesas-rz-linux-cip-dev
ARCH=arm64 make defconfig
ARCH=arm64  INSTALL_MOD_PATH=$MODULES_FOLDER  DTC_FLAGS=-@ make -j 24
rm -R $MODULES_FOLDER
for MODULE in ${KERNEL_MODULES[@]}; do
  echo "Building module: $MODULE"
  cd $START_DIR/$MODULE
  ARCH=arm64  INSTALL_MOD_PATH=$MODULES_FOLDER make -C ../renesas-rz-linux-cip-dev M=$PWD modules
  cd $START_DIR/renesas-rz-linux-cip-dev
done
echo "Done building modules, installing to $MODULES_FOLDER"
ARCH=arm64  INSTALL_MOD_PATH=$MODULES_FOLDER make -j 24 modules_install
or MODULE in ${KERNEL_MODULES[@]}; do
  echo "Building module: $MODULE"
  cd $START_DIR/$MODULE
  ARCH=arm64  INSTALL_MOD_PATH=$MODULES_FOLDER make -C ../renesas-rz-linux-cip-dev M=$PWD modules_install
  cd $START_DIR/renesas-rz-linux-cip-dev
done
echo "Preparing kernel module deployment to $IP"
echo "Making tar of kernel modules"
rm  $MODULES_FOLDER/lib/modules/**/build
rm  $MODULES_FOLDER/lib/modules/**/source
tar -czf  /tmp/lib.tar.gz -C $MODULES_FOLDER lib
echo "Copying files to $IP"
scp -P $PORT -O /tmp/lib.tar.gz root@$IP:/tmp/
scp -P $PORT -O arch/arm64/boot/dts/renesas/*imdt*.dtb arch/arm64/boot/Image root@$IP:/boot/
ssh -p $PORT root@$IP "rm -Rf /lib/modules/5*/ && tar -xzf /tmp/lib.tar.gz -C / && sync"