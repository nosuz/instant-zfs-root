#!/bin/bash

# grant by ROOT is required
(( $EUID != 0 )) && exec sudo "$0" "$@"

exec 1>> /boot/update-refind.log 2>&1

echo ----------------
date

kernel_path=$(ls /boot/vmlinuz-* | sort -V | tail -n 1)
kernel=$(basename $kernel_path)
echo $kernel
src=$(stat -c %Y $kernel_path)

initrd="initrd.img-${kernel#vmlinuz-}"
echo $initrd

for efi in $(ls /boot | grep efi_); do
    echo $efi

    update=false
    dst=$(stat -c %Y /boot/$efi/$kernel || echo 0)
    if (( $src > $dst )); then
	cp /boot/$kernel /boot/$efi
	update=true
    fi

    dst=$(stat -c %Y /boot/$efi/$initrd || echo 0)
    if (( $src > $dst )); then
	cp /boot/$initrd /boot/$efi
	update=true
    fi

    if $update; then
	echo "Update refind.conf"
	if [[ -f /boot/$efi/efi/boot/refind.conf ]]; then
	    mv /boot/$efi/efi/boot/refind.conf /boot/$efi/efi/boot/refind.conf.bak
	fi

	cat << EOF > /boot/$efi/efi/boot/refind.conf
timeout 5
icons_dir EFI/boot/icons/
scanfor manual
scan_all_linux_kernels false

menuentry "Ubuntu ZFS" {
    ostype Linux
    graphics on
    loader /$kernel
    initrd /$initrd
    options "root=ZFS=tank/UBUNTU/root quiet"
}

EOF
    fi
done
