#!/bin/sh
# Run the agent (root; needs CAP_SYS_PTRACE to read the workload /proc) and restart it if it exits
# (e.g. "Trust recovery failed" after a server restart) - same role as systemd Restart=always on a VM.
(
  while true; do
    /opt/swa/bin/swa-agent run --configDir /etc/swa >>/var/log/swa-agent.log 2>&1
    echo "$(date -u +%FT%TZ) swa-agent exited (rc=$?), restarting in 5s" >>/var/log/swa-agent.log
    sleep 5
  done
) &
for i in $(seq 1 30); do [ -S /run/swa-agent/api.sock ] && break; sleep 1; done
chmod 755 /run/swa-agent
exec sleep infinity
