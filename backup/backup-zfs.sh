#!/bin/bash

# grant by ROOT is required
(( $EUID != 0 )) && exec sudo "$0" "$@"

# https://forums.opensuse.org/showthread.php/485261-Script-run-from-udev-rule-gets-killed-shortly-after-start
main_pool=$(zfs list|awk 'match($5,"^/$") {sub(/\/.*/, "",$1); print $1}')
backup_pool=$1

now=$(date +%Y%m%d_%H%M)
script_name=$(basename $0)

function log() {
    echo "$@"
    # [[ $no_tty -eq 1 ]] && logger --tag $script_name "$@"

    return 0
}

# get lock
[[ $FLOCKER != $0 ]] && exec env FLOCKER=$0 flock --exclusive --nonblock "$0" "$0" "$@"

log "Backup start at $(date +'%F %R') $$"

zpool export $backup_pool
retries=0
while (( $(zpool list | grep -c "^$backup_pool ") != 0 )); do
    if (( $retries > 3 )); then
        log Too many retries.
        exit
    fi
    let retries++

    log retry to export $backup_pool
    sleep 2
    zpool export $backup_pool
done

zpool import -N $backup_pool
# wait to import
retries=0
while (( $(zpool list | grep -c "^$backup_pool ") == 0 )); do
    if (( $retries > 3 )); then
        log Too many retries.
        exit
    fi
    let retries++

    log wait to import $backup_pool
    sleep 2
done
log imported $backup_pool

function exec_finish() {
    log export $backup_pool
    zpool export $backup_pool
    retries=0
    while (( $(zpool list | grep -c "^$backup_pool ") != 0 )); do
        if (( $retries > 3 )); then
            log Too many retries.
	    log "Failed to export $backup_pool"
            exit
        fi
        let retries++

        log retry to export $backup_pool
        sleep 2
        zpool export $backup_pool
    done

    log Exported $backup_pool
    return 0
}

trap "exit" INT
trap "exec_finish" EXIT

log "Take snapshot @bak_$now"
# exit if already exist
zfs list -H -t snap | grep ${main_pool}@bak_$now > /dev/null && exit
zfs snap -r ${main_pool}@bak_$now
if (( $? != 0 )); then
    log "ERROR: failed to take snapshot @bak_$now"
    exit
fi

last_snap=$(zfs list -H -t snap|cut -f 1 | grep -e "^${main_pool}@bak_" -e "^${backup_pool}/${main_pool}@bak_"|sed -e "s/.*@//"| sort |uniq -d|tail -n 1)
if [[ $last_snap = "" ]]; then
    # full backup
    log "send full: ${main_pool}@bak_$now"
    send_opt=''
else
    # diff backup
    log "send diff: @$last_snap => ${backup_pool}@bak_$now"
    send_opt=" -I @$last_snap"
fi
log "zfs send $send_opt ${main_pool}@bak_$now|zfs recv -vuF ${backup_pool}/${main_pool}"
zfs send -R $send_opt ${main_pool}@bak_$now|zfs recv -vuF ${backup_pool}/${main_pool}
if (( $? != 0 )); then
    log "ERROR: failed to send-recv @bak_$now"
fi

log "Backup finished at $(date +'%F %R')"
