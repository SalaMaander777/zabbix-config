"""CI: хосты ESMD и EB500 на фиктивном приборе, принудительный опрос, проверка зависимых элементов."""
import sys, time
sys.path.insert(0, "/opt/zbx-tools")
from zbxapi import Api
a = Api()
gid = a.call("hostgroup.get", {"filter": {"name": ["Роль/ESMD"]}})[0]["groupid"]
res = {}
for host, tpl in (("ci-eb500", "EB500 ICMP and SCPI"), ("ci-esmd", "ESMD ICMP and TCP")):
    tid = a.call("template.get", {"filter": {"host": [tpl]}})[0]["templateid"]
    hid = a.call("host.create", {"host": host, "groups": [{"groupid": gid}], "templates": [{"templateid": tid}],
                 "interfaces": [{"type": 1, "main": 1, "useip": 1, "ip": "127.0.0.1", "dns": "", "port": "10050"}]})["hostids"][0]
    res[host] = hid
time.sleep(70)  # конфигурация попадает в кэш сервера (CacheUpdateFrequency 60s по умолчанию)
for host, hid in res.items():
    master = [i for i in a.call("item.get", {"hostids": hid, "output": ["itemid", "key_"]}) if i["key_"].startswith("esmd_check.py[json")]
    assert master, f"{host}: нет мастер-элемента"
    a.call("task.create", [{"type": 6, "request": {"itemid": master[0]["itemid"]}}])
ok = True
for _ in range(30):
    time.sleep(5)
    ok = True
    for host, hid in res.items():
        items = a.call("item.get", {"hostids": hid, "output": ["name", "key_", "lastvalue", "lastclock", "state", "error"], "filter": {"type": 18}})
        got = {i["name"]: i["lastvalue"] for i in items if i["lastclock"] != "0"}
        if not got or not any("IDN" in n or "дентиф" in n for n in got):
            ok = False
    if ok:
        break
for host, hid in res.items():
    print("==", host)
    for i in a.call("item.get", {"hostids": hid, "output": ["name", "lastvalue", "lastclock", "state", "error"], "filter": {"type": [10, 18]}}):
        print(f"  {i['name']!r}: {i['lastvalue']!r} state={i['state']} {i['error']}")
assert ok, "зависимые элементы не получили значений"
print("SCPI e2e: OK")
