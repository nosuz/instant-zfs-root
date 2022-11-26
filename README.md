# ZFS as root file system

Linux のルートファイルシステムを ZFS にするためのスクリプトです。Ubuntu 　 Desktop では、root on ZFS が既にサポートされていますが、Ubuntu の Server 版や他のディストリビューションではまだサポートされていません。このスクリプトは、既存のルートファイルシステムを ZFS に置き換えます。

このスクリプトでルート・ファイルシステムを ZFS にするためには、現在のシステムの使用容量より大きな容量のディスクを追加する必要があります。ディスク自体の容量ではなく、使用済みの容量よりも大きければ問題ありません。試用期間が長くなると一般的に使用容量が大きくなるので、私は USB メモリにシステムをインストールしてから、このスクリプトを使ってメインの SSD や HDD に ZFS のルート・ファイルシステムを作成しています。

### サポートするディストリビューション

- Ubuntu
- LinuxMint
- open.Yellow.os

多分ディストリビューションの判断部分を書き換えれば Debian も問題ないと思います。

### RAID

- Mirroring pool (RAID1 相当)
- RAIDZ (RAID5 相当)
- RAIDZ2 (RAID6 相当)

接続されているドライブ数で RAID が選択されます。その他にコマンドオプションで指定することも可能です。

| Boot 以外のドライブ数 | RAID   |
| :-------------------: | ------ |
|           1           | Single |
|           2           | Mirror |
|           3           | RAIDZ  |
|           4           | RAIDZ2 |

### Boot Loader

デフォルトでは、kernel を直接起動します。

オプションで指定することで、Boot Loader に[rEFInd](https://www.rodsbooks.com/refind/)と GRUB を選択できます。オプションを指定しない場合にも、障害が発生したときのために rEFInd がインストールされます。

KVM の場合は、BootMgr の内容を書き換えられないかもしれません。

### 使用方法

```
# Show options
$ ./instant-zfs-root-fs.sh -h

# Install
$ ./instant-zfs-root-fs.sh

```
