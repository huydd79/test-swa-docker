#!/bin/bash
# 21-token-timer.sh - systemd timer template swa-lab-token@<env>: re-mint the server JWT every 30 minutes
source "$(dirname "$0")/lib.sh"
cat > /etc/systemd/system/swa-lab-token@.service <<UNIT
[Unit]
Description=Mint JWT for swa-server-%i (test.swa.docker)
[Service]
Type=oneshot
ExecStart=$PWD/mint-token.sh %i
UNIT
cat > /etc/systemd/system/swa-lab-token@.timer <<UNIT
[Unit]
Description=Refresh JWT swa-server-%i every 30m
[Timer]
OnActiveSec=1min
OnBootSec=1min
OnUnitActiveSec=30min
Persistent=true
[Install]
WantedBy=timers.target
UNIT
systemctl daemon-reload
# restart (not just enable): re-arms OnActiveSec so the timer always has a next run, even when this script is rerun
for e in $ENVS; do systemctl enable -q "swa-lab-token@$e.timer"; systemctl restart "swa-lab-token@$e.timer"; done
systemctl list-timers 'swa-lab-token@*' --no-pager | head -4
