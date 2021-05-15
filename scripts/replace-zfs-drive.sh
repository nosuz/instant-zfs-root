#!/bin/bash

# grant by ROOT is required
(( $EUID != 0 )) && exec sudo "$0" "$@"

if (( $# == 0 )); then
    echo Usage: $(basename $0) new_drive
    echo "    Replace ZFS drive, DEGRADED or UNAVAIL, with new drive."
    exit
fi

new_storage=""
dev=$(basename $1)
if [[ -e /dev/disk/by_id/$dev ]]; then
    dev=$(readlink /dev/disk/by_id/$dev)
    new_storage=$(basename $dev)
elif [[ -b /dev/$dev ]]; then
    new_storage=$dev
fi

broken_pool=$(zpool list -H | grep -v ONLINE | awk -e '{print $1}' | tail -1)
if [[ $broken_pool == "" ]]; then
    echo No degraded pool.
    exit
fi

lsblk | grep $new_storage

echo "Drive $new_storage is formatted and get into a ZFS member of $broken_pool."
echo -n "Are you sure to? [yes/NO] "
read answer
if [[ $answer =~ ^[Yy][Ee][Ss]$ ]]; then
    echo
else
    echo "Cancelled"
    exit
fi

zpool labelclear -f /dev/$new_storage
case "$new_storage" in
    [sv]d*)
        efi="${new_storage}1"
        zfs="${new_storage}2"
        ;;
    nvme*)
        efi="${new_storage}p1"
        zfs="${new_storage}p2"
        ;;
    *)
        efi="${new_storage}1"
        zfs="${new_storage}2"
        ;;
esac

sgdisk --zap-all /dev/$new_storage
sgdisk --clear /dev/$new_storage
sgdisk --new=1:1M:+512M \
        --typecode=1:EF00 \
        --change-name=1:EFI \
        /dev/$new_storage

sgdisk -n 2:0:0 \
        -t 2:8300 \
        -c 2:ZFS \
        /dev/$new_storage # Linux Filesystem

# create EFI boot partition
mkdosfs -F 32 -s 1 -n EFI /dev/${efi}
#mkfs.vfat -F 32 -s 1 -n EFI /dev/${efi}

sgdisk -p /dev/$new_storage

# duplicate EFI partition
mkdir /tmp/mnt_$$
mount /dev/${efi} /tmp/mnt_$$

rsync -a /boot/efi/ /tmp/mnt_$$

umount /tmp/mnt_$$
rmdir /tmp/mnt_$$

# make symlinks for ZFS drives
udevadm trigger

target_storage=""
retries=0
while [[ $target_storage == "" ]]; do
    if (( $retries > 3 )); then
        echo Too many retries.
        exit
    fi
    let retries++

    sleep 2 # wait to come up dist/zfs
    target_storage=$(ls -l /dev/disk/zfs |grep $zfs | awk '{print $9}')
done

echo $target_storage
source_storage=$(zpool status -x $broken_pool | grep -e DEGRADED -e UNAVAIL -e REMOVED -e FAULTED |  awk '{print $1}' |tail -1)

# replace broken drive
echo "Wait a moment to start replacing"
zpool replace $broken_pool $source_storage $target_storage

zpool status $broken_pool
