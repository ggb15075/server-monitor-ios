#!/bin/sh
# Run from a downloaded/checked-out source tree as root after installing Komari Agent.
set -eu
umask 077
TASK_SOURCE=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TASK_ROOT=/opt/yunshao-route
TASK_CONFIG=/opt/yunshao-agent/config.json
TASK_DIGEST=3868c8190c961b534b8f2d0ed528796fc48d46a818ee5268fe2dfc6aa44b3a5e

test "$(id -u)" = 0 || { echo 'Run this installer as root.' >&2; exit 1; }
test "$(uname -m)" = x86_64 || { echo 'This pinned installer supports Linux amd64 only.' >&2; exit 1; }
test -r "$TASK_CONFIG" || { echo 'Install the YunShao Komari Agent config first.' >&2; exit 1; }
command -v python3 >/dev/null
command -v curl >/dev/null
command -v systemctl >/dev/null
test -f "$TASK_SOURCE/scripts/detect_routes.py"
python3 -m unittest discover -s "$TASK_SOURCE/scripts/tests" -v
install -d -m 700 "$TASK_ROOT" "$TASK_ROOT/results"
TASK_DOWNLOAD=$(mktemp "$TASK_ROOT/.nexttrace.XXXXXX")
trap 'rm -f "$TASK_DOWNLOAD"' EXIT HUP INT TERM
curl --fail --location --silent --show-error --connect-timeout 15 --max-time 120 \
  --proto '=https' --proto-redir '=https' \
  https://github.com/nxtrace/NTrace-core/releases/download/v1.7.6/nexttrace_linux_amd64 \
  --output "$TASK_DOWNLOAD"
printf '%s  %s\n' "$TASK_DIGEST" "$TASK_DOWNLOAD" | sha256sum --check
install -m 700 "$TASK_DOWNLOAD" "$TASK_ROOT/nexttrace"
install -m 700 "$TASK_SOURCE/scripts/detect_routes.py" "$TASK_ROOT/detect_routes.py"
# Preserve an explicitly prepared prefix on subsequent updates.
if [ ! -f "$TASK_ROOT/remark-prefix.txt" ]; then
  : > "$TASK_ROOT/remark-prefix.txt"
  chmod 600 "$TASK_ROOT/remark-prefix.txt"
fi
cat > /etc/systemd/system/yunshao-route.service <<'SERVICE'
[Unit]
Description=YunShao bounded IPv4 return-route detection
After=network-online.target yunshao-agent.service
Wants=network-online.target

[Service]
Type=oneshot
UMask=0077
WorkingDirectory=/opt/yunshao-route
ExecStart=/usr/bin/python3 /opt/yunshao-route/detect_routes.py --nexttrace /opt/yunshao-route/nexttrace --agent-config /opt/yunshao-agent/config.json --remark-prefix-file /opt/yunshao-route/remark-prefix.txt --output-dir /opt/yunshao-route/results
TimeoutStartSec=600
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=strict
ReadWritePaths=/opt/yunshao-route/results
SERVICE
cat > /etc/systemd/system/yunshao-route.timer <<'TIMER'
[Unit]
Description=YunShao daily route refresh

[Timer]
# 04:30 in Asia/Shanghai, with up to 15 minutes of jitter.
OnCalendar=*-*-* 20:30:00 UTC
RandomizedDelaySec=15m
Persistent=true
Unit=yunshao-route.service

[Install]
WantedBy=timers.target
TIMER
systemctl daemon-reload
systemctl enable --now yunshao-route.timer
systemctl start --no-block yunshao-route.service
echo YUNSHAO_ROUTE_INSTALLED
echo 'First detection started. Inspect journalctl -u yunshao-route.service or the Komari public remark.'
