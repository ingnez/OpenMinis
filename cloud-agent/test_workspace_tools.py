import json
import plistlib
from pathlib import Path
import tempfile
import unittest
import urllib.request

import cloud_workspace_tools as tools
from test_phase1_support import CloudServerTestCase, FakeModelHandler, tool_call, tool_turns


class WorkspaceToolTests(unittest.TestCase):
    def test_report_escapes_supplied_data_and_requires_chart_numbers(self):
        report = tools.render_report("<title>", [
            {"type": "table", "columns": ["状态"], "rows": [["<script>"]]},
            {"type": "chart", "items": [{"label": "耗时", "value": -2.5}]},
        ])
        self.assertIn("&lt;script&gt;", report)
        self.assertNotIn("<script>", report)
        self.assertIn('value="-2.5"', report)
        with self.assertRaises(ValueError):
            tools.render_report("test", [{"type": "chart", "items": [{"value": float("nan")}]}])
        with self.assertRaises(ValueError):
            tools.render_report("test", [{"type": "table", "columns": ["a", "b"], "rows": [["x"]]}])

    def test_scan_stays_in_workspace_and_reports_truncation(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / "workspace"
            root.mkdir()
            (root / "sub").mkdir()
            (root / "sub" / "file").write_bytes(b"abc")
            (root / "a").write_bytes(b"de")
            outside = Path(tmp) / "outside"
            outside.write_bytes(b"outside")
            (root / "link").symlink_to(outside)
            report = tools.scan_workspace(root)
            self.assertEqual((report["total_bytes"], report["file_count"], report["skipped_entries"]), (5, 2, 1))
            self.assertEqual(report["largest_dirs"], [{"path": "sub", "bytes": 3}])
            self.assertTrue(tools.scan_workspace(root, max_entries=1)["truncated"])
            for path in ("../", str(outside), "link"):
                with self.assertRaises(ValueError):
                    tools.scan_workspace(root, path)

    def test_drafts_validate_dates_and_link_actions(self):
        self.assertEqual(tools.reminder_draft({"title": "Review", "due": "2028-02-29"})["due"], "2028-02-29")
        self.assertEqual(tools.reminder_draft({"title": "Review"})["due"], "")
        with self.assertRaises(ValueError):
            tools.reminder_draft({"title": "Review", "due": "2026-02-29"})
        with self.assertRaises(ValueError):
            tools.shortcut_draft({"title": "Review", "url": "file:///tmp/draft"})
        shortcut = plistlib.loads(tools.shortcut_draft({"title": "Read", "url": "https://example.com/"}))
        source, action = shortcut["WFWorkflowActions"][-2:]
        self.assertEqual(source["WFWorkflowActionIdentifier"], "is.workflow.actions.url")
        self.assertEqual(action["WFWorkflowActionIdentifier"], "is.workflow.actions.openurl")
        self.assertEqual(action["WFWorkflowActionParameters"]["WFInput"]["Value"]["OutputUUID"],
                         source["WFWorkflowActionParameters"]["UUID"])


class WorkspaceDeliveryTests(CloudServerTestCase):
    def test_report_and_device_drafts_reach_chat_history(self):
        requested = [
            ("workspace_report", {"title": "回归报告", "blocks": [{"type": "text", "text": "通过 3 项"}]}),
            ("workspace_scan", {}),
            ("reminder_draft", {"title": "复核 IPA", "due": "2026-11-14"}),
            ("shortcut_draft", {"title": "打开项目", "url": "https://example.com/"}),
        ]

        def reply(data):
            calls = tool_turns(data)
            if len(calls) < len(requested):
                name, args = requested[len(calls)]
                return tool_call(f"w{len(calls)}", name, args)
            return {"role": "assistant", "content": "草稿和报告已生成"}

        FakeModelHandler.scripts["m-workspace-tools"] = reply
        session = self.new_session()
        status, task = self.submit(session, "做回归报告、磁盘扫描、提醒事项、快捷指令", "m-workspace-tools")
        self.assertIn(status, (200, 202))
        self.assertEqual(self.wait_status(task["task_id"], ("completed", "failed"))["status"], "completed")
        messages = self.request("GET", f"/v1/sessions/{session}")[1]["messages"]
        final = next(m for m in messages if m.get("page") and m.get("shortcut_draft"))
        self.assertEqual(final["reminder_draft"]["due"], "2026-11-14")
        page = self.request("GET", "/v1/pages/" + final["page"]["page_id"])[1]
        self.assertIn("通过 3 项", page["html"])
        request = urllib.request.Request(f"http://127.0.0.1:{self.api_port}" + final["shortcut_draft"]["attachment_url"],
                                         headers={"Authorization": "Bearer " + self.token})
        with urllib.request.urlopen(request) as response:
            self.assertEqual(plistlib.loads(response.read())["WFWorkflowName"], "打开项目")
        result = next(m for m in messages if m.get("tool_call_id") == "w1")
        self.assertIn("total_bytes", json.loads(result["content"]))
