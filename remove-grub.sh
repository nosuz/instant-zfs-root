#!/bin/bash

# grant by ROOT is required
(( $EUID == 0 )) && exec sudo "$0" "$@"

dpkg -l | grep ^ii | grep grub | awk '{print $2}' | xargs apt remove -y

