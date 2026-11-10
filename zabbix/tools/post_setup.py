#!/usr/bin/env python3
"""Первичная настройка (идемпотентно): хранение, группы хостов, импорт шаблонов.
Запуск: docker compose exec zabbix-server python3 /opt/zbx-tools/post_setup.py
Структура групп - ЧЕРНОВАЯ, согласуется с заказчиком (docs/DECISIONS.md)."""
import glob, os, sys
sys.path.insert(0, os.path.dirname(__file__))
from zbxapi import Api

GROUPS = ["Регион/Москва", "Регион/Московская область",
          "Роль/Cisco", "Роль/Infinet", "Роль/Windows ПК", "Роль/ESMD"]

api = Api()
api.call("housekeeping.update", {
    "hk_history_global": "1", "hk_history": os.environ.get("ZBX_HISTORY", "90d"),
    "hk_trends_global": "1", "hk_trends": os.environ.get("ZBX_TRENDS", "365d")})
print("housekeeping: ok")

have = {g["name"] for g in api.call("hostgroup.get", {"output": ["name"]})}
for g in GROUPS:
    if g not in have:
        api.call("hostgroup.create", {"name": g})
        print("группа создана:", g)

for f in sorted(glob.glob("/opt/templates/*.yaml")):
    api.call("configuration.import", {
        "format": "yaml", "source": open(f, encoding="utf-8").read(),
        "rules": {"template_groups": {"createMissing": True, "updateExisting": True},
                  "templates": {"createMissing": True, "updateExisting": True},
                  "items": {"createMissing": True, "updateExisting": True},
                  "triggers": {"createMissing": True, "updateExisting": True},
                  "valueMaps": {"createMissing": True, "updateExisting": True}}})
    print("шаблон импортирован:", os.path.basename(f))
