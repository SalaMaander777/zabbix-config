#!/usr/bin/env python3
"""Экспорт шаблонов, групп и хостов в /backups/config-<дата>/*.json (для хранения в git/папке версий).
Запуск: docker compose exec zabbix-server python3 /opt/zbx-tools/export_config.py"""
import datetime, os, sys
sys.path.insert(0, os.path.dirname(__file__))
from zbxapi import Api

api = Api()
out = f"/backups/config-{datetime.date.today():%Y-%m-%d}"
os.makedirs(out, exist_ok=True)
for kind, method in (("templates", "templates"), ("hosts", "hosts"), ("host_groups", "host_groups")):
    ids = {"templates": "templateid", "hosts": "hostid", "host_groups": "groupid"}[kind]
    getm = {"templates": "template.get", "hosts": "host.get", "host_groups": "hostgroup.get"}[kind]
    objs = [o[ids] for o in api.call(getm, {"output": [ids]})]
    if not objs:
        continue
    # порциями: экспорт всех встроенных шаблонов одним запросом не помещается в память PHP
    for n, i in enumerate(range(0, len(objs), 25), 1):
        data = api.call("configuration.export", {"format": "json", "options": {method: objs[i:i + 25]}})
        name = f"{out}/{kind}-{n:03d}.json"
        open(name, "w", encoding="utf-8").write(data)
    print("экспорт:", kind, len(objs), "объектов")
