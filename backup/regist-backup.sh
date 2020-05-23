#!/bin/bash

# grant by ROOT is required
(( $EUID != 0 )) && exec sudo "$0" "$@"

# https://qiita.com/koara-local/items/2d67c0964188bba39e29
SCRIPT_NAME=$(basename $0)
SCRIPT_DIR=$(cd $(dirname $0); pwd)

# define usage
usage(){
    cat <<EOF_HELP
Usage:
    $SCRIPT_NAME zfs_pool

EOF_HELP
}

if (( $(zpool list -H | grep -c "^${1}\s") == 1 )); then
    zfs_pool=$1
    zfs_path=$(zpool status -LP $zfs_pool | awk 'match($1, /^\/dev\//){print $1}'|tail -n 1)

    zfs_serial=$(udevadm info $zfs_path|awk 'match($2, /ID_SERIAL=/) {sub("ID_SERIAL=", "", $2); print $2}')
    zfs_uuid=$(udevadm info $zfs_path|awk 'match($2, /ID_PART_ENTRY_UUID=/) {sub("ID_PART_ENTRY_UUID=", "", $2); print $2}')
else
    echo No such pool: $1
    exit
fi

# install service
cat > /etc/systemd/system/backup-zfs2${zfs_pool}.service << EOF_SYSD
[Unit]
Description=Backup ZFS to $zfs_pool

[Service]
Type=simple
ExecStart=/root/bin/backup-zfs.sh $zfs_pool
EOF_SYSD

# install udev rules
cat >> /etc/udev/rules.d/99-backup-zfs.rules <<EOF_UDEV
# backup to $zfs_pool ($zfs_serial)
ACTION=="add",ENV{ID_PART_ENTRY_UUID}=="$zfs_uuid",RUN+="/bin/systemctl --no-block start backup-zfs2${zfs_pool}.service"

EOF_UDEV

# apply udev rules
udevadm control --reload

systemctl list-unit-files --type=service | grep backup-zfs

echo -n "Do you want to start backup now? [YES/no] "
read answer
if [[ $answer =~ ^[Nn][Oo]$ ]]; then
    zpool export $zfs_pool
    retries=0
    while (( $(zpool list -H | grep -c "^${zfs_pool}\s") != 0 )); do
        if (( $retries > 3 )); then
            echo Too many retries.
	    echo "Failed to export $zfs_pool"
            exit
        fi
        let retries++

        echo retry to export $zfs_pool
        sleep 2
        zpool export $zfs_pool
    done

    echo Exported $zfs_pool
    echo Remove backup pool and reconnet it to start backup process.
else
    echo "You can watch backup process by watch-backup.sh or nc -Ukl /tmp/backup"
    echo "Backup starts anytime the drive that have backup pool are connected."
    systemctl --no-block start backup-zfs2${zfs_pool}.service
fi
