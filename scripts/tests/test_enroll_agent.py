import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest


MODULE_PATH = Path(__file__).resolve().parents[1] / "enroll_agent.py"
SPEC = importlib.util.spec_from_file_location("enroll_agent", MODULE_PATH)
enroll = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(enroll)


class EnrollmentHelperTests(unittest.TestCase):
    def test_endpoint_requires_https_and_removes_trailing_slashes(self):
        self.assertEqual(enroll.normalize_endpoint("HTTPS://Monitor.Example:443/base///"),
                         "https://monitor.example:443/base")
        with self.assertRaises(ValueError):
            enroll.normalize_endpoint("http://monitor.example")
        self.assertEqual(enroll.normalize_endpoint("http://127.0.0.1:25774/", allow_http=True),
                         "http://127.0.0.1:25774")

    def test_endpoint_rejects_credentials_queries_fragments_and_malformed_ports(self):
        for endpoint in (
            "https://user:pass@example.test",
            "https://example.test?token=secret",
            "https://example.test/#fragment",
            "https://example.test:wrong",
            "https://example.test/path with spaces",
            "https://example.test/path\nInjected: yes",
        ):
            with self.subTest(endpoint=endpoint), self.assertRaises(ValueError):
                enroll.normalize_endpoint(endpoint, allow_http=True)

    def test_secrets_are_bounded_and_reject_control_characters(self):
        self.assertEqual(enroll.validate_secret("registration-key", "key", 12), "registration-key")
        for key in ("short", "bad key", "line\nbreak", "x" * 4097):
            with self.subTest(key=key[:16]), self.assertRaises(ValueError):
                enroll.validate_secret(key, "key", 12)

    def test_new_agent_config_has_safe_defaults_and_only_node_token(self):
        config = enroll.build_agent_config("https://monitor.example", "node-token")
        self.assertEqual(config["endpoint"], "https://monitor.example")
        self.assertEqual(config["token"], "node-token")
        self.assertEqual(config["interval"], 3)
        self.assertIs(config["disable_auto_update"], True)
        self.assertIs(config["disable_web_ssh"], True)
        self.assertIs(config["ignore_unsafe_cert"], False)
        self.assertEqual(config["prefer_ip_version"], "4")
        self.assertEqual(enroll.build_agent_config("https://monitor.example", "node-token", "6")[
            "prefer_ip_version"], "6")
        self.assertNotIn("auto_discovery_key", config)
        self.assertNotIn("api_key", config)

    def test_registration_response_must_include_success_uuid_and_node_token(self):
        self.assertEqual(enroll.extract_registration({"status": "success", "data": {
            "uuid": "node-uuid", "token": "node-token"}}), ("node-uuid", "node-token"))
        for response in (
            {},
            {"status": "failed", "data": {"uuid": "node-uuid", "token": "node-token"}},
            {"status": "success", "data": {"uuid": "", "token": "node-token"}},
            {"status": "success", "data": {"uuid": "node-uuid", "token": ""}},
        ):
            with self.subTest(response=response), self.assertRaises(ValueError):
                enroll.extract_registration(response)

    def test_existing_config_is_reused_only_for_same_endpoint(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "config.json"
            original = {"endpoint": "https://monitor.example/", "token": "existing-node-token"}
            path.write_text(json.dumps(original), encoding="utf-8")
            self.assertEqual(enroll.read_existing_config(path, "https://monitor.example"), original)
            with self.assertRaisesRegex(ValueError, "another endpoint"):
                enroll.read_existing_config(path, "https://different.example")

    def test_existing_config_rejects_invalid_json_missing_token_and_symlinks(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "config.json"
            path.write_text("not json", encoding="utf-8")
            with self.assertRaises(ValueError):
                enroll.read_existing_config(path, "https://monitor.example")
            path.write_text(json.dumps({"endpoint": "https://monitor.example"}), encoding="utf-8")
            with self.assertRaises(ValueError):
                enroll.read_existing_config(path, "https://monitor.example")
            target = Path(directory) / "target.json"
            target.write_text(json.dumps({"endpoint": "https://monitor.example", "token": "token"}),
                              encoding="utf-8")
            path.unlink()
            path.symlink_to(target)
            with self.assertRaisesRegex(ValueError, "symlink"):
                enroll.read_existing_config(path, "https://monitor.example")

    def test_registration_key_and_request_body_are_passed_only_via_curl_stdin(self):
        key = "test-registration-secret"
        body = {"method": "agent.basicInfo", "token": "node-token"}
        calls = []

        def capture(command, **kwargs):
            calls.append((command, kwargs))
            return subprocess.CompletedProcess(command, 0,
                '{"status":"success","data":{"uuid":"uuid","token":"node-token"}}\n200', "")

        response = enroll.request_json("https://monitor.example", "/api/clients/register?name=host",
            bearer=key, runner=capture)
        self.assertEqual(response["data"]["uuid"], "uuid")
        command, options = calls[0]
        self.assertIn("--config", command)
        self.assertNotIn(key, " ".join(command))
        self.assertIn("--max-redirs", command)
        self.assertIn("Authorization: Bearer " + key, options["input"])
        self.assertIn("https://monitor.example/api/clients/register?name=host", options["input"])

        calls.clear()
        enroll.request_json("https://monitor.example", "/api/clients/v2/rpc", body,
                            runner=capture)
        _, options = calls[0]
        self.assertIn(json.dumps(body, separators=(",", ":")), options["input"])
        self.assertNotIn("node-token", " ".join(calls[0][0]))

    def test_panel_reachability_prefers_ipv6_and_falls_back_to_default_family(self):
        calls = []

        def ipv6_available(command, **kwargs):
            calls.append(command)
            return subprocess.CompletedProcess(command, 0 if len(calls) == 1 else 1, "", "")

        self.assertEqual(enroll.choose_family("https://monitor.example", runner=ipv6_available), "--ipv6")
        self.assertIn("--ipv6", calls[0])
        calls.clear()

        def ipv6_unavailable(command, **kwargs):
            calls.append(command)
            return subprocess.CompletedProcess(command, 1 if len(calls) == 1 else 0, "", "")

        self.assertEqual(enroll.choose_family("https://monitor.example", runner=ipv6_unavailable), "")
        self.assertIn("--ipv6", calls[0])
        self.assertNotIn("--ipv6", calls[1])

    def test_request_json_rejects_redirects_http_errors_and_malformed_json(self):
        for output, code in (
            ('{"status":"success"}\n302', 0),
            ("not json\n200", 0),
            ('{"status":"success"}\n200', 22),
        ):
            with self.subTest(output=output, code=code):
                def fail(command, **kwargs):
                    return subprocess.CompletedProcess(command, code, output, "")
                with self.assertRaises(ValueError):
                    enroll.request_json("https://monitor.example", "/api/clients/register",
                                        bearer="registration-key", runner=fail)

    def test_nexttrace_and_agent_release_hashes_are_pinned_for_supported_architectures(self):
        self.assertEqual(set(enroll.AGENT_HASHES), {"amd64", "arm64"})
        self.assertEqual(set(enroll.NEXTTRACE_HASHES), {"amd64", "arm64"})
        for digest in (*enroll.AGENT_HASHES.values(), *enroll.NEXTTRACE_HASHES.values()):
            with self.subTest(digest=digest):
                self.assertRegex(digest, r"^[0-9a-f]{64}$")


if __name__ == "__main__":
    unittest.main()
