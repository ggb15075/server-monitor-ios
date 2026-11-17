#!/usr/bin/env bash
# YunShao VPS bootstrap. Shared registration keys never go in the public source.
set -euo pipefail
umask 077

TASK_SOURCE_REF='agent-v1.0.0'
TASK_SOURCE_URL="https://raw.githubusercontent.com/ggb15075/server-monitor-ios/${TASK_SOURCE_REF}"
TASK_ENROLL_SHA256='a34adf44641695de8f3da2cd3ccd0444af23cb3ef33eb06917af134f6ed8f35d'
TASK_ROUTES_SHA256='6158d6af90a0f0fe77d07f288e4ea8384d2b13023be0725d9fa845b09e1abd3c'
TASK_ENDPOINT=''
TASK_NAME=''
TASK_KEY=''
TASK_TOKEN=''
TASK_ALLOW_HTTP=0
TASK_CHECK=0

task_usage() {
  cat <<'USAGE'
YunShao VPS installer: Linux amd64/arm64 with systemd, run as root.
  bash install.sh --endpoint https://monitor.example.com --auto-discovery 'REGISTRATION_KEY' [--name 'server-name']
  bash install.sh --endpoint https://monitor.example.com --token 'THIS_NODES_TOKEN'
  bash install.sh --endpoint https://monitor.example.com --check

--auto-discovery is the dedicated registration key, not the panel administrator API Key.
--name defaults to the hostname. Komari prefixes auto-discovered names with Auto-.
Repeated installation reuses this host's saved node token; it does not add another node.
--allow-http explicitly permits plain HTTP for a trusted LAN or local test endpoint.
USAGE
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --endpoint|-e) [ "$#" -ge 2 ] || { task_usage; exit 2; }; TASK_ENDPOINT=$2; shift 2 ;;
    --name) [ "$#" -ge 2 ] || { task_usage; exit 2; }; TASK_NAME=$2; shift 2 ;;
    --auto-discovery) [ "$#" -ge 2 ] || { task_usage; exit 2; }; TASK_KEY=$2; shift 2 ;;
    --token|-t) [ "$#" -ge 2 ] || { task_usage; exit 2; }; TASK_TOKEN=$2; shift 2 ;;
    --allow-http) TASK_ALLOW_HTTP=1; shift ;;
    --check) TASK_CHECK=1; shift ;;
    --help|-h) task_usage; exit 0 ;;
    *) echo 'Unknown option. Use --help.' >&2; exit 2 ;;
  esac
done

[ -n "$TASK_ENDPOINT" ] || { task_usage; exit 2; }
[ -z "$TASK_KEY" ] || [ -z "$TASK_TOKEN" ] || { echo 'Choose --auto-discovery or --token.' >&2; exit 2; }
[ "$(id -u)" = 0 ] || { echo 'Run this installer as root.' >&2; exit 1; }
[ "$(uname -s)" = Linux ] || { echo 'This installer supports Linux only.' >&2; exit 1; }
case "$(uname -m)" in x86_64|amd64|aarch64|arm64) ;; *) echo 'Use Linux amd64 or arm64.' >&2; exit 1;; esac
command -v systemctl >/dev/null || { echo 'This installer needs systemd.' >&2; exit 1; }

if [ "$TASK_CHECK" = 1 ]; then
  command -v python3 >/dev/null && command -v curl >/dev/null || { echo 'Check needs existing python3 and curl; nothing was installed.' >&2; exit 1; }
else
if ! command -v python3 >/dev/null || ! command -v curl >/dev/null || { [ ! -r /etc/ssl/certs/ca-certificates.crt ] && [ ! -r /etc/pki/tls/certs/ca-bundle.crt ]; }; then
  if command -v apt-get >/dev/null; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y --no-install-recommends python3 curl ca-certificates
  elif command -v dnf >/dev/null; then
    dnf install -y python3 curl ca-certificates
  elif command -v yum >/dev/null; then
    yum install -y python3 curl ca-certificates
  else
    echo 'Install python3, curl and ca-certificates with your package manager, then retry.' >&2
    exit 1
  fi
fi
fi

# A checked-out source tree uses its own reviewed helpers (also used by CI).
# Process-substitution and standalone downloads use the fixed published version.
TASK_LOCAL_SOURCE=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd) || TASK_LOCAL_SOURCE=''
TASK_STAGE=''
if [ -n "$TASK_LOCAL_SOURCE" ] && [ -f "$TASK_LOCAL_SOURCE/scripts/enroll_agent.py" ] && [ -f "$TASK_LOCAL_SOURCE/scripts/detect_routes.py" ]; then
  TASK_SCRIPTS="$TASK_LOCAL_SOURCE/scripts"
else
  TASK_STAGE=$(mktemp -d /tmp/yunshao-bootstrap.XXXXXX)
  trap 'if [ -n "$TASK_STAGE" ]; then rm -rf -- "$TASK_STAGE"; fi' EXIT HUP INT TERM
  TASK_SCRIPTS=$TASK_STAGE
  curl --fail --location --silent --show-error --connect-timeout 15 --max-time 60 \
    --proto '=https' --proto-redir '=https' "$TASK_SOURCE_URL/scripts/enroll_agent.py" -o "$TASK_SCRIPTS/enroll_agent.py"
  curl --fail --location --silent --show-error --connect-timeout 15 --max-time 60 \
    --proto '=https' --proto-redir '=https' "$TASK_SOURCE_URL/scripts/detect_routes.py" -o "$TASK_SCRIPTS/detect_routes.py"
  printf '%s  %s\n' "$TASK_ENROLL_SHA256" "$TASK_SCRIPTS/enroll_agent.py" | sha256sum --check
  printf '%s  %s\n' "$TASK_ROUTES_SHA256" "$TASK_SCRIPTS/detect_routes.py" | sha256sum --check
fi

export YUNSHAO_INSTALL_AD_KEY="$TASK_KEY"
export YUNSHAO_INSTALL_NODE_TOKEN="$TASK_TOKEN"
TASK_KEY=''
TASK_TOKEN=''
TASK_OPTIONS=(--endpoint "$TASK_ENDPOINT" --source-dir "$TASK_SCRIPTS")
[ -z "$TASK_NAME" ] || TASK_OPTIONS+=(--name "$TASK_NAME")
[ "$TASK_ALLOW_HTTP" = 0 ] || TASK_OPTIONS+=(--allow-http)
[ "$TASK_CHECK" = 0 ] || TASK_OPTIONS+=(--check)
python3 "$TASK_SCRIPTS/enroll_agent.py" "${TASK_OPTIONS[@]}"
unset YUNSHAO_INSTALL_AD_KEY YUNSHAO_INSTALL_NODE_TOKEN
