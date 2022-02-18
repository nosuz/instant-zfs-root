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

distri=$(lsb_release -i | awk '{print $3}')

zfs_pool=""
if (( $# > 0 )); then
    zfs_pool=$1
else
    echo No required options.
    exit
fi

cp $SCRIPT_DIR/scripts/mount-efi.sh /boot

# https://www.golinuxcloud.com/run-script-at-startup-boot-without-cron-linux/
cat << EOF > /etc/systemd/system/mount-efi.service
[Unit]
# Execute command after reboot
Description=Mount EFI partition.
After=default.target

[Service]
Type=simple
RemainAfterExit=no
ExecStart=/boot/mount-efi.sh
TimeoutStartSec=0

[Install]
WantedBy=default.target
EOF

systemctl enable mount-efi
systemctl start mount-efi

sleep 5

cp $SCRIPT_DIR/scripts/update-efi.sh /boot

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
cp $SCRIPT_DIR/scripts/trim-zfs-pools.sh /root/bin
crontab -l | (cat ; echo "@monthly /root/bin/trim-zfs-pools.sh";) | crontab -
cp $SCRIPT_DIR/scripts/zfs-snapshot.sh /root/bin
crontab -l | \
    (cat ; echo "@daily /root/bin/zfs-snapshot.sh -d";) | \
    (cat ; echo "@hourly /root/bin/zfs-snapshot.sh -h";) | \
    crontab -

# copy other utils.
cp $SCRIPT_DIR/scripts/replace-zfs-drive.sh /root/bin

# install EFI mout check program
cp $SCRIPT_DIR/scripts/notify-efi-mount-error.sh /boot
cat << EOF >> /etc/profile

# check EFI is mouted as RW
/boot/notify-efi-mount-error.sh

EOF

cat << EOF > /etc/xdg/autostart/mount-efi.desktop
[Desktop Entry]
Type=Application
Name=My Script
Exec=/boot/notify-efi-mount-error.sh
Icon=system-run
X-GNOME-Autostart-enabled=true
EOF

# install backup script
cp $SCRIPT_DIR/backup/regist-backup.sh /root/bin/
cp $SCRIPT_DIR/backup/watch-backup.sh /root/bin/
cp $SCRIPT_DIR/backup/backup-zfs.sh /root/bin/
if [[ -e $SCRIPT_DIR/backup-skip.list ]]; then
    cp $SCRIPT_DIR/backup-skip.list /root/bin/
fi
zfs list -H|awk '{if ($1 ~ /\/swap$/) { print $1}}' >> /root/bin/backup-skip.list

# cancel autorun on reboot
systemctl disable post-install-stuffs
rm /etc/systemd/system/post-install-stuffs.service

# take initial snapshot
zfs snapshot -r $zfs_pool@init
if (( $(zfs list -H $zfs_pool/${distri^^}/swap 2> /dev/null | wc -l) != 0)); then
    zfs destroy $zfs_pool/${distri^^}/swap@init
fi
zfs list -t all

notify-send "Post install jobs" "Finished."
echo Finished post install jobs.
