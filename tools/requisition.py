#!/usr/bin/env python3
# Copyright 2026 Ronny Trommer <ronny@no42.org>
# SPDX-License-Identifier: Apache-2.0
#
# Build a detector-free foreign source and a requisition of N nodes.
# The first --sources nodes get the trap generator's pool addresses, so traps
# from those addresses match inventoried nodes. The rest get synthetic
# addresses from 100.64.0.0/10. With no detectors and no policies, Provisiond
# imports the nodes without scanning them.

import argparse
import ipaddress
import os
import sys
from xml.sax.saxutils import quoteattr

MI_NS = "http://xmlns.opennms.org/xsd/config/model-import"
FS_NS = "http://xmlns.opennms.org/xsd/config/foreign-source"


def foreign_source(name: str) -> str:
    return (f'<foreign-source xmlns="{FS_NS}" name={quoteattr(name)}>'
            "<scan-interval>1d</scan-interval><detectors/><policies/></foreign-source>")


def pool_from(cidr: str, size: int) -> list:
    hosts = ipaddress.ip_network(cidr).hosts()
    return [str(next(hosts)) for _ in range(size)]


def addresses(count: int, pool: list) -> list:
    out = list(pool[:count])
    synth = ipaddress.ip_network("100.64.0.0/10").hosts()
    while len(out) < count:
        out.append(str(next(synth)))
    return out


def requisition(name: str, count: int, location: str, pool: list) -> str:
    rows = [f"<model-import xmlns=\"{MI_NS}\" foreign-source={quoteattr(name)}>"]
    for i, ip in enumerate(addresses(count, pool), 1):
        label = f"n{i:05d}"
        rows.append(f'<node foreign-id="{label}" node-label="{label}" location={quoteattr(location)}>'
                    f'<interface ip-addr="{ip}" snmp-primary="N"/></node>')
    rows.append("</model-import>")
    return "\n".join(rows)


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description="Detector-free foreign source and requisition generator")
    ap.add_argument("--nodes", type=int, required=True)
    ap.add_argument("--out-dir", required=True)
    ap.add_argument("--name", default="poc-scale")
    ap.add_argument("--location", default="poc")
    ap.add_argument("--source-subnet", default="198.51.100.0/24")
    ap.add_argument("--sources", type=int, default=0)
    a = ap.parse_args(argv)
    pool = pool_from(a.source_subnet, a.sources) if a.sources else []
    os.makedirs(a.out_dir, exist_ok=True)
    with open(os.path.join(a.out_dir, "foreign-source.xml"), "w") as f:
        f.write(foreign_source(a.name))
    with open(os.path.join(a.out_dir, "requisition.xml"), "w") as f:
        f.write(requisition(a.name, a.nodes, a.location, pool))
    return 0


if __name__ == "__main__":
    sys.exit(main())
