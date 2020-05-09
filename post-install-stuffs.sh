#!/bin/bash

# grant by ROOT is required
(( $EUID != 0 )) && exec sudo "$0" "$@"

# https://qiita.com/koara-local/items/2d67c0964188bba39e29
SCRIPT_DIR=$(cd $(dirname $0); pwd)

# cancel autorun on reboot
#crontab -l | sed -e "/^@reboot $SCRIPT_DIR\//s/^/#/"| awk '!a[$0]++' | crontab -
crontab -l | perl -pe "s{^(\@reboot $SCRIPT_DIR/)}{#\1}" | awk '!a[$0]++' | crontab -

swapoff -a

cp $SCRIPT_DIR/update-efi.sh /boot

cat << EOF > /etc/systemd/system/update-efi.service
[Unit]
# Execute command before shutdown/reboot [duplicate]
# https://askubuntu.com/questions/416299/execute-command-before-shutdown-reboot
Description=Copy latest kernel to EFI patitions and update refind.conf

[Service]
Type=oneshot
RemainAfterExit=true
ExecStart=/bin/true
ExecStop=/boot/update-efi.sh

[Install]
WantedBy=multi-user.target
EOF

systemctl enable update-efi
systemctl start update-efi
