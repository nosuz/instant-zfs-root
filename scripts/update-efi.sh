#!/bin/bash

# grant by ROOT is required
(( $EUID != 0 )) && exec sudo "$0" "$@"

export PATH=$PATH:/usr/sbin:/sbin
# redirect STDOUT and STDERR to logfile
exec &>> /var/log/update-efi.log

cd /boot

distri=$(lsb_release -i | awk '{print $3}')
echo --- update EFI ---
date

kernel=$(ls -v vmlinuz-* | tail -n 1)
initrd="initrd.img-${kernel#vmlinuz-}"

# set 1 if updated any files.
updated=0

cmp -s $kernel efi/EFI/${distri,,}/vmlinuz
if (( $? )); then
    echo "update vmlinux to $kernel"
    ln -sf $kernel vmlinuz
    updated=1
fi

cmp -s $initrd efi/EFI/${distri,,}/initrd.img
if (( $? )); then
    echo "update initrd to $initrd"
    ln -sf $initrd initrd.img
    updated=1
fi

efi_phy_path=$(findmnt -o SOURCE -n /boot/efi)
grep "$efi_phy_path " /proc/mounts |grep '[, ]ro[, ]' > /dev/null
if (( $? )); then
# mounted as rw
    if (( $updated )); then
        rsync -av --copy-links --delete --delete-before \
            --filter='- *.old' \
            --filter="- $kernel" \
            --filter="- $initrd" \
            --filter='+ vmlinuz*' \
            --filter='+ initrd.img*' \
            --filter='- *' \
            --modify-window=1 \
            /boot/ /boot/efi/EFI/${distri,,}
    else
        echo No kernel updated.
    fi

    # revert bootx64 to refind
    if [[ -e efi/EFI/boot/refind_x64.efi ]]; then
        cmp -s efi/EFI/boot/refind_x64.efi efi/EFI/boot/bootx64.efi
        if (( $? )) ; then
            echo "bootx64.efi is missing or over writen. copy refindx64 over bootx64."
            cp efi/EFI/boot/refind_x64.efi efi/EFI/boot/bootx64.efi
        fi
    fi
else
# mounted as ro
cat << EOF
$efi_phy_path is mounted as RO. There might be inconsistency.
Fix it followed by the next commands.

umount /boot/efi
dosfsck -w -a -t $efi_phy_path
mount $efi_phy_path /boot/efi
EOF
fi

echo Done.
