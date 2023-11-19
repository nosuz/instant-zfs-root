#!/bin/bash

tmpdir="/tmp/refind"
if [[ -e $tmpdir ]]; then
    rm -rf $tmpdir
fi

mkdir $tmpdir
cd $tmpdir

mountpoint="$tmpdir/mnt"
mkdir $mountpoint

wget -q -O refind-latest.zip https://sourceforge.net/projects/refind/files/latest/download
unzip -qq -d refind-bin refind-latest.zip

# https://www.rodsbooks.com/refind/installing.html#linux
mv refind-bin/*/refind .
rm -rf refind-bin
# optional
# remove useless binary and drivers
ls -d refind/* | grep -vE '_x64|icons' | xargs rm -rf
# make default boot loader
cp refind/refind_x64.efi refind/bootx64.efi

cp /boot/efi/EFI/boot/refind.conf refind

#rsync -avn --delete refind/ /boot/efi/EFI/boot
rsync -av refind/ /boot/efi/EFI/boot
