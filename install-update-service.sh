#!/bin/bash

# grant by ROOT is required
(( $EUID != 0 )) && exec sudo "$0" "$@"

# https://qiita.com/koara-local/items/2d67c0964188bba39e29
SCRIPT_DIR=$(cd $(dirname $0); pwd)

cp $SCRIPT_DIR/update-refind.sh /boot

efis=$(ls -d /boot/efi_* | xargs)
cat << EOF > /etc/systemd/system/update-refind.service 
[Unit]
Description=Copy latest kernel to EFI patitions and update refind.conf
RequiresMountsFor=$efis
Before=shutdown.target reboot.target poweroff.target halt.target
DefaultDependencies=no

[Service]
Type=oneshot
ExecStart=/boot/update-refind.sh

[Install]
WantedBy=multi-user.target
EOF

systemctl enable update-refind
systemctl start update-refind
