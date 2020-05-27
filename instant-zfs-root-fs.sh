#!/bin/bash

# https://github.com/zfsonlinux/zfs/wiki/Ubuntu-16.04-Root-on-ZFS
# https://www.medo64.com/2019/04/installing-uefi-zfs-root-on-ubuntu-19-04/

#https://pve.proxmox.com/wiki/Booting_a_ZFS_root_file_system_via_UEFI
#https://wiki.archlinux.jp/index.php/GNU_Parted#UEFI.2FGPT_.E3.81.AE.E4.BE.8B

# ZFS default pool name
zfs_pool='tank'
altroot='/tmp/root'

# http://sourceforge.net/projects/refind/files/
refind_ver='0.12.0'

# check booted from EFI
if [[ ! -d /sys/firmware/efi ]]; then
    echo -n "Does this machine support EFI boot? [yes/NO] "
    read answer
    if [[ ! $answer =~ ^[Yy][Ee][Ss]$ ]]; then
        echo This script requires EFI boot.
        exit
    fi
fi

# grant by ROOT is required
(( $EUID != 0 )) && exec sudo "$0" "$@"

# https://qiita.com/koara-local/items/2d67c0964188bba39e29
SCRIPT_NAME=$(basename $0)
SCRIPT_DIR=$(cd $(dirname $0); pwd)

single_fs=0
edit_fstab=0
do_reboot=0
encrypt_opts=""
encrypt_key=""
bootmng=""
bootmng_timeout=5
boot_opts="quiet splash"
grub_pkg=""
vdev=""
zfs_compress=1
zfs_encrypt=0
zpool_opts=()

# default swap size
ram_size=$(free --giga|awk '{if ($1 == "Mem:") print $2}')
zfs_swap=$(echo "sqrt($ram_size+1)"|bc)

# define usage
usage(){
    cat <<EOF_HELP
Usage:
    $SCRIPT_NAME [options] [zfs_drive]...

Options:
-b (grub|refind)
    Install boot manager. If this option was not set, the kernel will
    be directly loaded by EFI stub.

    If no boot manager was selected, the system boot kernel directory
    by EFI boot stub. And rEFInd is installed to keep bootable when
    NVRAM is cleared or moved to another machine.

-e keyfile_path
    Encrypt all file systems.

    If set / as key file, the file systems are encrypted by passphrase.

    If a keyfile_path is specified, it is used as encryption key
    file. Be care all contents are destroy and created a new patition
    table if keyfile_path was whole disk.

-f
    Stop to edit /etc/fstab file.

-p pool_name
    specify pool name

-R
    Reboot automatically when prepared ZFS root filesystem.

-s
    Single ZFS filesystem. /(root) and /home are placed
    on the same filesystem.

-t timeout_sec
    Specify timeout for boot managers.

-u
    Disable compression by LZ4.

-v
    Show messages while booting.

-z (single|stripe|mirror|raidz|raidz1|raidz2)
    Specify vdev to create.

ZFS properties
--autotrim
    Enable auto trim.

    On the zpool manual, enableing auto trim property puts significant
    stress on the strage devices. So, they recommend to run periodical
    zpool trim command for lower end devices.

--copies=(2|3)
    Set copies property on zpool. THis option might be rescue from
    some checksum errors. But this completeley DOES NOT protect from
    drive errors. Use a mirrored or RAID vdev for redundancy.

--snapdir
    Set snapdir visible.

--swap=SWAP_SIZE
    Set swap zvol size by gibibyte. If set 0, no swap volume.
    Default size is sqrt(RAM_SZIE + 1).

EOF_HELP
}

