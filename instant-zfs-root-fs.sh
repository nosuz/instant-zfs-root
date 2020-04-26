#!/bin/bash

# https://github.com/zfsonlinux/zfs/wiki/Ubuntu-16.04-Root-on-ZFS
# https://www.medo64.com/2019/04/installing-uefi-zfs-root-on-ubuntu-19-04/

#https://pve.proxmox.com/wiki/Booting_a_ZFS_root_file_system_via_UEFI
#https://wiki.archlinux.jp/index.php/GNU_Parted#UEFI.2FGPT_.E3.81.AE.E4.BE.8B

# http://sourceforge.net/projects/refind/files/
refind_ver='0.12.0'


# grant by ROOT is required
(( $EUID != 0 )) && exec sudo "$0" "$@"

single_fs=0

# define usage
usage(){
    cat <<EOF_HELP
-s  Single ZFS filesystem. /(root) and /home are placed
    on the same filesystem.

-y  Accept all program's default values. No interaction.

specify ZFS drives:
	-- drive1 drive2

EOF_HELP
}

while getopts "hs" opt; do
    case "$opt" in
	h)
	    usage
	    ;;
	s)
	    single_fs=1
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
	subvol="Ubuntu"
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
if (( ${#zfs_drives[@]} == 0 )); then
    while read drive; do
	drives+=(${drive##/dev/})
    done < <(ls /dev/sd[a-z] /dev/nvme[0-9]n[0-9]|grep -v $root_drive)
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

echo -n "Last chance. Are you sure? [yes/NO]"
read answer
if [[ $answer =~ ^[Yy][Ee][Ss]$ ]]; then
    echo "make ZFS root on /dev/${drive[0]}"
else
    echo "Cancelled"
    exit
fi

apt update
# install packges if some are missing
apt install -y zfsutils-linux zfs-initramfs gdisk zip
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

# detroy existing ZFS pool
zpool destroy tank

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
rsync --info=progress2 -a --exclude=/home /mnt/ /tank/$subvol/root
umount /mnt

# create home directory
mkdir /tank/$subvol/root/home
chmod 755 /tank/$subvol/root/home

echo "Copying /home to /tank/ROOT/home."
if (( $single_fs == 1 )); then
    rsync --info=progress2 -a /home/ /tank/$subvol/root/home
else
    rsync --info=progress2 -a /home/ /tank/$subvol/home
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

    mkdir /tmp/root/boot/efi_${drive} || true
    mount /dev/${efi} /tmp/root/boot/efi_${drive}

    mkdir -p /tmp/root/boot/efi_${drive}/efi/boot

    cp -r refind-bin-${refind_ver}/refind/* /tmp/root/boot/efi_${drive}/efi/boot/
    cp refind-bin-${refind_ver}/refind/refind_x64.efi /tmp/root/boot/efi_${drive}/efi/boot/bootx64.efi

    cp /tmp/root/boot/initrd.img-$kernel /tmp/root/boot/efi_${drive}/
    cp /tmp/root/boot/vmlinuz-$kernel /tmp/root/boot/efi_${drive}/

    cp /tmp/refind.conf /tmp/root/boot/efi_${drive}/efi/boot/refind.conf

    umount /tmp/root/boot/efi_${drive}

    uuid=$(blkid -o value -s UUID /dev/${efi})
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
