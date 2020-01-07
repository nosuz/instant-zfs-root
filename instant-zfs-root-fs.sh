#!/bin/bash

# https://github.com/zfsonlinux/zfs/wiki/Ubuntu-16.04-Root-on-ZFS
# https://www.medo64.com/2019/04/installing-uefi-zfs-root-on-ubuntu-19-04/

#https://pve.proxmox.com/wiki/Booting_a_ZFS_root_file_system_via_UEFI
#https://wiki.archlinux.jp/index.php/GNU_Parted#UEFI.2FGPT_.E3.81.AE.E4.BE.8B
refind_ver='0.11.4'


# grant by ROOT is required
(( $EUID != 0 )) && exec sudo "$0" "$@"

single_fs=0

while getopts "hs" opt; do
    case "$opt" in
	h)
	    cat <<EOF_HELP
-s            Single ZFS filesystem. /(root) and /home are placed
              on the same filesystem.

-y            Accept all program's default values. No interaction.

EOF_HELP
	    ;;
	s)
	    single_fs=1 
	    ;;
    esac
done

# get Ubuntu Release
distri=$(lsb_release -i | awk '{print $3}')
release=$(lsb_release -r | awk '{print $2}')
case "$distri" in
    "Ubuntu")
	subvol="Ubuntu"
	case "$release" in
	    19.04)
		:
		;;
	    19.10)
		:
		;;
	    *)
		echo Ubuntu $release is not supported by this script.
		exit
		;;
	esac
	;;
    "LinuxMint")
	subvol="Mint"
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
while read drive; do
    drives+=(${drive##/dev/})
done < <(ls /dev/sd[a-z]|grep -v $root_drive)
if (( ${#drives[@]} == 0 )); then
    echo No drives for ZFS
    exit
elif (( ${#drives[@]} > 4 )); then
    echo Too many drives: ${#drives[@]}
    exit
else
    echo Found ${#drives[@]} drives
fi

case "${#drives[@]}" in
    1)
	zpool_type="Single drive pool"
	zpool_target="${drives[0]}2"
	;;
    2)
	zpool_type="Mirror pool"
	zpool_target="mirror ${drives[0]}2 ${drives[1]}2"
	;;
    3)
	zpool_type="RAIDZ pool"
	zpool_target="raidz ${drives[0]}2 ${drives[1]}2 ${drives[2]}2"
	;;
    4)
	zpool_type="RAIDZ2 pool"
	zpool_target="raidz2 ${drives[0]}2 ${drives[1]}2 ${drives[2]}2 ${drives[3]}2"
	;;
esac

lsblk
cat <<EOF_DRIVE_HEADER

-*-*-*-*-*-*--*-*-*-*-*-*--*-*-*-*-*-*--*-*-*-*-*-*-
ALL data in next drive are DESTROYED and patitioned as follows.

EOF_DRIVE_HEADER

for drive in ${drives[@]}; do
    cat <<EOF_DRIVE
${drive}
  ${drive}1 UEFI
  ${drive}2 ZFS pool
EOF_DRIVE
done

cat <<EOF_DRIVE_FOOTER

-*-*-*-*-*-*--*-*-*-*-*-*--*-*-*-*-*-*--*-*-*-*-*-*-

EOF_DRIVE_FOOTER

echo Make $zpool_type

echo -n "Last chance. Are you sure? [yes/NO]"
read answer
if [[ $answer =~ ^[Yy][Ee][Ss]$ ]]; then
    echo "make ZFS root on /dev/${drive[0]}"
else
    echo "Cancelled"
    exit
fi

# install packges if some are missing
apt install -y zfsutils-linux zfs-initramfs gdisk zip
apt remove -y cryptsetup-initramfs

if [[ -d refind-bin-${refind_ver} ]]; then
    rm -rf refind-bin-${refind_ver}
fi

if [[ ! -e refind-bin-${refind_ver}.zip ]] ; then
    wget -q -O refind-bin-${refind_ver}.zip https://sourceforge.net/projects/refind/files/0.11.4/refind-bin-${refind_ver}.zip/download

    if [[ -s refind-bin-${refind_ver}.zip ]] ; then
	echo Got refind-bin-${refind_ver}.zip
    else
	echo Failed to download refind-bin-${refind_ver}.zip
	exit
    fi
fi
unzip refind-bin-${refind_ver}.zip

# install udev rules
# make link to the member of ZFS in /dev
if [[ ! -e /etc/udev/rules.d/90-zfs-vdev.rules ]] ; then
        cat > /etc/udev/rules.d/90-zfs-vdev.rules <<EOF_UDEV
# HOWTO install Ubuntu 14.04 or Later to a Native ZFS Root Filesystem
# https://github.com/zfsonlinux/pkg-zfs/wiki/HOWTO-install-Ubuntu-14.04-or-Later
-to-a-Native-ZFS-Root-Filesystem

# Create by-id links in /dev as well for zfs vdev. Needed by grub
# Force ata_id for USB disks
KERNEL=="sd*[!0-9]", SUBSYSTEMS=="usb", IMPORT{program}="ata_id --export \$devno
de"
# Force ata_id when ID_VENDOR=ATA
KERNEL=="sd*[!0-9]", ENV{ID_VENDOR}=="ATA", IMPORT{program}="ata_id --export \$devnode"
# Add links for zfs_member only
KERNEL=="sd*[0-9]", IMPORT{parent}=="ID_*", ENV{ID_FS_TYPE}=="zfs_member", SYMLINK+="\$env{ID_BUS}-\$env{ID_SERIAL}-part%n"
EOF_UDEV
fi

# destroy existing ZFS pool
zpool destroy tank

# setup GPT on target drive
for drive in ${drives[@]}; do
    sgdisk --zap-all /dev/$drive
    sgdisk --clear /dev/$drive
    sgdisk --new=1:1M:+512M --typecode=1:EF00 /dev/$drive

    sgdisk -n 2:0:0 -t 2:8300 /dev/$drive # Linux Filesystem
    # All same size drives have same number of sectors?
    # I am not sure. ZFS dones not accept smaller dirves for replace.
    # create 1G smaller partition
    #sgdisk -n 2:0:-1G -t 2:8300 /dev/$drive # Linux Filesystem

    # create EFI boot partition
    mkdosfs -F 32 -s 1 -n EFI /dev/${drive}1
    #mkfs.vfat -F32 /dev/${drive}1

    gdisk -l /dev/$drive
done

# create ZFS pool
# all ZFS features are enabled by default
zpool create -f -o ashift=12 -o autoexpand=on -O atime=off tank ${zpool_target}

# conver name from sdX to drive ID
zpool export tank
zpool import -d /dev/disk/by-id tank
zpool status

# make subvolume for /(root)
zfs create tank/$subvol
zfs create tank/$subvol/root
if (( $single_fs != 1 )); then
    # make subvolume for /home and copy on it.
    zfs create tank/$subvol/home
fi
zfs list

# copy system files
mount --bind / /mnt
echo ""
echo "Copying / to /tank/$subvol/root. This takes for a few minutes."
rsync --progress -a --exclude=/home /mnt/ /tank/$subvol/root
umount /mnt

# create home directory
mkdir /tank/$subvol/root/home
chmod 755 /tank/$subvol/root/home

echo "Copying /home to /tank/ROOT/home."
if (( $single_fs == 1 )); then
    rsync --progress -a /home/ /tank/$subvol/root/home
else
    rsync --progress -a /home/ /tank/$subvol/home
    zfs set mountpoint=/home tank/$subvol/home
fi

# edit /etc/fstab
sed -e '/^#/! s/^/#/' /tank/$subvol/root/etc/fstab > /tank/$subvol/root/etc/fstab.new
mv /tank/$subvol/root/etc/fstab.new /tank/$subvol/root/etc/fstab
# comment out all
#nano /tank/$subvol/root/etc/fstab

# remove zpool.cache to accept zpool struct change
rm /tank/$subvol/root/etc/zfs/zpool.cache

# update initiramfs
for d in proc sys dev;do
    echo "mount $d"
    mount --bind /$d /tank/$subvol/root/$d
done

mkdir /tank/$subvol/root/boot/efi || true
chroot /tank/$subvol/root update-initramfs -u -k all

for d in proc sys dev;do
    echo "unmount $d"
    umount /tank/$subvol/root/$d
done

# set mountpoint for root
zfs set mountpoint=/ tank/$subvol/root
zfs set mountpoint=none tank/$subvol
zfs set mountpoint=none tank

mkdir /tmp/root
mount -t zfs -o zfsutil tank/$subvol/root /tmp/root

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
    options "root=ZFS=tank/$subvol/root quiet"
}
EOF_CONF

nano /tmp/refind.conf

for drive in ${drives[@]}; do
    mkdir /tmp/root/boot/efi_${drive} || true
    mount /dev/${drive}1 /tmp/root/boot/efi_${drive}

    mkdir -p /tmp/root/boot/efi_${drive}/efi/boot

    cp -r refind-bin-${refind_ver}/refind/* /tmp/root/boot/efi_${drive}/efi/boot/
    cp refind-bin-${refind_ver}/refind/refind_x64.efi /tmp/root/boot/efi_${drive}/efi/boot/bootx64.efi

    cp /tmp/root/boot/initrd.img-$kernel /tmp/root/boot/efi_${drive}/
    cp /tmp/root/boot/vmlinuz-$kernel /tmp/root/boot/efi_${drive}/

    cp /tmp/refind.conf /tmp/root/boot/efi_${drive}/efi/boot/refind.conf

    umount /tmp/root/boot/efi_${drive}

    uuid=$(blkid -o value -s UUID /dev/${drive}1)
    echo UUID=$uuid /boot/efi_$drive vfat defaults 0 0 >> /tmp/root/etc/fstab
done

# show final message
cat <<EOF_MSG1

-*-*-*-*-*-*--*-*-*-*-*-*--*-*-*-*-*-*--*-*-*-*-*-*-

Finised

Next:
 1. Shutdown system.
 2. Remove current root fs drive.
 3. Reboot
EOF_MSG1

if [[ ! -e /sys/firmware/efi ]]; then
    echo "      Make sure to boot from UEFI. This system didn't boot from UEFI."
fi

cat <<EOF_MSG2
 4. (Optional) Run post-install-stuffs.sh to remobe GRUB and install update-refind service.

-*-*-*-*-*-*--*-*-*-*-*-*--*-*-*-*-*-*--*-*-*-*-*-*-
EOF_MSG2
