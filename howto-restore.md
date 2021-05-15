## Mount Backup pool

```
zpool import -N pool_name

# alternative root
zpool import -R /mnt pool_name
```

## For restore all from backup.

```
zfs destroy -r main
zfs send -wR backup/main/DIST@snap | pv | zfs recv -Fue main
```

or each dataset

```
zfs destroy -r main/DIST/data
zfs send -w backup/main/DIST/data@snap | pv | zfs recv -Fue main/DIST
```
