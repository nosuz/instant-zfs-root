#!/bin/bash

export PATH=$PATH:/usr/sbin:/sbin

efi_phy_path=$(findmnt -o SOURCE -n /boot/efi)
grep "$efi_phy_path " /proc/mounts |grep '[, ]ro[, ]' > /dev/null
if (( ! $?)); then
    # mounted as RO
    cat << EOF

--- EFI mount ERROR ---
$efi_phy_path is mounted as RO. There might be inconsistency.
Fix it followed by the next commands. Or you will fail to update kernel.

umount /boot/efi
dosfsck -w -a -t $efi_phy_path
mount $efi_phy_path /boot/efi

EOF

XDG_RUNTIME_DIR=/run/user/$(id -u) notify-send -u critical 'EFI mounted as RO' "$efi_phy_path is mounted as RO."

fi