import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest


MODULE_PATH = Path(__file__).resolve().parents[1] / "detect_routes.py"
SPEC = importlib.util.spec_from_file_location("detect_routes", MODULE_PATH)
routes = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(routes)


def hop(ip, asn=None, *, success=True, geo_ip=None):
    return {"Success": success, "Address": {"IP": ip, "Zone": ""},
            "Geo": {"ip": geo_ip or ip, "asnumber": asn} if asn is not None else None}


def result(*hops, stop_reason="destination_reached"):
    return json.dumps({"Hops": [[item] for item in hops],
                       "StopReason": {"hop": len(hops), "reason": stop_reason}})


class RouteDetectionTests(unittest.TestCase):
    def test_observed_cn2_has_priority_over_domestic_163_without_claiming_gia(self):
        report = routes.parse_trace(result(hop("59.43.1.1", "4809"),
                                           hop("202.96.134.133", "4134")), "电信", "202.96.134.133")
        self.assertEqual(report["label"], "电信CN2")
        self.assertNotIn("GIA", report["label"])
        self.assertEqual(report["evidence"], ["AS4809", "AS4134"])
        self.assertTrue(report["reached_target"])

    def test_special_backbone_can_carry_traffic_to_another_carrier(self):
        report = routes.parse_trace(result(hop("8.8.8.8", "4809")), "联通", "210.21.196.6")
        self.assertEqual(report["label"], "电信CN2")
        self.assertEqual(report["evidence"], ["AS4809"])
        self.assertFalse(report["reached_target"])

    def test_telecom_tail_does_not_hide_observed_unicom_9929_transit(self):
        # Synthetic hop addresses, with the measured ASN sequence as a regression.
        raw = result(hop("8.8.8.8", "1054"), hop("1.1.1.1", "10099"),
                     hop("9.9.9.9", "9929"), hop("202.96.134.133", "4134"))
        report = routes.parse_trace(raw, "电信", "202.96.134.133")
        self.assertEqual(report["label"], "联通9929")
        self.assertEqual(report["evidence"], ["AS1054", "AS10099", "AS9929", "AS4134"])
        self.assertTrue(report["reached_target"])

    def test_unicom_and_mobile_domestic_tails_keep_visible_special_backbone(self):
        for carrier, target, asns, label in [
            ("联通", "210.21.196.6", ["1054", "10099", "9929", "4837", "17623"], "联通9929"),
            ("移动", "211.136.192.6", ["1054", "58807", "9808", "56040"], "移动CMIN2"),
        ]:
            probes = [hop(f"8.8.8.{index + 1}", asn) for index, asn in enumerate(asns[:-1])]
            probes.append(hop(target, asns[-1]))
            with self.subTest(carrier=carrier):
                report = routes.parse_trace(result(*probes), carrier, target)
                self.assertEqual(report["label"], label)
                self.assertTrue(report["reached_target"])

    def test_multiple_special_backbones_preserve_path_order_without_choosing_a_tier(self):
        raw = result(hop("8.8.8.8", "9929"), hop("1.1.1.1", "4809"),
                     hop("202.96.134.133", "4134"))
        report = routes.parse_trace(raw, "电信", "202.96.134.133")
        self.assertEqual(report["label"], "联通9929 + 电信CN2")
        self.assertNotIn("GIA", report["label"])

    def test_cross_carrier_cmi_is_visible_and_cmin2_does_not_hide_cmi_segment(self):
        raw = result(hop("8.8.8.8", "58807"), hop("1.1.1.1", "58453"),
                     hop("202.96.134.133", "4134"))
        report = routes.parse_trace(raw, "电信", "202.96.134.133")
        self.assertEqual(report["label"], "移动CMIN2 + 移动CMI")
        self.assertTrue(report["reached_target"])

    def test_ordinary_other_carrier_backbone_does_not_replace_target_carrier(self):
        raw = result(hop("8.8.8.8", "4134"), hop("210.21.196.6", "4837"))
        report = routes.parse_trace(raw, "联通", "210.21.196.6")
        self.assertEqual(report["label"], "联通169")
        unknown = routes.parse_trace(result(hop("8.8.8.8", "4134")), "联通", "210.21.196.6")
        self.assertEqual(unknown["label"], "")

    def test_unreachable_destination_can_still_have_observed_backbone(self):
        report = routes.parse_trace(result(hop("8.8.8.8", "AS9929"), stop_reason="max_hops"),
                                    "联通", "210.21.196.6")
        self.assertEqual(report["label"], "联通9929")
        self.assertFalse(report["reached_target"])

    def test_stop_reason_or_success_exit_does_not_prove_destination_reached(self):
        report = routes.parse_trace(result(hop("8.8.8.8", "58453")), "移动", "211.136.192.6")
        self.assertEqual(report["label"], "移动CMI")
        self.assertFalse(report["reached_target"])

    def test_failed_private_wrong_family_and_mismatched_annotations_are_ignored(self):
        raw = result(hop("59.43.1.1", "4809", success=False),
                     hop("192.168.1.1", "4809"), hop("2001:4860:4860::8888", "4809"),
                     hop("8.8.8.8", "4809", geo_ip="1.1.1.1"))
        report = routes.parse_trace(raw, "电信", "202.96.134.133")
        self.assertEqual(report["label"], "")
        self.assertEqual(report["evidence"], [])
        self.assertFalse(report["reached_target"])

    def test_no_asn_and_bad_json_never_create_a_marketing_label(self):
        for raw in ["", "<html>rate limit</html>", '{"Hops": [', "[]", '{"Hops": {}}',
                    result(hop("202.96.134.133")),
                    result(hop("59.43.1.1", "CN2 GIA AS4809"))]:
            with self.subTest(raw=raw):
                report = routes.parse_trace(raw, "电信", "202.96.134.133")
                self.assertEqual(report["label"], "")

    def test_timeout_uses_only_complete_json_and_preserves_raw_output(self):
        raw = result(hop("8.8.8.8", "58807"), stop_reason="max_hops")

        def timeout_with_json(*args, **kwargs):
            raise subprocess.TimeoutExpired(args[0], kwargs["timeout"], output=raw.encode(), stderr=b"partial")

        report, output, diagnostics = routes.collect_target("nexttrace", "移动", "211.136.192.6",
                                                           runner=timeout_with_json)
        self.assertEqual(report["label"], "移动CMIN2")
        self.assertFalse(report["reached_target"])
        self.assertEqual(output, raw)
        self.assertIn("timed out", diagnostics)

        def timeout_truncated(*args, **kwargs):
            raise subprocess.TimeoutExpired(args[0], kwargs["timeout"], output=b'{"Hops": [')

        report, _, _ = routes.collect_target("nexttrace", "移动", "211.136.192.6", runner=timeout_truncated)
        self.assertEqual(report["label"], "")

    def test_invocation_is_bounded_traditional_ipv4_and_not_shell_text(self):
        command = routes.trace_command("/opt/nexttrace", "202.96.134.133")
        self.assertEqual(command[0], "/opt/nexttrace")
        self.assertIn("--traceroute", command)
        self.assertIn("--ipv4", command)
        self.assertEqual(command[-1], "202.96.134.133")
        self.assertIn("--max-attempts", command)
        self.assertIn("--max-hops", command)

    def test_upload_uses_existing_node_token_in_stdin_and_only_public_remark(self):
        with tempfile.TemporaryDirectory() as directory:
            config = Path(directory) / "agent.json"
            config.write_text(json.dumps({"endpoint": "https://monitor.example.test", "token": "node-secret"}),
                              encoding="utf-8")
            calls = []

            def capture(command, **kwargs):
                calls.append((command, kwargs))
                return subprocess.CompletedProcess(command, 0,
                    '{"jsonrpc":"2.0","id":"yunshao-route","result":{"status":"success"}}\n200', "")

            self.assertTrue(routes.upload_report({"schema": 1}, config, "我的备注", runner=capture))
            command, kwargs = calls[0]
            self.assertNotIn("node-secret", " ".join(command))
            self.assertNotIn("--location", command)
            self.assertNotIn("--insecure", command)
            self.assertEqual(command[-1], "https://monitor.example.test/api/clients/v2/rpc")
            body = json.loads(kwargs["input"])
            self.assertEqual(body["token"], "node-secret")
            self.assertEqual(body["method"], "agent.basicInfo")
            self.assertEqual(set(body["params"]["info"]), {"public_remark"})
            self.assertTrue(body["params"]["info"]["public_remark"].startswith("我的备注\n<details>"))
            self.assertIn("[yunshao-route-v1]", body["params"]["info"]["public_remark"])

    def test_redirect_and_rpc_error_are_upload_failures(self):
        with tempfile.TemporaryDirectory() as directory:
            config = Path(directory) / "agent.json"
            config.write_text(json.dumps({"endpoint": "https://monitor.example.test", "token": "node-secret"}),
                              encoding="utf-8")
            for response in ["<html>redirect</html>\n302",
                             '{"jsonrpc":"2.0","id":"yunshao-route","error":{"code":-1}}\n200',
                             '{"status":"success"}\n200',
                             '{"jsonrpc":"2.0","id":"yunshao-route","result":null}\n200']:
                with self.subTest(response=response):
                    def fail(command, **kwargs):
                        return subprocess.CompletedProcess(command, 0, response, "")
                    self.assertFalse(routes.upload_report({"schema": 1}, config, runner=fail))

    def test_agent_endpoint_rejects_embedded_secrets_and_malformed_ports(self):
        with tempfile.TemporaryDirectory() as directory:
            config = Path(directory) / "agent.json"
            for endpoint in ["https://user:pass@example.test", "https://example.test?token=secret",
                             "file:///tmp/target", "https://example.test:wrong"]:
                config.write_text(json.dumps({"endpoint": endpoint, "token": "node-secret"}), encoding="utf-8")
                with self.subTest(endpoint=endpoint):
                    with self.assertRaises(ValueError):
                        routes.agent_endpoint_and_token(config)


if __name__ == "__main__":
    unittest.main()
