#!/bin/bash

# https://github.com/zfsonlinux/zfs/wiki/Ubuntu-16.04-Root-on-ZFS
# https://www.medo64.com/2019/04/installing-uefi-zfs-root-on-ubuntu-19-04/

#https://pve.proxmox.com/wiki/Booting_a_ZFS_root_file_system_via_UEFI
#https://wiki.archlinux.jp/index.php/GNU_Parted#UEFI.2FGPT_.E3.81.AE.E4.BE.8B

# http://sourceforge.net/projects/refind/files/
refind_ver='0.12.0'

# ZFS default pool name
zfs_pool='tank'
altroot='/tmp/root'

# grant by ROOT is required
(( $EUID != 0 )) && exec sudo "$0" "$@"

# https://qiita.com/koara-local/items/2d67c0964188bba39e29
SCRIPT_DIR=$(cd $(dirname $0); pwd)

single_fs=0
no_interact=0
do_reboot=0

# define usage
usage(){
    cat <<EOF_HELP
-p  pool_name
    specify pool name

-R
    Reboot automatically when prepared ZFS root filesystem.

-s
    Single ZFS filesystem. /(root) and /home are placed
    on the same filesystem.

-y
    Skip editing /etc/fstab file.

specify ZFS drives:
	-- drive1 drive2

EOF_HELP
}

while getopts "hp:Rsy" opt; do
    case "$opt" in
	h)
	    usage
	    ;;
	p)
	    zfs_pool=$OPTARG
	    ;;
	R)
	    do_reboot=1
	    ;;
	s)
	    single_fs=1
	    ;;
	y)
	    no_interact=1
	    ;;
    esac
done

# https://blog.sleeplessbeastie.eu/2019/08/19/how-to-specify-the-same-option-multiple-times-using-bash/

# shift options/arguments list
shift $(($OPTIND - 1))
echo $OPTIND

# parse additional arguments
zfs_drives=()
while [ "$#" -gt "0" ]; do
    dev=$(basename $1)
    if [[ -b /dev/$dev ]]; then
	zfs_drives+=($dev)
    fi
    shift
done

# get Ubuntu Release
distri=$(lsb_release -i | awk '{print $3}')
release=$(lsb_release -r | awk '{print $2}')
case "$distri" in
    "Ubuntu")
	subvol="UBUNTU"
	case "$release" in
	    19.04)
		:
		;;
	    19.10)
		:
		;;
	    20.04)
		:
		;;
	    *)
		echo Ubuntu $release is not supported by this script.
		exit
		;;
	esac
	;;
    "LinuxMint")
	subvol="MINT"
	case "$release" in
	    19.3)
		:
		;;
	    *)
		echo Linux mint $release is not supported by this script.
		exit
		;;
	esac
	;;
    *)
	echo $distri is not supported by this script.
	exit
	;;
esac


arch=$(uname -m)
if [[ $arch != x86_64 ]]; then
    echo ZFS is available only on 64-bit OS.
    exit
fi

# get target drive
root_drive=$(mount | grep ' / ' | awk '{print $1}' | sed -e 's/[0-9]$//')

