#!/usr/bin/env python3
"""Bounded IPv4 return-route measurement using NextTrace 1.7.6.

No administrator credentials are required or read. stdout contains one route
report; diagnostics go to stderr. An optional node-scoped upload uses only the
existing Agent endpoint and token to update this node's public remark.
"""

from __future__ import annotations

import argparse
from datetime import datetime, timezone
import ipaddress
import json
from pathlib import Path
import re
import subprocess
import sys
from typing import Any
from urllib.parse import urlsplit, urlunsplit


TARGETS = (
    ("telecom", "电信", "202.96.134.133"),
    ("unicom", "联通", "210.21.196.6"),
    ("mobile", "移动", "211.136.192.6"),
)

# Priority is deliberate: seeing an enhanced backbone and the carrier's normal
# domestic network is common. The label describes only an observed backbone.
BACKBONES = {
    "电信": (("AS4809", "电信CN2"), ("AS4134", "电信163")),
    "联通": (("AS9929", "联通9929"), ("AS4837", "联通169")),
    "移动": (("AS58807", "移动CMIN2"), ("AS58453", "移动CMI")),
}


def normalized_asn(value: Any) -> str | None:
    """Accept the explicit ASN field, never owner names or free-form hop text."""
    if not isinstance(value, str):
        return None
    match = re.fullmatch(r"(?:AS)?([1-9][0-9]{0,9})", value.strip(), re.IGNORECASE)
    if not match or int(match.group(1)) > 4294967295:
        return None
    return "AS" + str(int(match.group(1)))


def parse_trace(stdout: str, carrier: str, target: str) -> dict[str, Any]:
    """Read the traditional NextTrace 1.7.6 JSON contract conservatively.

    Hops is [][]Hop; Hop.Success and Address.IP are Go-exported keys, while
    Geo.asnumber uses a lower-case JSON tag. Unknown or partial JSON is unknown.
    Exit status is intentionally not used as proof of reaching the destination.
    """
    path: dict[str, Any] = {
        "carrier": carrier,
        "label": "",
        "evidence": [],
        "target": target,
        "reached_target": False,
    }
    try:
        target_ip = ipaddress.ip_address(target)
        result = json.loads(stdout)
    except (ValueError, TypeError):
        return path
    if target_ip.version != 4 or not isinstance(result, dict):
        return path
    hops = result.get("Hops")
    if not isinstance(hops, list):
        return path
    seen: set[str] = set()
    for probes in hops[:64]:
        if not isinstance(probes, list):
            continue
        for probe in probes[:16]:
            if not isinstance(probe, dict) or probe.get("Success") is not True:
                continue
            address = probe.get("Address")
            if not isinstance(address, dict):
                continue
            try:
                hop_ip = ipaddress.ip_address(address.get("IP", ""))
            except (ValueError, TypeError):
                continue
            if hop_ip.version != 4:
                continue
            if hop_ip == target_ip:
                path["reached_target"] = True
            # ASN annotations on RFC1918 or other non-public hops are not proof.
            if not hop_ip.is_global:
                continue
            geo = probe.get("Geo")
            if not isinstance(geo, dict):
                continue
            # Reject a provider response explicitly annotated for a different IP.
            geo_ip = geo.get("ip")
            if geo_ip:
                try:
                    if ipaddress.ip_address(geo_ip) != hop_ip:
                        continue
                except (ValueError, TypeError):
                    continue
            asn = normalized_asn(geo.get("asnumber"))
            if asn and asn not in seen:
                seen.add(asn)
                path["evidence"].append(asn)
    for asn, label in BACKBONES.get(carrier, ()):
        if asn in seen:
            path["label"] = label
            break
    return path


def trace_command(binary: str, target: str) -> list[str]:
    return [
        binary, "--traceroute", "--ipv4", "--json", "--no-rdns",
        "--queries", "2", "--max-attempts", "4", "--max-hops", "30",
        "--parallel-requests", "6", "--timeout", "1500",
        "--data-provider", "NextTrace-API", target,
    ]


