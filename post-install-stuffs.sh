#!/bin/bash

# grant by ROOT is required
(( $EUID != 0 )) && exec sudo "$0" "$@"

# https://qiita.com/koara-local/items/2d67c0964188bba39e29
SCRIPT_DIR=$(cd $(dirname $0); pwd)

# cancel autorun on reboot
#crontab -l | sed -e "/^@reboot $SCRIPT_DIR\//s/^/#/"| awk '!a[$0]++' | crontab -
crontab -l | ruby -pe "sub(/^/, '#') if %r{^@reboot $SCRIPT_DIR/}"| awk '!a[$0]++' | crontab -

if [[ ! -e $SCRIPT_DIR/update-refind.sh ]]; then
    echo Doesn\'t exist update-refind.sh in $SCRIPT_DIR.
    exit
fi

cp $SCRIPT_DIR/update-refind.sh /boot

cat << EOF > /etc/systemd/system/update-refind.service
[Unit]
# Execute command before shutdown/reboot [duplicate]
# https://askubuntu.com/questions/416299/execute-command-before-shutdown-reboot
Description=Copy latest kernel to EFI patitions and update refind.conf

[Service]
Type=oneshot
RemainAfterExit=true
ExecStart=/bin/true
ExecStop=/boot/update-refind.sh

[Install]
WantedBy=multi-user.target
EOF

systemctl enable update-refind
systemctl start update-refind
