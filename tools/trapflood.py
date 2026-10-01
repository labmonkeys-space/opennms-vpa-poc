#!/usr/bin/env python3
# Copyright 2026 Ronny Trommer <ronny@no42.org>
# SPDX-License-Identifier: Apache-2.0
#
# SNMPv2c linkDown trap generator for the VPA campaign.
#
# Each trap carries ifIndex, ifAdminStatus and ifOperStatus for one interface
# index. Cycling the index over --keys values spreads the load over that many
# alarms per source if the alarm is keyed by ifIndex (Task 6 measures it).
# Traps go round robin from every --source address, so each pool address
# matches one inventoried node.
#
# PDUs are encoded once per key before sending starts, so the hot loop is a
# sendto. The printed totals are the sent figure for reconciliation.

import argparse
import socket
import sys
import time

SYSUPTIME = "1.3.6.1.2.1.1.3.0"
TRAPOID = "1.3.6.1.6.3.1.1.4.1.0"
LINKDOWN = "1.3.6.1.6.3.1.1.5.3"
IFINDEX = "1.3.6.1.2.1.2.2.1.1"
IFADMIN = "1.3.6.1.2.1.2.2.1.7"
IFOPER = "1.3.6.1.2.1.2.2.1.8"


def _len(n: int) -> bytes:
    if n < 0x80:
        return bytes([n])
    b = n.to_bytes((n.bit_length() + 7) // 8, "big")
    return bytes([0x80 | len(b)]) + b


def tlv(tag: int, val: bytes) -> bytes:
    return bytes([tag]) + _len(len(val)) + val


def integer(v: int, tag: int = 0x02) -> bytes:
    return tlv(tag, v.to_bytes(v.bit_length() // 8 + 1, "big", signed=True))


def oid(dotted: str) -> bytes:
    p = [int(x) for x in dotted.split(".")]
    out = bytearray([40 * p[0] + p[1]])
    for n in p[2:]:
        chunk = [n & 0x7F]
        n >>= 7
        while n:
            chunk.append(0x80 | (n & 0x7F))
            n >>= 7
        out += bytes(reversed(chunk))
    return tlv(0x06, bytes(out))


def seq(b: bytes) -> bytes:
    return tlv(0x30, b)


def varbind(name: str, value: bytes) -> bytes:
    return seq(oid(name) + value)


def linkdown_pdu(community: str, request_id: int, uptime: int, ifindex: int) -> bytes:
    vbs = (varbind(SYSUPTIME, integer(uptime, 0x43))
           + varbind(TRAPOID, oid(LINKDOWN))
           + varbind(f"{IFINDEX}.{ifindex}", integer(ifindex))
           + varbind(f"{IFADMIN}.{ifindex}", integer(2))
           + varbind(f"{IFOPER}.{ifindex}", integer(2)))
    pdu = tlv(0xA7, integer(request_id) + integer(0) + integer(0) + seq(vbs))
    return seq(integer(1) + tlv(0x04, community.encode()) + pdu)


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description="SNMPv2c linkDown trap generator")
    ap.add_argument("--dest", required=True, help="host:port")
    ap.add_argument("--rate", type=float, required=True, help="traps per second, all sources together")
    ap.add_argument("--duration", type=float, required=True, help="seconds")
    ap.add_argument("--keys", type=int, default=100, help="distinct ifIndex values per source")
    ap.add_argument("--source", action="append", default=[], help="source address to bind; repeat for a pool")
    ap.add_argument("--community", default="public")
    a = ap.parse_args(argv)

    host, port = a.dest.rsplit(":", 1)
    dest = (host, int(port))
    socks = []
    for addr in a.source or [""]:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.bind((addr, 0))
        socks.append(s)
    uptime = int(time.monotonic() * 100) & 0xFFFFFFFF
    pdus = [linkdown_pdu(a.community, k + 1, uptime, k + 1) for k in range(a.keys)]

    total = int(a.rate * a.duration)
    interval = 1.0 / a.rate
    sent = errors = 0
    start = time.perf_counter()
    for i in range(total):
        target = start + i * interval
        while True:
            now = time.perf_counter()
            if now >= target:
                break
            if target - now > 0.002:
                time.sleep(target - now - 0.001)
        try:
            socks[i % len(socks)].sendto(pdus[(i // len(socks)) % a.keys], dest)
            sent += 1
        except OSError:
            errors += 1
    elapsed = time.perf_counter() - start
    rate = sent / elapsed if elapsed else 0.0
    print(f"sent {sent} errors {errors} elapsed {elapsed:.2f}s rate {rate:.1f}/s sources {len(socks)} keys {a.keys}")
    return 0 if errors == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
