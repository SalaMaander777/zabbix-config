#!/usr/bin/env python3
"""Первичная настройка (идемпотентно): хранение, группы хостов, импорт шаблонов.
Запуск: docker compose exec zabbix-server python3 /opt/zbx-tools/post_setup.py
Структура групп - ЧЕРНОВАЯ, согласуется с заказчиком (docs/DECISIONS.md)."""
import glob, os, sys
sys.path.insert(0, os.path.dirname(__file__))
from zbxapi import Api

GROUPS = ["Регион/Москва", "Регион/Московская область",
          "Роль/Cisco", "Роль/Infinet", "Роль/Windows ПК", "Роль/ESMD", "Роль/EB500"]

RULES = {"template_groups": {"createMissing": True, "updateExisting": True},
         "templates": {"createMissing": True, "updateExisting": True},
         "items": {"createMissing": True, "updateExisting": True},
         "triggers": {"createMissing": True, "updateExisting": True},
         "valueMaps": {"createMissing": True, "updateExisting": True},
         # без discoveryRules правила LLD (в т.ч. прототипы) молча не импортируются
         "discoveryRules": {"createMissing": True, "updateExisting": True},
         "graphs": {"createMissing": True, "updateExisting": True},
         "templateLinkage": {"createMissing": True}}

api = Api()   # сам ждёт готовности API (до ZBX_API_WAIT секунд)
api.call("housekeeping.update", {
    "hk_history_global": "1", "hk_history": os.environ.get("ZBX_HISTORY", "90d"),
    "hk_trends_global": "1", "hk_trends": os.environ.get("ZBX_TRENDS", "365d")})
print("housekeeping: ok")

have = {g["name"] for g in api.call("hostgroup.get", {"output": ["name"]})}
for g in GROUPS:
    if g not in have:
        api.call("hostgroup.create", {"name": g})
        print("группа создана:", g)

failed = []
files = sorted(glob.glob("/opt/templates/*.yaml"))
if not files:
    sys.exit("нет шаблонов в /opt/templates (проверьте том ./templates)")
for f in files:
    try:
        with open(f, encoding="utf-8") as fh:
            source = fh.read()
        api.call("configuration.import", {"format": "yaml", "source": source, "rules": RULES})
        print("шаблон импортирован:", os.path.basename(f))
    except Exception as e:   # один плохой файл не должен мешать остальным
        failed.append(os.path.basename(f))
        print("ОШИБКА импорта", os.path.basename(f), "-", e, file=sys.stderr)
if failed:
    sys.exit("не импортированы: " + ", ".join(failed))
