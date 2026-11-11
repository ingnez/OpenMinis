# -*- coding: utf-8 -*-
"""Clash / mihomo YAML 订阅导入（全是假节点）。PyYAML 装没装两种都测。"""
import base64
import sys
import unittest
from unittest import mock

import cloud_clash
import cloud_proxy

FAKE_UUID = "00000000-1111-2222-3333-444444444444"

CLASH = f"""
mixed-port: 7890
proxies:
  - {{name: "假 SS", type: ss, server: 192.0.2.1, port: 8388, cipher: aes-256-gcm, password: "fake-pass"}}
  - name: 假 REALITY
    type: vless
    server: example.invalid
    port: 443
    uuid: {FAKE_UUID}
    network: tcp
    tls: true
    flow: xtls-rprx-vision
    servername: www.example.com
    client-fingerprint: chrome
    reality-opts:
      public-key: FAKEPUBLICKEYFAKEPUBLICKEYFAKEPUBLICKEY12
      short-id: 0123abcd
  - name: 假 trojan ws
    type: trojan
    server: example.invalid
    port: 443
    password: fake-trojan
    sni: example.invalid
    network: ws
    ws-opts:
      path: /fake
      headers:
        Host: cdn.example.invalid
  - {{name: 假 vmess, type: vmess, server: 198.51.100.2, port: 10086, uuid: {FAKE_UUID}, alterId: 0, cipher: auto, tls: true, network: grpc, grpc-opts: {{grpc-service-name: fakesvc}}}}
  - {{name: 假 hy2, type: hysteria2, server: example.invalid, port: 8443, password: fake-hy, sni: example.invalid, skip-cert-verify: true}}
  - {{name: 不支持, type: wireguard, server: 192.0.2.9, port: 51820}}
proxy-groups:
  - {{name: 节点选择, type: select, proxies: [假 SS]}}
rules:
  - MATCH,节点选择
"""


class ClashImport(unittest.TestCase):
    def check(self):
        nodes, skipped, why = cloud_proxy.parse_subscription(CLASH)
        self.assertEqual([n["type"] for n in nodes], ["ss", "vless", "trojan", "vmess", "hysteria2"])
        self.assertEqual(skipped, 1)
        self.assertIn("wireguard", why)
        names = [n["name"] for n in nodes]
        self.assertIn("假 REALITY", names)
        reality = nodes[1]["outbound"]
        self.assertEqual(reality["uuid"], FAKE_UUID)
        self.assertEqual(reality["tls"]["reality"]["short_id"], "0123abcd")
        self.assertEqual(reality["flow"], "xtls-rprx-vision")
        trojan = nodes[2]["outbound"]
        self.assertEqual(trojan["transport"]["type"], "ws")
        self.assertEqual(trojan["transport"]["path"], "/fake")
        self.assertEqual(nodes[3]["outbound"]["transport"]["service_name"], "fakesvc")
        self.assertTrue(nodes[4]["outbound"]["tls"]["insecure"])

    def test_with_mini_parser(self):
        with mock.patch.dict(sys.modules, {"yaml": None}):
            self.check()

    def test_with_pyyaml_if_present(self):
        try:
            import yaml  # noqa: F401
        except ImportError:
            self.skipTest("没装 PyYAML")
        self.check()

    def test_base64_wrapped_clash(self):
        with mock.patch.dict(sys.modules, {"yaml": None}):
            nodes, _, _ = cloud_proxy.parse_subscription(base64.b64encode(CLASH.encode()).decode())
        self.assertEqual(len(nodes), 5)

    def test_empty_proxies_is_clear_error(self):
        with self.assertRaises(cloud_proxy.ProxyError) as e:
            cloud_proxy.parse_subscription("proxies: []\nrules: []\n")
        self.assertIn("没有", str(e.exception))

    def test_version_bumped_together(self):
        import os, re
        import cloud_agent_server
        self.assertEqual(cloud_agent_server.AGENT_VERSION, "2.49.0")
        here = os.path.dirname(os.path.abspath(__file__))
        swift = open(os.path.join(here, "..", "src/ios/Views/Chat/AIChatView/Cloud/CloudLinkSupervisor.swift"), encoding="utf-8").read()
        self.assertEqual(re.search(r'bundledAgentVersion = "([^"]+)"', swift).group(1), "2.49.0")

    def test_plain_links_still_work(self):
        link = "trojan://fake@example.invalid:443?sni=example.invalid#t"
        nodes, _, _ = cloud_proxy.parse_subscription(link)
        self.assertEqual(nodes[0]["type"], "trojan")


if __name__ == "__main__":
    unittest.main()