while getopts "b:e:fhp:Rst:uvz:-:" opt; do
    # https://chitoku.jp/programming/bash-getopts-long-options#--foobar-%E3%81%A8---foo-bar-%E3%81%AE%E4%B8%A1%E6%96%B9%E3%82%92%E5%87%A6%E7%90%86%E3%81%99%E3%82%8B%E6%96%B9%E6%B3%95
    optarg="$OPTARG"
    [[ "$opt" = - ]] &&
        opt="-${OPTARG%%=*}" &&
        optarg="${OPTARG/${OPTARG%%=*}/}" &&
        optarg="${optarg#=}"

    case "-$opt" in
        -b)
            case $optarg in
                grub)
                    bootmng="grub"
                    ;;
                refind)
                    bootmng="refind"
                    ;;
                *)
                    echo set grub or refind.
                    exit
                    ;;
            esac
            ;;
        -e)
            zfs_encrypt=1
            case $optarg in
                /)
                    ;;
                *)
                    if [[ -b $optarg ]]; then
                        encrypt_key=$optarg
                    else
                        echo No path for key file: $optarg
                        exit
                    fi
                    ;;
            esac
            ;;
        -f)
            edit_fstab=1
            ;;
        -h|-\?)
            usage
            exit
            ;;
        -p)
            zfs_pool=$optarg
            ;;
        -R)
            do_reboot=1
            ;;
        -s)
            single_fs=1
            ;;
        -t)
            if [[ $optarg =~ ^[0-9]+$ ]]; then
                bootmng_timeout=$optarg
            else
                echo Set integer for timeout.
                exit
            fi
            ;;
        -u)
            zfs_compress=0
            ;;
        -v)
            boot_opts=""
            ;;
        -z)
            case ${optarg,,} in
                single|stripe)
                    vdev="single"
                    ;;
                mirror)
                    vdev="mirror"
                    ;;
                raid|raid1)
                    vdev="raidz1"
                    ;;
                raid2)
                    vdev="raidz2"
                    ;;
                *)
                    echo unknow vdev name $optarg
                    exit
                    ;;
            esac
            ;;
	--copies)
            if [[ $optarg =~ ^(2|3)$ ]]; then
                zpool_opts+=("-O copies=$optarg")
            else
                echo copy number must be 1 to 3.
                exit
            fi
            ;;
        --autotrim)
            zpool_opts+=("-o autotrim=on")
            ;;
        --snapdir)
            zpool_opts+=("-O snapdir=visible")
            ;;
        --swap)
            if (( $optarg == 0 )); then
                zfs_swap=""
            elif [[ $optarg =~ ^[0-9]+$ ]]; then
                zfs_swap=$optarg
            else
                echo swap size must be ineger in gibibyte.
                exit
            fi
            ;;
    esac
done

# https://blog.sleeplessbeastie.eu/2019/08/19/how-to-specify-the-same-option-multiple-times-using-bash/

# shift options/arguments list
shift $(($OPTIND - 1))

if (( $zfs_compress == 1 )); then
    zpool_opts+=("-O compression=lz4")
fi

