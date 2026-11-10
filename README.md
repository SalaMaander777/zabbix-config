# Zabbix 7.0 LTS в Docker для офлайн-сети

Стек: PostgreSQL + zabbix-server (с python3) + zabbix-web (nginx) + опционально zabbix-agent2.
Собирается на Mac (интернет), переносится на Windows 10 Pro/Enterprise без интернета.

| Путь | Назначение |
|---|---|
| `docker-compose.yml`, `.env.example` | стек, секреты в `.env` |
| `server/Dockerfile` | образ сервера + python3 |
| `zabbix/externalscripts`, `zabbix/mibs` | тома внешних скриптов и MIB |
| `zabbix/tools` | скрипты API: первичная настройка, экспорт конфигурации |
| `templates/` | шаблоны Infinet (основа) и ESMD (ICMP/TCP) |
| `scripts/` | сборка офлайн-комплекта, загрузка, бэкап, восстановление |
| `docs/` | решения, runbook, карты, ESMD, Infinet, офлайн-комплект |

**Полная инструкция по развёртыванию: `docs/DEPLOY.md`.** Кратко: `docs/RUNBOOK.md`. Отступления от ТЗ и открытые вопросы: `docs/DECISIONS.md`.

**Статус:** конфигурация написана, `docker compose config` и разбор YAML проходят. Образы не запускались, шаблоны в Zabbix не импортировались, офлайн-комплект на чистой Windows не проверялся: это нужно сделать до выезда (раздел 5 ТЗ).