def text_output(value: Any) -> str:
    if isinstance(value, bytes):
        return value.decode("utf-8", errors="replace")
    return value if isinstance(value, str) else ""


def collect_target(binary: str, carrier: str, target: str, timeout: float = 150,
                   runner: Any = subprocess.run) -> tuple[dict[str, Any], str, str]:
    try:
        completed = runner(trace_command(binary, target), capture_output=True,
                           text=True, encoding="utf-8", errors="replace",
                           timeout=timeout, check=False)
        stdout = text_output(completed.stdout)
        stderr = text_output(completed.stderr)
        if completed.returncode:
            stderr += f"\nNextTrace exit code: {completed.returncode}\n"
    except subprocess.TimeoutExpired as error:
        # A completed JSON document may have been emitted just before timeout.
        # Truncated output must not be turned into an invented route.
        stdout = text_output(error.stdout)
        stderr = text_output(error.stderr) + f"\nNextTrace timed out after {timeout:g}s.\n"
    except OSError as error:
        stdout = ""
        stderr = f"Cannot run NextTrace: {error}\n"
    return parse_trace(stdout, carrier, target), stdout, stderr


def write_private(path: Path, content: str) -> None:
    # Raw measurements contain network addresses. New output directories are
    # private, and individual files are never made globally readable by us.
    with path.open("x", encoding="utf-8", newline="\n") as stream:
        stream.write(content)
    path.chmod(0o600)


def agent_endpoint_and_token(config_path: Path) -> tuple[str, str]:
    """Read only the existing node's credentials; never emit them in diagnostics."""
    try:
        config = json.loads(config_path.read_text(encoding="utf-8"))
        endpoint, token = config["endpoint"], config["token"]
        parts = urlsplit(endpoint)
        if (parts.scheme not in ("http", "https") or not parts.hostname
                or parts.username is not None or parts.password is not None
                or parts.query or parts.fragment or not isinstance(token, str)
                or not token or len(token) > 4096 or parts.port == 0):
            raise ValueError("invalid agent settings")
        api = urlunsplit((parts.scheme, parts.netloc,
                          parts.path.rstrip("/") + "/api/clients/v2/rpc", "", ""))
        return api, token
    except (OSError, ValueError, KeyError, TypeError, AttributeError) as error:
        raise ValueError("Cannot read a valid endpoint and token from the agent config.") from error


