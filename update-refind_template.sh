#!/bin/bash

# grant by ROOT is required
(( $EUID != 0 )) && exec sudo "$0" "$@"

exec 1>> /var/log/update-refind.log 2>&1

cd /boot

echo ----------------
date

kernel=$(ls -v vmlinuz-* | tail -n 1)
echo $kernel

initrd="initrd.img-${kernel#vmlinuz-}"
echo $initrd

rsync -av --modify-window=1 --delete --filter='+ vmlinuz-*' --filter='+ initrd.img-*' --filter='- *' /boot/ /boot/efi

if [[ -f /boot/efi/efi/boot/refind.conf ]]; then
    refind=$(stat -c %Y /boot/efi/efi/boot/refind.conf 2> /dev/null || echo 0)

    boot_kernel=$(stat -c %Y $kernel)
    boot_initrd=$(stat -c %Y $initrd)

    update=false
    if (( $boot_kernel > $refind )) || (( $boot_initrd > $refind )); then
	update=true
	mv /boot/efi/efi/boot/refind.conf /boot/efi/efi/boot/refind.conf.bak
    fi
else
    update=true
fi

if $update; then
    echo "Update refind.conf"
    if [[ -e /boot/prev_release.txt ]]; then
	prev_rel=$(cat /boot/prev_release.txt)
    else
	prev_rel=$(uname -r)
    fi

    cat << EOF > /boot/efi/efi/boot/refind.conf
timeout 5
icons_dir EFI/boot/icons/
scanfor manual
scan_all_linux_kernels false

menuentry "Ubuntu ZFS" {
    ostype Linux
    graphics on
    loader /$kernel
    initrd /$initrd
    options "ro root=ZFS=__ZFS_POOL__/UBUNTU/root"
    submenu "boot $prev_rel" {
        loader /vmlinuz-${prev_rel}
        initrd /initrd.img-${prev_rel}
    }
}

EOF

    uname -r > /boot/prev_release.txt
fi


if [[ -e /tmp/efi ]]; then
    rm -rf tmp/efi
fi
mkdir /tmp/efi

efi_uuid=$(lsblk -o MOUNTPOINT,UUID | grep '^/boot/efi ' | awk -e '{print $2}')
for uuid in $(lsblk -o LABEL,UUID|grep '^EFI '|awk -e '{print $2}'); do
    if [[ $efi_uuid = $uuid ]]; then
	echo current EFI partition: $efi_uuid
	continue
    else
	echo mount $uuid
    fi

    # mount EFI partition
    mount UUID=$uuid /tmp/efi
    if [[ ! -e /tmp/efi/efi/boot/refind.conf ]]; then
	echo $uuid is not refind bootable partition.
	umount /tmp/efi
	continue
    fi

    # sync files in EFI patition.
    rsync -av --delete --modify-window=1 /boot/efi/ /tmp/efi

    umount /tmp/efi
done
