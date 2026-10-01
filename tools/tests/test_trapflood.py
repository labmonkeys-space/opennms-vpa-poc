# Copyright 2026 Ronny Trommer <ronny@no42.org>
# SPDX-License-Identifier: Apache-2.0
import os
import socket
import sys
import threading
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
import trapflood  # noqa: E402


def parse(b):
    """Decode one BER TLV: return (tag, value, rest)."""
    tag, n = b[0], b[1]
    i = 2
    if n & 0x80:
        k = n & 0x7F
        n = int.from_bytes(b[2:2 + k], "big")
        i = 2 + k
    return tag, b[i:i + n], b[i + n:]


def children(b):
    out = []
    while b:
        tag, val, b = parse(b)
        out.append((tag, val))
    return out


class Encoding(unittest.TestCase):
    def test_integer_minimal_twos_complement(self):
        self.assertEqual(trapflood.integer(0), b"\x02\x01\x00")
        self.assertEqual(trapflood.integer(127), b"\x02\x01\x7f")
        self.assertEqual(trapflood.integer(128), b"\x02\x02\x00\x80")
        self.assertEqual(trapflood.integer(5, 0x43), b"\x43\x01\x05")

    def test_oid_base128(self):
        self.assertEqual(trapflood.oid("1.3.6.1"), b"\x06\x03\x2b\x06\x01")
        self.assertEqual(trapflood.oid("1.3.6.1.4.1.200"), b"\x06\x07\x2b\x06\x01\x04\x01\x81\x48")

    def test_linkdown_pdu_structure(self):
        msg = trapflood.linkdown_pdu("public", 9, 1234, 7)
        tag, body, rest = parse(msg)
        self.assertEqual((tag, rest), (0x30, b""))
        (vt, version), (ct, community), (pt, pdu) = children(body)
        self.assertEqual(version, b"\x01")          # SNMPv2c
        self.assertEqual(community, b"public")
        self.assertEqual(pt, 0xA7)                   # SNMPv2-Trap-PDU
        _, _, _, (st, vbl) = children(pdu)
        vbs = [children(v) for _, v in children(vbl)]
        self.assertEqual(len(vbs), 5)
        self.assertEqual(vbs[1][1][1], trapflood.oid(trapflood.LINKDOWN)[2:])
        self.assertEqual(vbs[2][0][1], trapflood.oid(trapflood.IFINDEX + ".7")[2:])
        self.assertEqual(vbs[2][1], (0x02, b"\x07"))


class Sending(unittest.TestCase):
    def test_sends_exact_count_and_cycles_keys(self):
        rx = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        rx.bind(("127.0.0.1", 0))
        rx.settimeout(2)
        got = []

        def recv():
            try:
                while len(got) < 100:
                    got.append(rx.recv(2048))
            except socket.timeout:
                pass

        t = threading.Thread(target=recv)
        t.start()
        rc = trapflood.main(["--dest", f"127.0.0.1:{rx.getsockname()[1]}", "--rate", "500",
                             "--duration", "0.2", "--keys", "3", "--source", "127.0.0.1"])
        t.join()
        rx.close()
        self.assertEqual(rc, 0)
        self.assertEqual(len(got), 100)
        self.assertEqual(len(set(got)), 3)


if __name__ == "__main__":
    unittest.main()
