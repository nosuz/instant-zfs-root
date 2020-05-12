#!/bin/bash

for pool in $(zpool list -H -o health,name | awk '{if ($1 == "ONLINE") print $2}'); do
    zpool trim $pool
done
