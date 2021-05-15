# How to replace broken drives

```
$ zpool status -x

  pool: pool
 state: DEGRADED
status: One or more devices has experienced an unrecoverable error.  An
	attempt was made to correct the error.  Applications are unaffected.
action: Determine if the device needs to be replaced, and clear the errors
	using 'zpool clear' or replace the device with 'zpool replace'.
   see: http://zfsonlinux.org/msg/ZFS-8000-9P
  scan: scrub repaired 0B in 0 days 00:00:20 with 0 errors on Sat May 15 00:06:43 2021
config:

	NAME                                  STATE     READ WRITE CKSUM
	pool                                  DEGRADED     0     0     0
	  raidz2-0                            DEGRADED     0     0     0
	    ata-WDC_WD10EADS-00L5B1-part2     ONLINE       0     0     0
	    ata-WDC_WD5000AAKX-001CA0-part2   DEGRADED     X     X     X  too many errors
	    ata-WDC_WD5000AAKX-001CA0-part2   ONLINE       0     0     0
	    ata-WDC_WD5000AAKX-00ERMA0-part2  ONLINE       0     0     0

errors: No known data errors

# replace-zfs-drive.sh is in /root/bin
$ sudo replace-zfs-drive.sh sdb
```

This last command creates a EFI patition at the top of sdb drive and the remaining space will be ZFS.
Then it will copy curent EFI contents into the new EFI partion and run replacing broken ZFS drive with this new one.
