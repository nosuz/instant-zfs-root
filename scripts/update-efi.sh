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
if (( $?)); then
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

efi_id=$(ls /boot | grep EFIid)

if [[ -e /tmp/efi ]]; then
    rm -rf /tmp/efi
fi
mkdir /tmp/efi

efi_uuid=$(lsblk -n -o UUID $efi_phy_path)
for uuid in $(lsblk -o LABEL,UUID | awk '{if ($1 == "EFI") print $2}'); do
    if [[ $efi_uuid = $uuid ]]; then
        echo current EFI partition: $efi_uuid
        continue
    else
        echo mount $uuid
    fi

    # mount EFI partition
    mount UUID=$uuid /tmp/efi

    if [[ -e /tmp/efi/$efi_id ]]; then
        # same EFI group
        grep " /tmp/efi " /proc/mounts |grep '[, ]ro[, ]' > /dev/null
        if (($?)); then
            # mounted as rw
            if (( $updated )); then
                # sync files in EFI patition.
                # rsync -av --delete --delete-before --modify-window=1 /boot/efi/ /tmp/efi
                rsync -av --copy-links --delete --delete-before \
                    --filter='- *.old' \
                    --filter="- $kernel" \
                    --filter="- $initrd" \
                    --filter='+ vmlinuz*' \
                    --filter='+ initrd.img*' \
                    --filter='- *' \
                    --modify-window=1 \
                    /boot/ /tmp/efi/EFI/${distri,,}
            fi

            # revert bootx64 to refind
            if [[ -e /tmp/efi/EFI/boot/refind_x64.efi ]]; then
                cmp -s /tmp/efi/EFI/boot/refind_x64.efi /tmp/efi/EFI/boot/bootx64.efi
                if (( $? )) ; then
                    echo "bootx64.efi in $uuid is missing or over writen. copy refindx64 over bootx64."
                    cp /tmp/efi/EFI/boot/refind_x64.efi /tmp/efi/EFI/boot/bootx64.efi
                fi
            fi
        else
            # mounted as ro
            tmp_phy_path=$(findmnt -o SOURCE -n /tmp/efi)
            cat << EOF
$uuid is mounted on /tmp/efi as RO. There might be inconsistency.
Fix it followed by the next commands.

dosfsck -w -a -t $tmp_phy_path
mount UUID=$uuid /tmp/efi
EOF
        fi
    else
        echo This EFI partition belongs to another system.
    fi

    umount /tmp/efi
done

echo Done.
