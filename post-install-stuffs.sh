#!/bin/bash

# grant by ROOT is required
(( $EUID != 0 )) && exec sudo "$0" "$@"

export PATH=$PATH:/usr/sbin:/sbin

# https://stackoverflow.com/questions/28195805/running-notify-send-as-root
function notify-send() {
    # return if not graphical
    (( $(ls /tmp/.X11-unix/ | wc -l) == 0 )) && return

    #Detect the name of the display in use
    local display=":$(ls /tmp/.X11-unix/* | sed 's#/tmp/.X11-unix/X##' | head -n 1)"

    #Detect the user using such display
    local user=$(who | grep '('$display')' | awk '{print $1}' | head -n 1)
    [[ -z $user ]] && return

    #Detect the id of the user
    local uid=$(id -u $user)

    sudo -u $user DISPLAY=$display DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$uid/bus notify-send "$@"
}

# https://qiita.com/koara-local/items/2d67c0964188bba39e29
SCRIPT_DIR=$(cd $(dirname $0); pwd)

# redirect STDOUT and STDERR to logfile
exec &>> $SCRIPT_DIR/post-install.log
echo Start post install jobs.

zfs_pool=""
if (( $# > 0 )); then
    zfs_pool=$1
else
    echo No required options.
    exit
fi

swapoff -a

cp $SCRIPT_DIR/update-efi.sh /boot

cat << EOF > /etc/systemd/system/update-efi.service
[Unit]
# Execute command before shutdown/reboot [duplicate]
# https://askubuntu.com/questions/416299/execute-command-before-shutdown-reboot
Description=Copy latest kernel to EFI patitions.

[Service]
Type=oneshot
RemainAfterExit=true
ExecStart=/bin/true
ExecStop=/boot/update-efi.sh

[Install]
WantedBy=multi-user.target
EOF

systemctl enable update-efi
systemctl start update-efi

mkdir -p /root/bin
cp $SCRIPT_DIR/trim-zfs-pools.sh /root/bin
crontab -l | (cat ; echo "@monthly /root/bin/trim-zfs-pools.sh";) | crontab -

# install backup script
cp $SCRIPT_DIR/backup/regist-backup.sh /root/bin/
cp $SCRIPT_DIR/backup/backup-zfs.sh /root/bin/

# cancel autorun on reboot
systemctl disable post-install-stuffs
rm /etc/systemd/system/post-install-stuffs.service

# take initial snapshot
zfs snapshot -r $zfs_pool@init
zfs list -t snap

notify-send "Post install jobs" "Finished."
echo Finished post install jobs.
