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

if [[ ! -e /tmp/efi ]]; then
    mkdir /tmp/efi
fi
for uuid in $(lsblk -o LABEL,UUID|grep '^EFI '|awk -e '{print $2}'); do
    echo $uuid

    # mount EFI partition
    mount UUID=$uuid /tmp/efi

    update=false
    src=$(stat -c %Y $kernel)
    dst=$(stat -c %Y /tmp/efi/$kernel 2> /dev/null || echo 0)
    if (( $src > $dst )); then
	cp $kernel /tmp/efi
	update=true
    fi

    # remove purged kernel
    for installed in $(ls /tmp/efi/vmlinuz-*); do
	if [[ ! -e $(basename $installed) ]]; then
	    rm $installed
	    echo "Removed $installed"
	fi
    done

    src=$(stat -c %Y $initrd)
    dst=$(stat -c %Y /tmp/efi/$initrd 2> /dev/null || echo 0)
    if (( $src > $dst )); then
	cp $initrd /tmp/efi
	update=true
    fi

    # remove purged initrd
    for installed in $(ls /tmp/efi/initrd.img-*); do
	if [[ ! -e $(basename $installed) ]]; then
	    rm $installed
	    echo "Removed $installed"
	fi
    done

    if $update; then
	echo "Update refind.conf"
	if [[ -f /tmp/efi/efi/boot/refind.conf ]]; then
	    mv /tmp/efi/efi/boot/refind.conf /tmp/efi/efi/boot/refind.conf.bak
	fi

	cat << EOF > /tmp/efi/efi/boot/refind.conf
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
}

EOF
    fi

    umount /tmp/efi
done
