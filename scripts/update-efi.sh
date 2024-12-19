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

efi_phy_path=$(findmnt -o SOURCE -n /boot/efi)
grep "$efi_phy_path " /proc/mounts |grep '[, ]ro[, ]' > /dev/null
if (( $? )); then
# mounted as rw
    # test not blocked: workaround
    dummy_file=$(date -u +'/boot/efi/%Y%m%d_%H%M%S.tmp')
    dd bs=1k count=1024 if=/dev/random of=${dummy_file}

    # keep only latest and previous kernels
    rsync -av --copy-links --delete --delete-before \
        --filter='+ vmlinuz' \
        --filter='+ initrd.img' \
        --filter='+ vmlinuz.old' \
        --filter='+ initrd.img.old' \
        --filter='- *' \
        --modify-window=1 \
        /boot/ /boot/efi/EFI/${distri,,}

    # revert bootx64 to refind
    if [[ -e efi/EFI/boot/refind_x64.efi ]]; then
        cmp -s efi/EFI/boot/refind_x64.efi efi/EFI/boot/bootx64.efi
        if (( $? )) ; then
            echo "bootx64.efi is missing or over writen. copy refindx64 over bootx64."
            cp efi/EFI/boot/refind_x64.efi efi/EFI/boot/bootx64.efi
        fi
    fi

    # remove dummy file
    rm ${dummy_file}
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
