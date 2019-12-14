#!/bin/bash

# grant by ROOT is required
(( $EUID == 0 )) && exec sudo "$0" "$@"

# https://qiita.com/koara-local/items/2d67c0964188bba39e29
SCRIPT_DIR=$(cd $(dirname $0); pwd)

cp $SCRIPT_DIR/update-refind.sh /boot
cp $SCRIPT_DIR/update-refind.service /etc/systemd/system
systemctl enable update-refind
systemctl start update-refind
