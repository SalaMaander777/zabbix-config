"""CI: SNMP-сквозная проверка на имитаторе (контейнер snmpsim, net-snmp).
1) хост с шаблоном 'Infinet R5000 SNMP' по SNMPv2c: LLD находит узел/линк/интерфейсы, элементы получают
   значения (проверяются и преобразования: x0.1, x1000, x0.01);
2) хост по SNMPv3 authPriv (SHA1/AES128, пользователь zbxmon, пароли в секретных макросах, как в docs/CISCO.md)
   с встроенным шаблоном 'Cisco IOS by SNMP' и простым элементом sysDescr."""
import sys, time
sys.path.insert(0, "/opt/zbx-tools")
from zbxapi import Api

DEADLINE = 240
a = Api()


def one(method, params, what):
    r = a.call(method, params)
    assert r, f"не найдено: {what}"
    return r[0]


def group(name):
    return one("hostgroup.get", {"filter": {"name": [name]}}, name)["groupid"]


def tpl_id(name):
    return one("template.get", {"filter": {"host": [name]}}, f"шаблон {name!r}")["templateid"]


# Имена встроенных шаблонов Zabbix 7.0 (проверка для docs/CISCO.md и docs/DEPLOY.md)
names = sorted(t["host"] for t in a.call("template.get", {"output": ["host"]}) if "Cisco" in t["host"] or "Windows" in t["host"])
print("встроенные шаблоны Cisco/Windows:", names)
assert "Cisco IOS by SNMP" in names, "нет шаблона 'Cisco IOS by SNMP'"
assert "Windows by Zabbix agent" in names, "нет шаблона 'Windows by Zabbix agent'"

snmp_if = {"type": 2, "main": 1, "useip": 0, "ip": "", "dns": "snmpsim", "port": "161"}
h2 = a.call("host.create", {
    "host": "ci-infinet", "groups": [{"groupid": group("Роль/Infinet")}],
    "templates": [{"templateid": tpl_id("Infinet R5000 SNMP")}],
    "interfaces": [dict(snmp_if, details={"version": 2, "bulk": 1, "community": "public"})]})["hostids"][0]
h3 = a.call("host.create", {
    "host": "ci-cisco-v3", "groups": [{"groupid": group("Роль/Cisco")}],
    "templates": [{"templateid": tpl_id("Cisco IOS by SNMP")}],
    "macros": [{"macro": "{$SNMPV3_AUTH}", "value": "zbx-auth-pass1", "type": 1},
               {"macro": "{$SNMPV3_PRIV}", "value": "zbx-priv-pass1", "type": 1}],
    "interfaces": [dict(snmp_if, details={
        "version": 3, "bulk": 1, "securityname": "zbxmon", "securitylevel": 2,   # authPriv
        "authprotocol": 1, "authpassphrase": "{$SNMPV3_AUTH}",                   # SHA1
        "privprotocol": 1, "privpassphrase": "{$SNMPV3_PRIV}",                   # AES128
        "contextname": ""})]})["hostids"][0]
if3 = a.call("host.get", {"hostids": h3, "selectInterfaces": ["interfaceid"]})[0]["interfaces"][0]["interfaceid"]
a.call("item.create", {"hostid": h3, "interfaceid": if3, "name": "CI sysDescr", "key_": "ci.sysdescr",
                       "type": 20, "snmp_oid": "1.3.6.1.2.1.1.1.0", "value_type": 4, "delay": "30s"})


def items(hid):
    return a.call("item.get", {"hostids": hid, "output": ["itemid", "key_", "type", "lastvalue", "lastclock", "state", "error", "flags"]})


def by_prefix(its, prefix):
    return [i for i in its if i["key_"].startswith(prefix) and i["lastclock"] != "0"]


def num(i):
    try:
        return float(i["lastvalue"])
    except ValueError:
        return None