# parse additional arguments
zfs_drives=()
while (( $# > 0 )); do
    dev=$(basename $1)
    if [[ -e /dev/disk/by_id/$dev ]]; then
        dev=$(readlink /dev/disk/by_id/$dev)
        zfs_drives+=($(basename $dev))
    elif [[ -b /dev/$dev ]]; then
        zfs_drives+=($dev)
    fi
    shift
done

echo Check distribution
# get Release info.
distri=$(lsb_release -i | awk '{print $3}')
release=$(lsb_release -r | awk '{print $2}')
kernel_ver=$(uname -r)

case "$distri" in
    "Ubuntu")
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

# GRUB can't recognize not all ZFS features like encryption.
if [[ $bootmng == "grub" ]] && (( $zfs_encrypt == 1 )); then
    echo
    echo "Grub can't boot system on encrypted ZFS."
    echo Use the rEFInd boot manager or EFIstub.
    exit
fi

echo
echo Setup ZFS
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

if [[ -z $vdev ]]; then
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
else
    case $vdev in
        single)
            zpool_type="Single or striped drive pool"
            zpool_target="${targets[@]}"
            ;;
        mirror)
            if (( ${#drives[@]} < 2 )); then
                echo At least 2 drives are required.
                exit
            fi
            zpool_type="Mirror pool"
            zpool_target="mirror ${targets[@]}"
            ;;
        raid|raid1)
            if (( ${#drives[@]} < 3 )); then
                echo At least 3 drives are required.
                exit
            fi
            zpool_type="RAIDZ pool"
            zpool_target="raidz ${targets[@]}"
            ;;
        raid2)
            if (( ${#drives[@]} < 4 )); then
                echo At least 4 drives are required.
                exit
            fi
            zpool_type="RAIDZ2 pool"
            zpool_target="raidz2 ${targets[@]}"
            ;;
    esac
fi

echo Make $zpool_type
echo Make $zpool_target

echo -n "Last chance. Are you sure? [yes/NO] "
read answer
if [[ $answer =~ ^[Yy][Ee][Ss]$ ]]; then
    echo "make ZFS root on ${drives[@]}"
else
    echo "Cancelled"
    exit
fi

if (( $zfs_encrypt == 1 )); then
    if [[ -z $encrypt_key ]]; then
        encrypt_opts="-o encryption=aes-256-gcm -o keyformat=passphrase -o keylocation=prompt"
    else
        # https://github.com/openzfs/zfs/issues/6556
        # parted -s /dev/usbdevice mklabel gpt mkpart key 2048s 2048s
        # tr -d '\n' < /dev/urandom | dd of=/dev/disk/by-partlabel/key

        # check encryption key file is disk or partition
        echo
        echo Prepare encryption key file.
        type=$(lsblk -d -o TYPE $encrypt_key | tail -n 1)
        case $type in
            disk)
                key_file=/dev/disk/by-partlabel/zfs_key
                echo disk: $encrypt_key
                echo Are you sure to destroy or remove all contents in this disk?
                echo yes: Clear all contents in this disk and make encryotion key drive.
                echo NO: Keep every things and exit.
                echo -n "[yes/NO] "
                read answer
                if [[ $answer =~ ^[Yy][Ee][Ss]$ ]]; then
                    parted -s $encrypt_key mklabel gpt mkpart zfs_key 2048s 2048s
                    retries=0
                    while [[ ! -e $key_file ]]; do
                        if (( $retries > 3 )); then
                            echo Too many retries.
                            exit
                        fi
                        let retries++

                        echo waiting key file.
                        sleep 2
                    done
                    tr -d '\n' < /dev/urandom | dd bs=512 count=1 of=$key_file
                else
                    exit
                fi
                ;;
            part)
                echo partition: $encrypt_key
                echo Do you want to make a new key in this partition?
                echo yes: Create new encryption key.
                echo NO: Use current content as encryption key.
                echo -n "[yes/NO] "
                read answer
                if [[ $answer =~ ^[Yy][Ee][Ss]$ ]]; then
                    (tr -d '\n' < /dev/urandom | dd bs=512 count=1; echo "") > $encrypt_key
                fi
                key_file=$encrypt_key
                ;;
            *)
                echo unknow type $type for $encrypt_key
                exit
                ;;
        esac
        encrypt_opts="-o encryption=aes-256-gcm -o keyformat=passphrase -o keylocation=file://$key_file"
    fi
    echo $encrypt_opts
fi

echo
echo Install pakcages.
apt update
if (( $? != 0 )); then
    echo Failed to update packages information.
    exit
fi
# install packges if some are missing
if [[ $bootmng == "grub" ]]; then
    grub_pkg="grub-efi-amd64-signed shim-signed"
fi
apt install -y zfsutils-linux zfs-initramfs gdisk efibootmgr $grub_pkg
if (( $? != 0 )); then
    echo Failed to install required packages.
    exit
fi

echo
echo Install udev rule.
# install udev rules
# make link to the member of ZFS in /dev
if [[ ! -e /etc/udev/rules.d/91-zfs-vdev.rules ]] ; then
        cat > /etc/udev/rules.d/91-zfs-vdev.rules <<EOF_UDEV
# HOWTO install Ubuntu 14.04 or Later to a Native ZFS Root Filesystem
# https://github.com/zfsonlinux/pkg-zfs/wiki/HOWTO-install-Ubuntu-14.04-or-Later-to-a-Native-ZFS-Root-Filesystem

# Create a by-id style link in /dev for zfs_member vdev. Needed by boot
KERNEL=="sd*[0-9]", ENV{ID_FS_TYPE}=="zfs_member", SYMLINK+="disk/zfs/\$env{ID_BUS}-\$env{ID_SERIAL}-part%n"
KERNEL=="nvme[0-9]n[0-9]p[0-9]", ENV{ID_FS_TYPE}=="zfs_member", SYMLINK+="disk/zfs/nvme-\$env{ID_SERIAL}-part%n"
EOF_UDEV
fi

# apply udev rules
udevadm control --reload

echo
echo Setup GPT
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
    sgdisk --new=1:1M:+512M \
           --typecode=1:EF00 \
           --change-name=1:EFI \
           /dev/$drive

    sgdisk -n 2:0:0 \
           -t 2:8300 \
           -c 2:ZFS \
           /dev/$drive # Linux Filesystem
    # All same size drives have same number of sectors?
    # I am not sure. ZFS dones not accept smaller dirves for replace.
    # create 1G smaller partition
    #sgdisk -n 2:0:-1G -t 2:8300 /dev/$drive # Linux Filesystem

    # create EFI boot partition
    mkdosfs -F 32 -s 1 -n EFI /dev/${efi}
    #mkfs.vfat -F 32 -s 1 -n EFI /dev/${efi}

    sgdisk -p /dev/$drive
done

[[ -e $altroot ]] && rm -rf $altroot
mkdir $altroot

echo
echo Create zpool
echo ${zpool_opts[@]}
# create ZFS pool
# all ZFS features are enabled by default
zpool create -R $altroot -f \
      -o ashift=12 -o autoexpand=on \
      -O atime=off -O canmount=off -O mountpoint=none \
      ${zpool_opts[@]} \
      $zfs_pool ${zpool_target}

echo
echo Create zfs
# make top subvolume
# https://www.reddit.com/r/zfs/comments/bnvdco/zol_080_encryption_dont_encrypt_the_pool_root/
zfs create \
    -o canmount=off \
    -o mountpoint=none \
    $encrypt_opts $zfs_pool/${distri^^}

# make subvolume for /(root)
zfs create \
    -o mountpoint=/ \
    $zfs_pool/${distri^^}/root
if (( $single_fs != 1 )); then
    # make subvolume for /home and copy on it.
    zfs create \
        -o mountpoint=/home \
        $zfs_pool/${distri^^}/home
fi

if [[ -n $zfs_swap ]]; then
    # https://github.com/zfsonlinux/pkg-zfs/wiki/HOWTO-use-a-zvol-as-a-swap-device
    zfs create \
        -V ${zfs_swap}G \
        -b $(getconf PAGESIZE) \
        -o logbias=throughput \
        -o compression=off \
        -o sync=always \
        -o primarycache=metadata \
        -o secondarycache=none \
        -o com.sun:auto-snapshot=false \
        $zfs_pool/${distri^^}/swap
fi

zpool status
zfs list

echo
echo Make post installation script entry in systemd.
# https://www.golinuxcloud.com/run-script-at-startup-boot-without-cron-linux/
# run post install script at the next boot.
cat << EOF > /etc/systemd/system/post-install-stuffs.service
[Unit]
# Execute command after reboot
Description=Do post reboot job for ZFS root.
After=default.target

[Service]
Type=simple
RemainAfterExit=no
ExecStart=$SCRIPT_DIR/post-install-stuffs.sh $zfs_pool
TimeoutStartSec=0

[Install]
WantedBy=default.target
EOF

systemctl enable post-install-stuffs

# copy system files
echo ""
echo "Copying / to $altroot. This takes for a few minutes."
rsync --info=progress2 -ax --exclude=/home --exclude=$altroot --exclude=/tmp --exclude=/swapfile --exclude=/swap.img / $altroot

# cancel autorun on reboot
systemctl disable post-install-stuffs
rm /etc/systemd/system/post-install-stuffs.service

echo "Copying /home to $altroot/home."
rsync --info=progress2 -a /home/ $altroot/home

echo
echo Edit /etc/fstab
# comment out all
sed -i.orig -e '/^#/!s/^/\#/' $altroot/etc/fstab
echo LABEL=EFI /boot/efi vfat defaults 0 0 >> $altroot/etc/fstab

if [[ -n $zfs_swap ]]; then
    mkswap -f /dev/zvol/$zfs_pool/${distri^^}/swap
    echo  "/dev/zvol/$zfs_pool/${distri^^}/swap none swap sw 0 0" >> $altroot/etc/fstab
fi

if (( $edit_fstab == 1 )); then
    # edit /etc/fstab
    nano $altroot/etc/fstab
fi

# remove zpool.cache to accept zpool struct change
if [[ -e $altroot/etc/zfs/zpool.cache ]]; then
    rm $altroot/etc/zfs/zpool.cache
fi

echo
echo Update initrd
# update initramfs
# mount /run to avoid next warnings.
# WARNING: Device /dev/XXX not initialized in udev database even after waiting 10000000 microseconds.
for d in proc sys dev run;do
    echo "mount $d"
    mount --rbind /$d $altroot/$d
done

chroot $altroot update-initramfs -u -k $kernel_ver

# make simlinks to the current kernel and initrd
pushd . > /dev/null
cd $altroot/boot
ln -sf vmlinuz-$kernel_ver vmlinuz
ln -sf initrd.img-$kernel_ver initrd.img
popd > /dev/null

if [[ $bootmng == "grub" ]]; then
    echo
    echo Install GRUB
    if [[ -e $altroot/etc/default/grub ]]; then
        mv $altroot/etc/default/grub $altroot/etc/default/grub.orig
    fi
    cat > $altroot/etc/default/grub <<EOF_GRUB
GRUB_DEFAULT=0
#GRUB_TIMEOUT_STYLE=hidden
GRUB_TIMEOUT=$bootmng_timeout
GRUB_RECORDFAIL_TIMEOUT=$bootmng_timeout
GRUB_DISTRIBUTOR=`lsb_release -i -s 2> /dev/null || echo Debian`
GRUB_CMDLINE_LINUX_DEFAULT="$boot_opts"
GRUB_CMDLINE_LINUX=""
GRUB_TERMINAL=console
EOF_GRUB
    cat $altroot/etc/default/grub

    if [[ ! -d $altroot/tmp ]]; then
        mkdir $altroot/tmp
    fi
    mount -t tmpfs tmpfs $altroot/tmp

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

        if [[ ! -d $altroot/boot/efi ]]; then
            mkdir -p $altroot/boot/efi
        fi
        mount /dev/${efi} $altroot/boot/efi
        if [[ ! -d $altroot/boot/efi/EFI/${distri,,} ]]; then
            mkdir -p $altroot/boot/efi/EFI/${distri,,}
        fi

        rsync -a --copy-links --filter='- *.old' --filter='+ vmlinuz*' --filter='+ initrd.img*' --filter='- *' $altroot/boot/ $altroot/boot/efi/EFI/${distri,,}

        echo
        echo Install Grub to $drive
        chroot $altroot update-grub
        chroot $altroot grub-install \
               --efi-directory=/boot/efi \
               --bootloader-id=${distri,,} \
               --recheck --no-floppy

        umount $altroot/boot/efi
    done

    umount $altroot/tmp

    for drive in ${drives[@]}; do
        # Grub-install make only one boot entry.
        # Install endividual boot entry.
        serial=$(lsblk -dno MODEL,SERIAL /dev/$drive | sed -e 's/ \+/_/g')
        echo Make boot entry for $drive $serial
        efibootmgr -c -d /dev/$drive -p 1 \
                   -l '/EFI/ubuntu/shimx64.efi' \
                   -L "$distri ZFS $serial"
    done
fi

for d in proc sys dev run;do
    echo "unmount $d"
    umount -lfR $altroot/$d
done

if [[ $bootmng != "grub" ]]; then
    # download rEFInd
    echo
    echo Install rEFInd.
    apt install -y zip

    if [[ ! -d refind-bin-${refind_ver} ]]; then
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
    fi

    # https://www.rodsbooks.com/refind/installing.html#linux
    mv refind-bin-${refind_ver}/refind .
    # optional
    # remove useless binary and drivers
    ls -d refind/* | grep -vE '_x64|icons' | xargs rm -rf

    # set refind_x64 as default boot loader
    mv refind/refind_x64.efi refind/bootx64.efi

    cat > refind/refind.conf <<EOF_CONF
timeout $bootmng_timeout
icons_dir EFI/boot/icons/
scanfor manual
scan_all_linux_kernels false

menuentry "$distri ZFS" {
    graphics on
    ostype Linux
    loader /EFI/${distri,,}/vmlinuz
    initrd /EFI/${distri,,}/initrd.img
    options "ro root=ZFS=$zfs_pool/${distri^^}/root $boot_opts"
}
EOF_CONF
    cat refind/refind.conf

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
        mkdir -p /tmp/efi/EFI/${distri,,}

        rsync -a --copy-links --filter='- *.old' --filter='+ vmlinuz*' --filter='+ initrd.img*' --filter='- *' $altroot/boot/ /tmp/efi/EFI/${distri,,}

        # install rEFInd
        cp -pr refind/. /tmp/efi/EFI/boot

        # add EFI boot entry
        serial=$(lsblk -dno MODEL,SERIAL /dev/$drive | sed -e 's/ \+/_/g')
        if [[ $bootmng == "refind" ]]; then
            efibootmgr -c -d /dev/$drive -p 1 -l '/EFI/boot/bootx64.efi' -L "rEFInd $serial"
        else
            efibootmgr -c -d /dev/$drive -p 1 -l "/EFI/${distri,,}/vmlinuz" -L "$distri ZFS $serial" -u "ro root=ZFS=$zfs_pool/${distri^^}/root initrd=/EFI/${distri,,}/initrd.img $boot_opts"
        fi
        umount /tmp/efi
    done
fi

# make symlinks for ZFS drives
udevadm trigger

retries=0
while [[ ! -e /dev/disk/zfs ]] || (( $(ls /dev/disk/zfs | wc -l) != ${#drives[@]} )); do
    if (( $retries > 3 )); then
        echo Too many retries.
        exit
    fi
    let retries++

    echo waiting ZFS vol come up in /dev/disk/zfs
    sleep 2 # wait to come up dist/zfs
done

# convert name from sdX to drive ID
zpool export $zfs_pool
retries=0
while (( $(zpool list -H | grep -c "^${zfs_pool}\s") != 0 )); do
    if (( $retries > 3 )); then
        echo Too many retries.
        exit
    fi
    let retries++

    echo retry to export $zfs_pool
    sleep 2
    zpool export $zfs_pool
done
zpool import -R $altroot -d /dev/disk/zfs $zfs_pool
zpool status

zpool export $zfs_pool
retries=0
while (( $(zpool list -H | grep -c "^${zfs_pool}\s") != 0 )); do
    if (( $retries > 3 )); then
        echo Too many retries.
        exit
    fi
    let retries++

    echo retry to export $zfs_pool
    sleep 2
    zpool export $zfs_pool
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
