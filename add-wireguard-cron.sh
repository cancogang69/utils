#!/bin/bash

RERESOLVE_DNS_SCRIPT_PATH="/usr/share/doc/wireguard-tools/examples/reresolve-dns/reresolve-dns.sh"
RERUN_IN_MINUTE=1
SCHEDULE_SERVICE=

if [ -d /run/systemd/system ]; then 
    echo "Using systemd."
    SCHEDULE_SERVICE=systemd
elif crontab -l >/dev/null 2>&1; then
    echo "Using crontab."
    SCHEDULE_SERVICE=crontab
else
    echo "Cannot find systemd or crontab in this machine."
    echo "Please install either of them then re-run this scripts."
    exit 1
fi

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

if [[ $SCHEDULE_SERVICE == "systemd" ]]; then
    cat >/etc/systemd/system/${INTERFACE}_dns.service <<EOF
[Unit]
Description=Cron job to re-resolve the wireguard dns ${INTERFACE} interface
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
ExecStart=$RERESOLVE_DNS_SCRIPT_PATH $INTERFACE_CONFIG_PATH
EOF

    cat >/etc/systemd/system/${INTERFACE}_dns.timer <<EOF
[Unit]
Description=${INTERFACE} interface timer
Requires=${INTERFACE}_dns.service

[Timer]
Unit=${INTERFACE}_dns.service
OnCalendar=*:0/$RERUN_IN_MINUTE
Persistent=true

[Install]
WantedBy=timers.target
EOF

    sudo systemctl daemon-reload

    sudo systemctl enable ${INTERFACE}_dns.timer
    sudo systemctl start ${INTERFACE}_dns.timer
    printf "Create cron job for $INTERFACE succesfully!\n"

elif [[ $SCHEDULE_SERVICE == "crontab" ]]; then
    line="*/$RERUN_IN_MINUTE * * * * $RERESOLVE_DNS_SCRIPT_PATH $INTERFACE_CONFIG_PATH"
    (sudo crontab -l; echo "$line" ) | sudo crontab -

    sudo systemctl restart cron

    printf "Create cron job for $INTERFACE succesfully!\n"
fi

