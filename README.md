# Introduction
This repository provides a script for building common out of tree kernel modules for the IMDT V2 SBC as well as the kernel so that you can work on these repositories outside of yocto.

##  Instructions
You will need to copy the following kernel module repositories into this folder:
1. kernel-module-mali - required by graphics feature
2. kernel-module-mmngrbuf   
3. kernel-module-udmabuf - required by drpai feature
4. kernel-module-vspm
5. kernel-module-vspmif
6. kernel-module-uvcs-drv - required by codecs feature

Its recommend that you obtain these folders from using devtool modify within Yocto and then pushing them to a git server.

You will also need a copy of the kernel in the following folder:

renesas-rz-linux-cip-dev

# Building
To build and deploy the kernel modules plus DTB and Image, you can use the script like the following:
```bash
./rz.sh
```

This assumes your IMDT V2 SBC is connected to 172.16.30.100 (ETH0)
If you wish to use a different IP address or port you can provide the following arguments:
```bash
./rz.sh $IP $PORT
```
