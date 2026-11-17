#!/usr/bin/env python3
"""Install a node-scoped Komari Agent and YunShao route timer on Linux.

The shell bootstrap passes secrets in its environment, not this program's
arguments. The auto-discovery key is used once and is never written to disk.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import socket
import subprocess
import sys
import tempfile
from typing import Any
from urllib.parse import quote, urlsplit, urlunsplit


AGENT_ROOT = Path("/opt/yunshao-agent")
ROUTE_ROOT = Path("/opt/yunshao-route")
UNIT_ROOT = Path("/etc/systemd/system")
AGENT_VERSION = "1.5.11"
NEXTTRACE_VERSION = "1.7.6"
AGENT_HASHES = {
    "amd64": "78c28d89e523816baea010c0ed0714f245f508ffdaca0540f5c9f230f7053c8c",
    "arm64": "ff8e33dc12ef2b5738fa291a58498bd15dcbf8ef51966ab65fd67679a0abc87d",
}
NEXTTRACE_HASHES = {
    "amd64": "3868c8190c961b534b8f2d0ed528796fc48d46a818ee5268fe2dfc6aa44b3a5e",
    "arm64": "e4c4e818f6cebf8d8ee3df3976a304c8bac2bb3bea3160a23fd5bce18095c9e6",
}

AGENT_UNIT = """[Unit]
Description=YunShao Komari server monitoring agent
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
WorkingDirectory=/opt/yunshao-agent
ExecStart=/opt/yunshao-agent/komari-agent --config /opt/yunshao-agent/config.json
Restart=always
RestartSec=10
NoNewPrivileges=true
UMask=0077

[Install]
WantedBy=multi-user.target
"""
ROUTE_UNIT = """[Unit]
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
"""
ROUTE_TIMER = """[Unit]
Description=YunShao daily route refresh

[Timer]
OnCalendar=*-*-* 20:30:00 UTC
RandomizedDelaySec=15m
Persistent=true
Unit=yunshao-route.service

