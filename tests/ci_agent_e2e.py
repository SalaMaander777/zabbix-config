"""CI: связка агент Zabbix <-> сервер. Контейнер zabbix-agent2 (профиль agent), хост с шаблоном
'Linux by Zabbix agent', пассивные проверки по имени контейнера."""
import sys, time
sys.path.insert(0, "/opt/zbx-tools")
from zbxapi import Api
a = Api()
gid = a.call("hostgroup.get", {"filter": {"name": ["Linux servers"]}})[0]["groupid"]
tid = a.call("template.get", {"filter": {"host": ["Linux by Zabbix agent"]}})[0]["templateid"]
hid = a.call("host.create", {"host": "ci-agent", "groups": [{"groupid": gid}], "templates": [{"templateid": tid}],
             "interfaces": [{"type": 1, "main": 1, "useip": 0, "ip": "", "dns": "zabbix-agent2", "port": "10050"}]})["hostids"][0]
t0, last, ok = time.time(), 0, False
while time.time() - t0 < 180 and not ok:
    time.sleep(10)
    its = a.call("item.get", {"hostids": hid, "output": ["itemid", "key_", "type", "lastvalue", "lastclock", "error"],
                              "filter": {"type": 0}})
    if time.time() - last > 40:
        last = time.time()
        for i in its:
            try:
                a.call("task.create", [{"type": 6, "request": {"itemid": i["itemid"]}}])
            except Exception:
                pass
    ping = [i for i in its if i["key_"] == "agent.ping" and i["lastclock"] != "0"]
    ok = bool(ping) and ping[0]["lastvalue"] == "1"
    print(f"[{int(time.time() - t0)} c] agent.ping:", ping and ping[0]["lastvalue"])
got = [(i["key_"], i["lastvalue"]) for i in its if i["lastclock"] != "0"]
print("значений от агента:", len(got), got[:6])
ifc = a.call("host.get", {"hostids": hid, "selectInterfaces": ["available", "error"]})[0]["interfaces"][0]
assert ok and ifc["available"] == "1", f"агент не отвечает серверу: {ifc}"
print("agent e2e: OK")
