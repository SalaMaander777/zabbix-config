#!/usr/bin/env python3
"""Экспорт групп, шаблонов и хостов в /backups/config-<дата>/*.json (для хранения в git/папке версий).
Запуск: docker compose exec zabbix-server python3 /opt/zbx-tools/export_config.py
Внимание: экспорт хостов содержит параметры интерфейсов (в т.ч. SNMP community / ключи SNMPv3, если
заданы прямо в хосте, а не в секретных макросах); папку backups хранить как закрытую."""
import datetime, os, sys
sys.path.insert(0, os.path.dirname(__file__))
from zbxapi import Api

# (имя файла, метод *.get, поле id, ключ options у configuration.export)
KINDS = (("template_groups", "templategroup.get", "groupid", "template_groups"),
         ("host_groups", "hostgroup.get", "groupid", "host_groups"),
         ("templates", "template.get", "templateid", "templates"),
         ("hosts", "host.get", "hostid", "hosts"))

api = Api()
out = f"/backups/config-{datetime.date.today():%Y-%m-%d}"
os.makedirs(out, exist_ok=True)
for kind, getm, idf, opt in KINDS:
    objs = [o[idf] for o in api.call(getm, {"output": [idf]})]
    if not objs:
        continue
    # порциями: экспорт всех встроенных шаблонов одним запросом не помещается в память PHP
    for n, i in enumerate(range(0, len(objs), 25), 1):
        data = api.call("configuration.export", {"format": "json", "options": {opt: objs[i:i + 25]}})
        with open(f"{out}/{kind}-{n:03d}.json", "w", encoding="utf-8") as fh:
            fh.write(data)
    print("экспорт:", kind, len(objs), "объектов")
print("каталог:", out)
