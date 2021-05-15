## Mount Backup pool

```
zpool import -N pool_name

# alternative root
zpool import -R /mnt pool_name
```

## For restore all from backup.

Restore with a specified snapshot.

```
zfs destroy -r main
zfs send -wpR backup/main/DIST@snap | pv | zfs recv -Fue main
```

or each dataset

```
zfs destroy -r main/DIST/data
zfs send -wp backup/main/DIST/data@snap | pv | zfs recv -Fue main/DIST
```

zfs send

- -w Send raw dataset.
- -p Send properties. ex. mount points.

zfs recv

- -F Rollback to the latest snapshot if exists.
- -u Not mount until the next boot.
- -e Use last element as a name of dataset.

Set a mount point.

```
zfs set mountpoint=/mnt/path pool_name/dataset
```
