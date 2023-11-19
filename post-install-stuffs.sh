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
