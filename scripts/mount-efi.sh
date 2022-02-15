#!/bin/bash

# grant by ROOT is required
(( $EUID != 0 )) && exec sudo "$0" "$@"

export PATH=$PATH:/usr/sbin:/sbin
# redirect STDOUT and STDERR to logfile
exec &>> /var/log/update-efi.log

echo --- mount EFI ---
date

efi_id=$(ls /boot | grep EFIid)

efi_uuid=$(lsblk -n -o UUID $(findmnt -o SOURCE -n /boot/efi))
for uuid in $(lsblk -o LABEL,UUID | awk '{if ($1 == "EFI") print $2}'); do
    if [[ $efi_uuid = $uuid ]]; then
        echo current EFI partition: $efi_uuid
        continue
    else
        echo mount $uuid
    fi

    # mount EFI partition
    mount UUID=$uuid /boot/efi

    if [[ -e /boot/efi/$efi_id ]]; then
        echo This is our EFI partition.
        break
    else
        echo another system EFI partition and unmount this.
        umount /boot/efi
    fi
done

# check permit
efi_phy_path=$(findmnt -o SOURCE -n /boot/efi)
grep "$efi_phy_path " /proc/mounts |grep '[, ]ro[, ]' > /dev/null
if (( ! $?)); then
    cat << "EOF"
$efi_phy_path is mounted as RO. There might be inconsistency.
Fix it followed by the next commands.

umount /boot/efi
dosfsck -w -a -t $efi_phy_path
mount $efi_phy_path /boot/efi
EOF
else
    echo Mounted $efi_phy_path on /boot/efi properly.
fi

echo Done.