def upload_report(report: dict[str, Any], config_path: Path, prefix: str = "",
                  runner: Any = subprocess.run) -> bool:
    endpoint, token = agent_endpoint_and_token(config_path)
    document = json.dumps(report, ensure_ascii=False, separators=(",", ":"))
    remark = prefix.rstrip() + ("\n" if prefix.strip() else "")
    remark += "<details><summary>云哨线路检测</summary>\n\n[yunshao-route-v1]\n"
    remark += document + "\n[/yunshao-route-v1]\n\n</details>"
    if len(remark.encode("utf-8")) > 65536:
        raise ValueError("The combined public remark exceeds 64 KiB.")
    body = json.dumps({"jsonrpc": "2.0", "id": "yunshao-route", "token": token,
                       "method": "agent.basicInfo", "params": {"info": {"public_remark": remark}}},
                      ensure_ascii=False, separators=(",", ":"))
    command = ["curl", "--silent", "--show-error", "--request", "POST",
               "--header", "Content-Type: application/json", "--data-binary", "@-",
               "--connect-timeout", "10", "--max-time", "35", "--max-redirs", "0",
               "--proto", "=http,https", "--write-out", "\n%{http_code}"]
    # Prefer a reachable IPv6 endpoint when a domain also has a private A record.
    # Do not follow redirects: a node token must stay at the configured origin.
    for family in (["--ipv6"], []):
        try:
            completed = runner(command + family + [endpoint], input=body, capture_output=True,
                               text=True, encoding="utf-8", errors="replace", timeout=40, check=False)
            output = text_output(completed.stdout)
            response_text, separator, status = output.rpartition("\n")
            if completed.returncode or not separator or not status.isdigit() or not 200 <= int(status) < 300:
                continue
            response = json.loads(response_text)
            if (isinstance(response, dict) and response.get("jsonrpc") == "2.0"
                    and response.get("id") == "yunshao-route" and "error" not in response
                    and isinstance(response.get("result"), dict)
                    and response["result"].get("status") == "success"):
                return True
        except (OSError, ValueError, subprocess.TimeoutExpired):
            continue
    return False


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--nexttrace", required=True, help="Path to official NextTrace 1.7.6 binary")
    parser.add_argument("--timeout", type=float, default=150, help="Per-target timeout, 1–150 seconds")
    parser.add_argument("--output-dir", type=Path, help="Save a new private subdirectory containing raw JSON and report")
    parser.add_argument("--agent-config", type=Path,
                        help="Upload with this node's existing Komari agent endpoint/token after measuring")
    parser.add_argument("--remark-prefix-file", type=Path,
                        help="Existing public remark text to keep before the route block (UTF-8)")
    arguments = parser.parse_args()
    if not 1 <= arguments.timeout <= 150:
        parser.error("--timeout must be between 1 and 150 seconds")
    binary = str(Path(arguments.nexttrace).expanduser().resolve())
    if not Path(binary).is_file():
        parser.error("--nexttrace must identify an existing executable file")
    prefix = ""
    if arguments.remark_prefix_file:
        try:
            if arguments.remark_prefix_file.stat().st_size > 32768:
                parser.error("--remark-prefix-file must not exceed 32 KiB")
            prefix = arguments.remark_prefix_file.read_text(encoding="utf-8")
            if "[yunshao-route-v1]" in prefix or "[/yunshao-route-v1]" in prefix:
                parser.error("--remark-prefix-file must contain only your other remark text, without a route block")
        except (OSError, UnicodeError):
            parser.error("Cannot read --remark-prefix-file as UTF-8")
    if arguments.agent_config:
        try:
            agent_endpoint_and_token(arguments.agent_config)
        except ValueError as error:
            parser.error(str(error))

    started = datetime.now(timezone.utc)
    output_dir: Path | None = None
    if arguments.output_dir:
        root = arguments.output_dir.expanduser().resolve()
        root.mkdir(mode=0o700, parents=True, exist_ok=True)
        output_dir = root / started.strftime("%Y%m%dT%H%M%S.%fZ")
        output_dir.mkdir(mode=0o700)

    paths = []
    for identifier, carrier, target in TARGETS:
        path, raw, diagnostics = collect_target(binary, carrier, target, arguments.timeout)
        paths.append(path)
        if diagnostics:
            print(f"[{carrier}] {diagnostics.rstrip()}", file=sys.stderr)
        if output_dir:
            write_private(output_dir / f"{identifier}.json", raw)
            write_private(output_dir / f"{identifier}.stderr.txt", diagnostics)
    report = {
        "schema": 1,
        "checked_at": datetime.now(timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z"),
        "direction": "VPS → 中国大陆（回程）",
        "ip_version": "IPv4",
        "paths": paths,
    }
    document = json.dumps(report, ensure_ascii=False, separators=(",", ":"))
    if output_dir:
        write_private(output_dir / "report.json", document + "\n")
        print(f"Raw measurements saved in {output_dir}", file=sys.stderr)
    print(document)
    if arguments.agent_config:
        try:
            uploaded = upload_report(report, arguments.agent_config, prefix)
        except ValueError:
            uploaded = False
        if not uploaded:
            print("Route report was measured, but the node-scoped upload failed. No credentials are printed.",
                  file=sys.stderr)
            return 1
        print("Route report uploaded with this node's existing agent identity.", file=sys.stderr)
    # Unknown or unreachable paths are valid measurements, not collector errors.
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
