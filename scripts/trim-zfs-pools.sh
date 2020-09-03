#!/bin/bash
export PATH=$PATH:/usr/sbin:/sbin

# redirect STDOUT and STDERR to logfile
exec &>> /var/log/trim-zfs-pool.log

echo ----------------
date

for pool in $(zpool list -H -o health,name | awk '{if ($1 == "ONLINE") print $2}'); do
    echo trim $pool
    zpool trim $pool
done
