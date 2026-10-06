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
OnBootSec=1min
OnUnitActiveSec=30min
Persistent=true
[Install]
WantedBy=timers.target
UNIT
systemctl daemon-reload
for e in $ENVS; do systemctl enable --now "swa-lab-token@$e.timer"; done
systemctl list-timers 'swa-lab-token@*' --no-pager | head -4