drives=()
if (( ${#zfs_drives[@]} == 0 )); then
    while read drive; do
	drives+=(${drive##/dev/})
    done < <(ls /dev/sd[a-z] /dev/nvme[0-9]n[0-9] 2> /dev/null |grep -v $root_drive)
else
    for drive in ${zfs_drives[@]}; do
	drives+=($drive)
    done
fi
if (( ${#drives[@]} == 0 )); then
    echo No drives for ZFS
    exit
elif (( ${#drives[@]} > 4 )); then
    echo Too many drives: ${#drives[@]}
    exit
else
    echo Found ${#drives[@]} drives
fi

lsblk
cat <<EOF_DRIVE_HEADER

-*-*-*-*-*-*--*-*-*-*-*-*--*-*-*-*-*-*--*-*-*-*-*-*-
ALL data in next drive are DESTROYED and patitioned as follows.

EOF_DRIVE_HEADER

targets=()
for drive in ${drives[@]}; do
    case "$drive" in
	sd*)
	    cat <<EOF_DRIVE
${drive}
  ${drive}1 UEFI
  ${drive}2 ZFS pool
EOF_DRIVE
	    targets+=(${drive}2)
	    ;;
	nvme*)
	    cat <<EOF_DRIVE
${drive}
  ${drive}p1 UEFI
  ${drive}p2 ZFS pool
EOF_DRIVE
	    targets+=(${drive}p2)
	    ;;
	*)
	    cat <<EOF_DRIVE
${drive}
  ${drive}1 UEFI
  ${drive}2 ZFS pool
EOF_DRIVE
	    targets+=(${drive}2)
	    ;;
    esac
done

cat <<EOF_DRIVE_FOOTER

-*-*-*-*-*-*--*-*-*-*-*-*--*-*-*-*-*-*--*-*-*-*-*-*-

EOF_DRIVE_FOOTER

case "${#drives[@]}" in
    1)
	zpool_type="Single drive pool"
	zpool_target="${targets[@]}"
	;;
    2)
	zpool_type="Mirror pool"
	zpool_target="mirror ${targets[@]}"
	;;
    3)
	zpool_type="RAIDZ pool"
	zpool_target="raidz ${targets[@]}"
	;;
    4)
	zpool_type="RAIDZ2 pool"
	zpool_target="raidz2 ${targets[@]}"
	;;
esac

echo Make $zpool_type
echo Make $zpool_target

echo -n "Last chance. Are you sure? [yes/NO] "
read answer
if [[ $answer =~ ^[Yy][Ee][Ss]$ ]]; then
    echo "make ZFS root on /dev/${drive[0]}"
else
    echo "Cancelled"
    exit
fi

apt update
# install packges if some are missing
apt install -y zfsutils-linux zfs-initramfs gdisk zip efibootmgr
apt remove -y cryptsetup-initramfs

if [[ -d refind-bin-${refind_ver} ]]; then
    rm -rf refind-bin-${refind_ver}
fi

if [[ ! -e refind-bin-${refind_ver}.zip ]] ; then
    wget -q -O refind-bin-${refind_ver}.zip https://sourceforge.net/projects/refind/files/${refind_ver}/refind-bin-${refind_ver}.zip/download

    if [[ -s refind-bin-${refind_ver}.zip ]] ; then
	echo Got refind-bin-${refind_ver}.zip
    else
	echo Failed to download refind-bin-${refind_ver}.zip
	exit
    fi
fi
unzip refind-bin-${refind_ver}.zip > /dev/null

# install udev rules
# make link to the member of ZFS in /dev
if [[ ! -e /etc/udev/rules.d/91-zfs-vdev.rules ]] ; then
        cat > /etc/udev/rules.d/91-zfs-vdev.rules <<EOF_UDEV
# HOWTO install Ubuntu 14.04 or Later to a Native ZFS Root Filesystem
# https://github.com/zfsonlinux/pkg-zfs/wiki/HOWTO-install-Ubuntu-14.04-or-Later
-to-a-Native-ZFS-Root-Filesystem

# Create a by-id style link in /dev for zfs_member vdev. Needed by boot
KERNEL=="sd*[0-9]|nvme[0-9]n[0-9]p[0-9]", ENV{ID_FS_TYPE}=="zfs_member", SYMLINK+="disk/zfs/\$env{ID_BUS}-\$env{ID_SERIAL}-part%n"
EOF_UDEV
fi

# apply udev rules and make symlinks for ZFS drives
udevadm control --reload
udevadm trigger

# detroy existing ZFS pool
zpool destroy $zfs_pool

# setup GPT on target drive
for drive in ${drives[@]}; do
    case "$drive" in
	sd*)
	    efi="${drive}1"
	    ;;
	nvme*)
	    efi="${drive}p1"
	    ;;
	*)
	    efi="${drive}1"
	    ;;
    esac

    sgdisk --zap-all /dev/$drive
    sgdisk --clear /dev/$drive
    sgdisk --new=1:1M:+512M --typecode=1:EF00 /dev/$drive

    sgdisk -n 2:0:0 -t 2:8300 /dev/$drive # Linux Filesystem
    # All same size drives have same number of sectors?
    # I am not sure. ZFS dones not accept smaller dirves for replace.
    # create 1G smaller partition
    #sgdisk -n 2:0:-1G -t 2:8300 /dev/$drive # Linux Filesystem

    # create EFI boot partition
    mkdosfs -F 32 -s 1 -n EFI /dev/${efi}
    #mkfs.vfat -F 32 -s 1 -n EFI /dev/${efi}

    gdisk -l /dev/$drive
done

[[ -e $altroot ]] && rm -rf $altroot
mkdir $altroot

# create ZFS pool
# all ZFS features are enabled by default
zpool create -R $altroot -f -o ashift=12 -o autoexpand=on -O atime=off $zfs_pool ${zpool_target}

# make subvolume for /(root)
zfs create -o mountpoint=none $zfs_pool/$subvol
zfs create -o mountpoint=/ $zfs_pool/$subvol/root
if (( $single_fs != 1 )); then
    # make subvolume for /home and copy on it.
    zfs create -o mountpoint=/home $zfs_pool/$subvol/home
fi
zfs set mountpoint=none $zfs_pool

# convert name from sdX to drive ID
zpool export $zfs_pool
sleep 5 # wait to come up dist/zfs

[[ -e $altroot ]] && rm -rf $altroot
mkdir $altroot
echo Made fresh $altroot

zpool import -R $altroot -d /dev/disk/zfs $zfs_pool
zpool status

zfs list

# create update-refind.sh from template
sed -e "s/__ZFS_POOL__/$zfs_pool/" $SCRIPT_DIR/update-refind_template.sh > $SCRIPT_DIR/update-refind.sh
chmod +x $SCRIPT_DIR/update-refind.sh

# run post install script at the next boot.
crontab -l | (cat ; echo "@reboot $SCRIPT_DIR/post-install-stuffs.sh";) | crontab -

# copy system files
echo ""
echo "Copying / to $altroot. This takes for a few minutes."
rsync --info=progress2 -ax --exclude=/home --exclude=$altroot --exclude=/tmp / $altroot

# cancel autorun on reboot
crontab -l | sed -e "/^@reboot $SCRIPT_DIR\// s/^/#/"| awk '!a[$0]++' | crontab -

echo "Copying /home to $altroot/home."
rsync --info=progress2 -a /home/ $altroot/home

# comment out all
sed -i.orig -e '/^#/!s/^/\#/' $altroot/etc/fstab
echo LABEL=EFI /boot/efi vfat defaults 0 0 >> $altroot/etc/fstab

if (( $no_interact != 1 )); then
    # edit /etc/fstab
    nano $altroot/etc/fstab
fi

# remove zpool.cache to accept zpool struct change
rm $altroot/etc/zfs/zpool.cache

# update initiramfs
for d in proc sys dev;do
    echo "mount $d"
    mount --rbind /$d $altroot/$d
done

chroot $altroot update-initramfs -u -k all

for d in proc sys dev;do
    echo "unmount $d"
    umount -lfR $altroot/$d
done

kernel=$(uname -r)
cat > /tmp/refind.conf <<EOF_CONF
timeout 10
icons_dir EFI/boot/icons/
scanfor manual
scan_all_linux_kernels false

menuentry "Ubuntu ZFS" {
    ostype Linux
    graphics on
    loader /vmlinuz-${kernel}
    initrd /initrd.img-${kernel}
    options "ro root=ZFS=$zfs_pool/$subvol/root"
}
EOF_CONF

echo $kernel > $altroot/boot/prev_release.txt

cat /tmp/refind.conf

if [[ ! -e /tmp/efi ]]; then
    mkdir /tmp/efi
fi
for drive in ${drives[@]}; do
    case "$drive" in
	sd*)
	    efi="${drive}1"
	    ;;
	nvme*)
	    efi="${drive}p1"
	    ;;
	*)
	    efi="${drive}1"
	    ;;
    esac

    mount /dev/${efi} /tmp/efi

    mkdir -p /tmp/efi/efi/boot

    cp -r refind-bin-${refind_ver}/refind/* /tmp/efi/efi/boot/
    cp refind-bin-${refind_ver}/refind/refind_x64.efi /tmp/efi/efi/boot/bootx64.efi

    cp $altroot/boot/initrd.img-$kernel /tmp/efi/
    cp $altroot/boot/vmlinuz-$kernel /tmp/efi/

    cp /tmp/refind.conf /tmp/efi/efi/boot/

    umount /tmp/efi
done

zpool export $zfs_pool

# setup EFI boot order
for (( i=${#drives[@]}-1; i>=0; i--)); do
    serial=$(lsblk -dno MODEL,SERIAL /dev/${drives[i]} | sed -e 's/ \+/_/g')
    efibootmgr -c -d /dev/${drives[i]} -p 1 -l '\efi\boot\bootx64.efi' -L "$distri ZFS $serial"
done

# show final message
echo Finished.
if (( $do_reboot == 1 )); then
    reboot
else
    echo -n "Reboot now? [yes/NO] "
    read answer
    if [[ $answer =~ ^[Yy][Ee][Ss]$ ]]; then
	reboot
    fi
fi