[Install]
WantedBy=timers.target
"""


def normalize_endpoint(value: str, allow_http: bool = False) -> str:
    if not isinstance(value, str) or any(ord(ch) < 33 for ch in value):
        raise ValueError("The panel endpoint must be a complete URL without whitespace.")
    try:
        parts = urlsplit(value)
        port = parts.port
    except ValueError as error:
        raise ValueError("The panel endpoint has an invalid host or port.") from error
    if (parts.scheme not in (("http", "https") if allow_http else ("https",))
            or not parts.hostname or parts.username is not None or parts.password is not None
            or parts.query or parts.fragment or port == 0):
        raise ValueError("Use an HTTPS panel homepage URL; HTTP requires --allow-http.")
    # Do not change path case or decode escaped characters in reverse-proxy paths.
    return urlunsplit((parts.scheme.lower(), parts.netloc.lower(), parts.path.rstrip("/"), "", ""))


def validate_secret(value: str, label: str, min_length: int = 1) -> str:
    if not isinstance(value, str) or not min_length <= len(value) <= 4096:
        raise ValueError(f"A valid {label} is required.")
    if any(ord(ch) < 33 or ord(ch) == 127 for ch in value):
        raise ValueError(f"The {label} contains unsupported whitespace or control characters.")
    return value


def read_existing_config(path: Path, endpoint: str) -> dict[str, Any] | None:
    if path.parent.is_symlink() or (path.parent.exists() and not path.parent.is_dir()):
        raise ValueError("Refusing to read the agent config through an unexpected parent path.")
    if path.is_symlink():
        raise ValueError("Refusing to follow a symlink for the existing agent config.")
    if not path.exists():
        return None
    try:
        if path.stat().st_size > 131072:
            raise ValueError("oversize")
        config = json.loads(path.read_text(encoding="utf-8"))
        if not isinstance(config, dict):
            raise ValueError("invalid config")
        saved_endpoint = normalize_endpoint(config["endpoint"], allow_http=True)
        validate_secret(config["token"], "node token")
    except (OSError, ValueError, TypeError, KeyError) as error:
        raise ValueError("Existing agent config is invalid; it was left unchanged.") from error
    if saved_endpoint != endpoint:
        raise ValueError("Existing agent belongs to another endpoint; no changes were made.")
    return config


def build_agent_config(endpoint: str, token: str, ip_version: str = "4") -> dict[str, Any]:
    if ip_version not in ("4", "6"):
        raise ValueError("Preferred IP version must be 4 or 6.")
    return {
        "endpoint": endpoint, "token": validate_secret(token, "node token"), "interval": 3,
        "disable_auto_update": True, "disable_web_ssh": True,
        "ignore_unsafe_cert": False, "month_rotate": 0,
        "prefer_ip_version": ip_version,
    }


def extract_registration(response: dict[str, Any]) -> tuple[str, str]:
    try:
        if response.get("status") != "success":
            raise ValueError("registration rejected")
        data = response["data"]
        uuid = data["uuid"]
        token = validate_secret(data["token"], "node token")
        if not isinstance(uuid, str) or not uuid or len(uuid) > 128:
            raise ValueError("invalid uuid")
        return uuid, token
    except (ValueError, TypeError, KeyError, AttributeError) as error:
        raise ValueError("The panel did not return valid node registration credentials.") from error


def registration_name(name: str, hostname: str) -> str:
    requested = name or hostname
    if (not isinstance(requested, str) or not requested or len(requested) > 95
            or any(ord(ch) < 32 or ord(ch) == 127 for ch in requested)):
        raise ValueError("The server name must be 1-95 characters without control characters.")
    return requested


def curl_config_escape(value: str) -> str:
    if any(ord(ch) < 32 or ord(ch) == 127 for ch in value):
        raise ValueError("A request value contains control characters.")
    return value.replace("\\", "\\\\").replace('"', '\\"')


def request_json(endpoint: str, path: str, body: dict[str, Any] | None = None,
                 bearer: str | None = None, method: str = "POST",
                 runner: Any = subprocess.run, family: str = "") -> dict[str, Any]:
    """One request, without redirects/retries; credentials only in curl stdin.

    Registration is non-idempotent. Never retry a request whose response was lost.
    Select a reachable address family with GET /ping before calling registration.
    """
    config = [f'url = "{curl_config_escape(endpoint + path)}"',
              f'request = "{method}"', 'header = "Content-Type: application/json"']
    if bearer is not None:
        validate_secret(bearer, "registration key")
        config.append('header = "Authorization: Bearer ' + curl_config_escape(bearer) + '"')
    if body is not None:
        payload = json.dumps(body, ensure_ascii=False, separators=(",", ":"))
        config.append('data-binary = "' + curl_config_escape(payload) + '"')
    command = ["curl", "--silent", "--show-error", "--config", "-",
               "--connect-timeout", "10", "--max-time", "35", "--max-redirs", "0",
               "--proto", "=http,https", "--write-out", "\n%{http_code}"]
    if family:
        command.append(family)
    try:
        completed = runner(command, input="\n".join(config) + "\n", capture_output=True,
                           text=True, encoding="utf-8", errors="replace", timeout=40, check=False)
        response_text, separator, status = completed.stdout.rpartition("\n")
        if completed.returncode or not separator or not status.isdigit() or not 200 <= int(status) < 300:
            raise ValueError("request failed")
        response = json.loads(response_text)
        if not isinstance(response, dict):
            raise ValueError("invalid response")
        return response
    except (OSError, ValueError, TypeError, subprocess.TimeoutExpired) as error:
        raise ValueError("Panel request failed or was rejected; no credentials are printed. "
                         "Registration is not retried automatically.") from error


def choose_family(endpoint: str, runner: Any = subprocess.run) -> str:
    for family in ("--ipv6", ""):
        command = ["curl", "--silent", "--show-error", "--fail", "--output", "/dev/null",
                   "--connect-timeout", "5", "--max-time", "10", "--max-redirs", "0",
                   "--proto", "=http,https"]
        if family:
            command.append(family)
        command.append(endpoint + "/ping")
        try:
            response = runner(command, capture_output=True, text=True, timeout=12, check=False)
            if response.returncode == 0:
                return family
        except (OSError, subprocess.TimeoutExpired):
            pass
    raise ValueError("The VPS cannot reach the panel. Check DNS, IPv4/IPv6 and HTTPS before installing.")


def run_systemctl(*args: str, check: bool = True) -> subprocess.CompletedProcess[str]:
    completed = subprocess.run(["systemctl", *args], capture_output=True, text=True,
                               encoding="utf-8", errors="replace", timeout=45, check=False)
    if check and completed.returncode:
        raise ValueError("A systemd operation failed: " + " ".join(args) +
                         ". Inspect systemctl status locally.")
    return completed


def validate_existing_unit(name: str, required_exec: str) -> None:
    fragment = run_systemctl("show", name, "--property=FragmentPath", "--value", check=False).stdout.strip()
    unit = Path(fragment) if fragment else UNIT_ROOT / name
    if unit.is_symlink():
        raise ValueError(f"Refusing to overwrite a symlinked {name} unit.")
    if unit.exists():
        text = unit.read_text(encoding="utf-8")
        if required_exec not in text:
            raise ValueError(f"An unrelated {name} unit already exists; it was left unchanged.")


def atomic_write(path: Path, content: str | bytes, mode: int) -> None:
    if path.is_symlink():
        raise ValueError(f"Refusing to replace a symlink: {path.name}.")
    descriptor, temporary = tempfile.mkstemp(prefix=".yunshao-", dir=str(path.parent))
    temporary_path = Path(temporary)
    try:
        with os.fdopen(descriptor, "wb") as stream:
            stream.write(content.encode("utf-8") if isinstance(content, str) else content)
            stream.flush()
            os.fsync(stream.fileno())
        temporary_path.chmod(mode)
        temporary_path.replace(path)
    finally:
        temporary_path.unlink(missing_ok=True)


def download_checked(url: str, destination: Path, expected: str) -> None:
    command = ["curl", "--fail", "--location", "--silent", "--show-error",
               "--connect-timeout", "15", "--max-time", "180", "--proto", "=https",
               "--proto-redir", "=https", "--output", str(destination), url]
    completed = subprocess.run(command, capture_output=True, text=True, timeout=190, check=False)
    if completed.returncode:
        raise ValueError("An official binary download failed; installed credentials are preserved for retry.")
    if hashlib.sha256(destination.read_bytes()).hexdigest() != expected:
        raise ValueError("An official binary failed its pinned SHA-256 check.")
    destination.chmod(0o700)


def safe_directory(path: Path) -> None:
    if path.is_symlink() or (path.exists() and not path.is_dir()):
        raise ValueError(f"Expected a real directory at {path}.")
    path.mkdir(mode=0o700, parents=True, exist_ok=True)
    path.chmod(0o700)


def preflight_directory(path: Path) -> None:
    if path.is_symlink() or (path.exists() and not path.is_dir()):
        raise ValueError(f"Refusing an unexpected path at {path}.")


def preflight_file(path: Path) -> None:
    if path.is_symlink() or (path.exists() and not path.is_file()):
        raise ValueError(f"Refusing an unexpected file path at {path}.")


def check_install(endpoint: str) -> int:
    config = read_existing_config(AGENT_ROOT / "config.json", endpoint)
    if config is None:
        print("No YunShao agent config is installed.")
        return 1
    agent = run_systemctl("is-active", "yunshao-agent.service", check=False).stdout.strip()
    timer = run_systemctl("is-active", "yunshao-route.timer", check=False).stdout.strip()
    print("Existing config belongs to the requested endpoint; node token is present.")
    print(f"Agent: {agent or 'unknown'}; route timer: {timer or 'unknown'}.")
    return 0 if agent == "active" else 1


def install(endpoint: str, key: str, token: str, name: str, source_dir: Path) -> int:
    config_path = AGENT_ROOT / "config.json"
    existing = read_existing_config(config_path, endpoint)
    # Only a successful fresh registration proves that the server-side remark
    # starts empty. A manually supplied token can belong to an existing node.
    new_node = existing is None and not token
    if existing is not None and token and token != existing["token"]:
        raise ValueError("A different node token was supplied; existing credentials were left unchanged.")
    if existing is None:
        if token:
            validate_secret(token, "node token")
        else:
            validate_secret(key, "auto-discovery key", 12)
        if AGENT_ROOT.exists() and not (AGENT_ROOT / ".yunshao-install").exists():
            raise ValueError("An unrecognized agent directory already exists without a valid config.")
    validate_existing_unit("yunshao-agent.service", "ExecStart=/opt/yunshao-agent/komari-agent --config /opt/yunshao-agent/config.json")
    validate_existing_unit("yunshao-route.service", "ExecStart=/usr/bin/python3 /opt/yunshao-route/detect_routes.py")
    other_agent_unit = run_systemctl("show", "komari-agent.service", "--property=FragmentPath",
                                     "--value", check=False).stdout.strip()
    if other_agent_unit:
        raise ValueError("A separate komari-agent.service already exists; it was left unchanged.")
    if Path("/opt/komari-agent").exists():
        raise ValueError("An unrecognized /opt/komari-agent installation exists; it was left unchanged.")
    timer_path = UNIT_ROOT / "yunshao-route.timer"
    if timer_path.is_symlink():
        raise ValueError("Refusing a symlinked route timer unit.")
    if timer_path.exists() and "Unit=yunshao-route.service" not in timer_path.read_text(encoding="utf-8"):
        raise ValueError("An unrelated route timer already exists; it was left unchanged.")
    for directory in (AGENT_ROOT, ROUTE_ROOT, ROUTE_ROOT / "results"):
        preflight_directory(directory)
    for path in (AGENT_ROOT / ".yunshao-install", AGENT_ROOT / "komari-agent",
                 ROUTE_ROOT / "nexttrace", ROUTE_ROOT / "detect_routes.py",
                 ROUTE_ROOT / "remark-prefix.txt", UNIT_ROOT / "yunshao-agent.service",
                 UNIT_ROOT / "yunshao-route.service"):
        preflight_file(path)
    machine = platform.machine().lower()
    arch = {"x86_64": "amd64", "amd64": "amd64", "aarch64": "arm64", "arm64": "arm64"}.get(machine)
    if arch is None:
        raise ValueError("This installer supports Linux amd64 and arm64 only.")
    collector = source_dir / "detect_routes.py"
    if not collector.is_file():
        raise ValueError("The installer source bundle is incomplete.")
    family = choose_family(endpoint)
    # Complete downloads before creating a new node. Config is persisted as soon
    # as registration succeeds, so later local failures cannot cause duplicates.
    with tempfile.TemporaryDirectory(prefix="yunshao-download-") as temporary:
        stage = Path(temporary)
        agent_binary, trace_binary = stage / "komari-agent", stage / "nexttrace"
        print(f"Downloading verified Komari Agent {AGENT_VERSION} and NextTrace {NEXTTRACE_VERSION} ({arch})...")
        download_checked(f"https://github.com/komari-monitor/komari-agent/releases/download/{AGENT_VERSION}/komari-agent-linux-{arch}",
                         agent_binary, AGENT_HASHES[arch])
        download_checked(f"https://github.com/nxtrace/NTrace-core/releases/download/v{NEXTTRACE_VERSION}/nexttrace_linux_{arch}",
                         trace_binary, NEXTTRACE_HASHES[arch])
        safe_directory(AGENT_ROOT)
        if existing is None:
            atomic_write(AGENT_ROOT / ".yunshao-install", "YunShao VPS installer v1\n", 0o600)
            if not token:
                requested_name = registration_name(name, socket.gethostname())
                response = request_json(endpoint, "/api/clients/register?name=" + quote(requested_name, safe=""),
                                        bearer=key, family=family)
                _, token = extract_registration(response)
                # Forget the shared registration credential before installing services.
                key = ""
                print("Created a new node with its own agent token.")
            existing = build_agent_config(endpoint, token, "6" if family == "--ipv6" else "4")
            atomic_write(config_path, json.dumps(existing, ensure_ascii=False, indent=2) + "\n", 0o600)
        else:
            print("Reusing this host's existing node token; no new node is registered.")
            config_path.chmod(0o600)
        # Validate only the existing identity and update no metadata.
        response = request_json(endpoint, "/api/clients/v2/rpc",
                                {"jsonrpc": "2.0", "id": "yunshao-install", "token": existing["token"],
                                 "method": "agent.basicInfo", "params": {"info": {}}}, family=family)
        if (response.get("id") != "yunshao-install" or "error" in response
                or not isinstance(response.get("result"), dict)
                or response["result"].get("status") != "success"):
            raise ValueError("The saved node token was rejected; it was preserved and not replaced.")
        atomic_write(AGENT_ROOT / "komari-agent", agent_binary.read_bytes(), 0o700)
        safe_directory(ROUTE_ROOT)
        safe_directory(ROUTE_ROOT / "results")
        atomic_write(ROUTE_ROOT / "nexttrace", trace_binary.read_bytes(), 0o700)
        atomic_write(ROUTE_ROOT / "detect_routes.py", collector.read_bytes(), 0o700)
        prefix_path = ROUTE_ROOT / "remark-prefix.txt"
        route_ready = prefix_path.exists()
        if not route_ready and not new_node:
            # A legacy/manual node may have public remarks we cannot read using
            # its node token. Never erase them by guessing an empty prefix.
            print("Existing node without a saved remark prefix: metrics will run; route upload is paused.")
            print("Save other public remarks in /opt/yunshao-route/remark-prefix.txt, then enable the route timer.")
        elif not route_ready:
            atomic_write(prefix_path, "", 0o600)
            route_ready = True
        if prefix_path.exists():
            if prefix_path.is_symlink():
                raise ValueError("Refusing a symlink for the route remark prefix.")
            prefix_path.chmod(0o600)
        atomic_write(UNIT_ROOT / "yunshao-agent.service", AGENT_UNIT, 0o644)
        atomic_write(UNIT_ROOT / "yunshao-route.service", ROUTE_UNIT, 0o644)
        atomic_write(timer_path, ROUTE_TIMER, 0o644)
        run_systemctl("daemon-reload")
        run_systemctl("enable", "--now", "yunshao-agent.service")
        run_systemctl("restart", "yunshao-agent.service")
        run_systemctl("is-active", "yunshao-agent.service")
        if route_ready:
            run_systemctl("enable", "--now", "yunshao-route.timer")
            run_systemctl("start", "--no-block", "yunshao-route.service")
        else:
            run_systemctl("disable", "--now", "yunshao-route.timer")
            run_systemctl("stop", "yunshao-route.service")
    print("YUNSHAO_VPS_INSTALLED")
    print("Refresh the existing panel in YunShao. Metrics appear after the first agent report.")
    if route_ready:
        print("First route detection is running; daily refresh: 04:30-04:45 Asia/Shanghai.")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--endpoint", required=True)
    parser.add_argument("--name", default="")
    parser.add_argument("--allow-http", action="store_true")
    parser.add_argument("--check", action="store_true", help="Read config/service status without modifying or contacting the panel")
    parser.add_argument("--source-dir", type=Path, default=Path(__file__).resolve().parent)
    arguments = parser.parse_args()
    key = os.environ.pop("YUNSHAO_INSTALL_AD_KEY", "")
    token = os.environ.pop("YUNSHAO_INSTALL_NODE_TOKEN", "")
    try:
        endpoint = normalize_endpoint(arguments.endpoint, arguments.allow_http)
        if platform.system() != "Linux" or os.geteuid() != 0:
            raise ValueError("Run this installer as root on Linux with systemd.")
        if not shutil.which("systemctl"):
            raise ValueError("This installer needs systemd.")
        if arguments.check:
            return check_install(endpoint)
        return install(endpoint, key, token, arguments.name, arguments.source_dir)
    except (ValueError, OSError, subprocess.TimeoutExpired) as error:
        print("Install stopped: " + str(error), file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
