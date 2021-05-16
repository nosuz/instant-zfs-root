#!/bin/bash
export PATH=$PATH:/usr/sbin:/sbin

num_snap=2 # number to keep snapshots.

prefix=""
format='+%Y%m%d_%H%M'
now=$(date $format)

while getopts "dh" opt; do
    case $opt in
        d)
            prefix="daily"
        ;;
        h)
            prefix="hourly"
        ;;
    esac
done

sleep $((RANDOM % 20))

for pool in $(zpool list -H -o health,name | awk '{if ($1 == "ONLINE") print $2}'); do
    if [[ -z $prefix ]]; then
        zfs snapshot -r ${pool}@${now}
    else
        zfs snapshot -r ${pool}@${prefix}_${now}
        for prev in $(zfs list -t snap | grep ${pool}@${prefix}_ | awk '{print $1}' | sort |head -n -${num_snap}); do
            zfs destroy -r $prev
        done
    fi
done
