#!/bin/bash
export PATH=$PATH:/usr/sbin:/sbin

format='+%Y%m%d_%H%M'
now=$(date $format)
prev=""

while getopts "dh" opt; do
    case $opt in
        d)
            format='+%Y%m%d'
            now=$(date $format)
            prev=$(date $format --date '1 day ago')
        ;;
        h)
            format='+%Y%m%d_%H%M'
            now=$(date $format)
            prev=$(date $format --date '1 hour ago')
        ;;
    esac
done

sleep $((RANDOM % 20))

for pool in $(zpool list -H -o health,name | awk '{if ($1 == "ONLINE") print $2}'); do
    if [[ -z $prev ]]; then
        zfs snapshot -r ${pool}@${now}
    else
        zfs snapshot -r ${pool}@cron_${now}
        if (( $(zfs list -t snap | grep ${pool}@cron_${prev} | wc -l) > 0 )); then
            zfs destroy -r ${pool}@cron_${prev}
        fi
    fi
done
