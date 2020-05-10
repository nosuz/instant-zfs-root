#!/bin/bash

# grant by ROOT is required
(( $EUID != 0 )) && exec sudo "$0" "$@"

exec 1>> /var/log/update-efi.log 2>&1

cd /boot

distri=$(lsb_release -i | awk '{print $3}')
echo ----------------
echo $distri
date

kernel=$(ls -v vmlinuz-* | tail -n 1)
echo $kernel

initrd="initrd.img-${kernel#vmlinuz-}"
echo $initrd

new=$(stat -c %Y $kernel)
boot=$(stat -c %Y efi/EFI/${distri,,}/vmlinuz)
diff=$(( $new - $boot ))

if (( $diff > 1 )); then
    echo "update vmlinux to $kernel \($diff sec\)"
    ln -sf $kernel vmlinuz
fi

new=$(stat -c %Y $initrd)
boot=$(stat -c %Y efi/EFI/${distri,,}/initrd.img)
diff=$(( $new - $boot ))

if (( $diff > 1 )); then
    echo "update initrd to $initrd \($diff sec\)"
    ln -sf $initrd initrd.img
fi

rsync -av --copy-links --delete --filter='+ vmlinuz*' --filter='+ initrd.img*' --filter='- *' --modify-window=1 /boot/ /boot/efi/EFI/${distri,,}

if [[ -e /tmp/efi ]]; then
    rm -rf /tmp/efi
fi
mkdir /tmp/efi

efi_uuid=$(lsblk -o MOUNTPOINT,UUID | awk -e '{if ($1 == "/boot/efi") print $2}')
for uuid in $(lsblk -o LABEL,UUID | awk -e '{if ($1 == "EFI") print $2}'); do
    if [[ $efi_uuid = $uuid ]]; then
	echo current EFI partition: $efi_uuid
	continue
    else
	echo mount $uuid
    fi

    # mount EFI partition
    mount UUID=$uuid /tmp/efi

    # sync files in EFI patition.
    rsync -a --delete --modify-window=1 /boot/efi/ /tmp/efi

    umount /tmp/efi
done