def check_infinet(its):
    """Возвращает список невыполненных условий."""
    miss = []
    kv = {i["key_"]: i for i in its if i["lastclock"] != "0"}

    def exact(key, want):
        i = kv.get(key)
        if i is None or num(i) is None or abs(num(i) - want) > 1e-6:
            miss.append(f"{key}={i and i['lastvalue']!r}, ожидалось {want}")

    def proto(prefix, want):
        r = by_prefix(its, prefix)
        if not r or not any(num(i) is not None and abs(num(i) - want) < 1e-6 for i in r):
            miss.append(f"{prefix}*: {[i['lastvalue'] for i in r]}, ожидалось {want}")

    exact("infinet.mint.link.status", 1)
    exact("infinet.sys.temperature", 45.3)          # 453 x 0.1
    exact("infinet.sys.cpu", 12)
    proto("infinet.mint.links.count[", 1)           # LLD mintNodesTable
    proto("infinet.mint.nodes.count[", 2)
    proto("infinet.mint.noise.floor[", -95)
    proto("infinet.link.snr.in[", 25)               # LLD mintLinksTable
    proto("infinet.link.snr.out[", 24)
    proto("infinet.link.rssi[", -60)
    proto("infinet.link.bitrate.rx[", 100000 * 1000)  # Кбит/с x 1000
    proto("infinet.link.txpower[", 20)              # 200 x 0.1
    proto("net.if.status[ifOperStatus.", 1)         # LLD ifTable (интерфейсы самого snmpd)
    if not by_prefix(its, "net.if.in.errors["):
        miss.append("нет элементов ifInErrors (LLD ifTable)")
    up = kv.get("sys.uptime")
    if up is None or not (num(up) or 0) > 0:
        miss.append("sys.uptime")
    return miss


def check_v3(its):
    miss = []
    d = [i for i in its if i["key_"] == "ci.sysdescr" and i["lastclock"] != "0"]
    if not d or "CI simulator" not in d[0]["lastvalue"]:
        miss.append(f"ci.sysdescr (SNMPv3) = {d and d[0]['lastvalue']!r}")
    ifc = a.call("host.get", {"hostids": h3, "selectInterfaces": ["available", "error"]})[0]["interfaces"][0]
    if ifc["available"] != "1":
        miss.append(f"интерфейс SNMPv3 недоступен: available={ifc['available']} {ifc['error']}")
    return miss


last = 0
t0 = time.time()
miss2 = miss3 = ["не проверялось"]
while time.time() - t0 < DEADLINE:
    time.sleep(10)
    now = time.time()
    try:
        if now - last > 40:      # "проверить сейчас": правила LLD и элементы SNMP без значений
            last = now
            req = [{"type": 6, "request": {"itemid": r["itemid"]}}
                   for h in (h2, h3) for r in a.call("discoveryrule.get", {"hostids": h, "output": ["itemid"]})]
            for h in (h2, h3):
                req += [{"type": 6, "request": {"itemid": i["itemid"]}} for i in items(h)
                        if i["type"] == "20" and i["lastclock"] == "0"]
            for r in req:        # по одному: ошибка одной задачи (ещё нет в кэше) не мешает остальным
                try:
                    a.call("task.create", [r])
                except Exception as e:
                    pass
        i2, i3 = items(h2), items(h3)
        miss2, miss3 = check_infinet(i2), check_v3(i3)
    except Exception as e:
        print("ошибка опроса API:", e)
        continue
    print(f"[{int(now - t0)} c] infinet: {len(miss2)} не выполнено, v3: {len(miss3)} не выполнено")
    if not miss2 and not miss3:
        break

for h, title in ((h2, "ci-infinet"), (h3, "ci-cisco-v3")):
    its = items(h)
    ok = [i for i in its if i["lastclock"] != "0"]
    bad = [i for i in its if i["state"] == "1"]
    print(f"== {title}: элементов {len(its)}, со значениями {len(ok)}, не поддерживается {len(bad)}")
    for i in (ok if title == "ci-infinet" else ok[:15]):
        print(f"   {i['key_']} = {i['lastvalue']!r}")
    for i in bad[:10]:
        print(f"   НЕ ПОДДЕРЖИВАЕТСЯ {i['key_']}: {i['error'][:120]}")
if miss2 or miss3:
    print("Infinet:", miss2)
    print("SNMPv3:", miss3)
    sys.exit("SNMP e2e: не все проверки выполнены за %d с" % DEADLINE)
print("SNMP e2e: OK (LLD Infinet, SNMPv2c; SNMPv3 authPriv SHA/AES128)")
