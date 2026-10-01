# Copyright 2026 Ronny Trommer <ronny@no42.org>
# SPDX-License-Identifier: Apache-2.0
import os
import sys
import tempfile
import unittest
import xml.etree.ElementTree as ET

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
import requisition  # noqa: E402

MI = "{http://xmlns.opennms.org/xsd/config/model-import}"
FS = "{http://xmlns.opennms.org/xsd/config/foreign-source}"


class Generator(unittest.TestCase):
    def test_pool_addresses_come_first_then_synthetic(self):
        pool = requisition.pool_from("198.51.100.0/24", 3)
        self.assertEqual(pool, ["198.51.100.1", "198.51.100.2", "198.51.100.3"])
        root = ET.fromstring(requisition.requisition("poc-scale", 5, "poc", pool))
        nodes = root.findall(f"{MI}node")
        ips = [n.find(f"{MI}interface").get("ip-addr") for n in nodes]
        self.assertEqual(len(nodes), 5)
        self.assertEqual(ips[:3], pool)
        self.assertTrue(all(ip.startswith("100.") for ip in ips[3:]))
        self.assertEqual(len(set(ips)), 5)
        self.assertEqual(nodes[0].get("node-label"), "n00001")
        self.assertEqual({n.get("location") for n in nodes}, {"poc"})
        self.assertEqual({n.find(f"{MI}interface").get("snmp-primary") for n in nodes}, {"N"})

    def test_foreign_source_has_no_detectors_or_policies(self):
        root = ET.fromstring(requisition.foreign_source("poc-scale"))
        self.assertEqual(root.get("name"), "poc-scale")
        self.assertEqual(list(root.find(f"{FS}detectors")), [])
        self.assertEqual(list(root.find(f"{FS}policies")), [])

    def test_cli_writes_both_files(self):
        with tempfile.TemporaryDirectory() as d:
            rc = requisition.main(["--nodes", "20000", "--out-dir", d,
                                   "--source-subnet", "198.51.100.0/24", "--sources", "200"])
            self.assertEqual(rc, 0)
            root = ET.parse(os.path.join(d, "requisition.xml")).getroot()
            self.assertEqual(len(root.findall(f"{MI}node")), 20000)
            self.assertTrue(os.path.exists(os.path.join(d, "foreign-source.xml")))


if __name__ == "__main__":
    unittest.main()
