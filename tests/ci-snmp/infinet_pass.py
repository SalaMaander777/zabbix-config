#!/usr/bin/python3
"""Имитатор Infinet R5000 для CI: подагент net-snmp (pass_persist) с ответами на числовые OID
из templates/infinet_r5000_snmp.yaml. IF-MIB и sysDescr отдаёт сам snmpd."""
import sys

B = "1.3.6.1.4.1.3942.1.1"


def o(s):
    return tuple(int(x) for x in s.strip().strip(".").split("."))


DATA = {}


def add(oid, typ, val):
    DATA[o(oid)] = (typ, val)


# AQUAMINT-MIB / AQUASYSTEM-MIB, скаляры
add(B + ".5.1.1.5.0", "integer", 1)          # mintLinkStatus: up(1)
add(B + ".3.7.0", "integer", 453)            # sysTemperature, 0.1 °C -> 45.3
add(B + ".3.6.0", "gauge", 12)               # sysCpu, %
add(B + ".3.14.0", "string", "5.5.1")        # sysSoftwareVersion
add(B + ".3.15.0", "string", "R5000-CI")     # sysModel
# mintNodesTable, индекс = ifIndex радиоинтерфейса (7)
for col, typ, val in ((8, "string", "ci-node"), (4, "integer", 1), (5, "integer", 2), (26, "integer", -95)):
    add("%s.5.1.1.1.1.%d.7" % (B, col), typ, val)
# mintLinksTable, индекс = ifIndex.MAC соседа (6 октетов)
IDX = "7.0.17.34.51.68.85"
for col, typ, val in ((3, "string", "ci-peer"), (5, "integer", 25), (6, "integer", 24),
                      (30, "integer", -60), (9, "integer", 100000), (10, "integer", 90000),
                      (19, "integer", 3), (28, "integer", 200)):
    add("%s.5.1.1.2.1.%d.%s" % (B, col, IDX), typ, val)

KEYS = sorted(DATA)


def fmt(oid):
    return "." + ".".join(map(str, oid))


def answer(oid):
    typ, val = DATA[oid]
    print(fmt(oid))
    print(typ)
    print(val)


def main():
    while True:
        line = sys.stdin.readline()
        if not line:
            return
        cmd = line.strip()
        if cmd == "PING":
            print("PONG")
        elif cmd == "get":
            oid = o(sys.stdin.readline())
            if oid in DATA:
                answer(oid)
            else:
                print("NONE")
        elif cmd == "getnext":
            oid = o(sys.stdin.readline())
            nxt = next((k for k in KEYS if k > oid), None)
            if nxt is None:
                print("NONE")
            else:
                answer(nxt)
        elif cmd == "set":
            sys.stdin.readline()
            sys.stdin.readline()
            print("not-writable")
        else:
            print("NONE")
        sys.stdout.flush()


if __name__ == "__main__":
    main()
