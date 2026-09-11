#!/bin/bash

RERESOLVE_DNS_SCRIPT_PATH="/usr/share/doc/wireguard-tools/examples/reresolve-dns/reresolve-dns.sh"
RERUN_IN_MINUTE=1

if [ "$EUID" -ne 0 ]; then
    printf "Error: Please run with sudo or as root.\n"
    exit 1
fi

if [ ! -f $INTERFACE_CONFIG_PATH ]; then
    printf "Cannot find $RERESOLVE_DNS_SCRIPT_PATH.\n"
    printf "Please install wireguard-tools.\n"
    printf "or specify true path to reresolve_dns.sh script,\n"
    printf "then retry."
    exit 1
fi

if [ $# -ne 1 ]; then
    printf "Interface name is requires\n"
    exit 1
fi

INTERFACE=$1
INTERFACE_CONFIG_PATH="/etc/wireguard/$INTERFACE.conf"

if [ ! -f $INTERFACE_CONFIG_PATH ]; then
    printf "Cannot find $INTERFACE_CONFIG_PATH.\n"
    exit 1
fi

line="*/$RERUN_IN_MINUTE * * * * $RERESOLVE_DNS_SCRIPT_PATH  $INTERFACE_CONFIG_PATH"
(sudo crontab -l; echo "$line" ) | sudo crontab -

sudo systemctl restart cron

printf "Create cron job for $INTERFACE succesfully!\n"