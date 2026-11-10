# Zabbix 7.0 LTS для офлайн-сети

Мониторинг Cisco, Infinet R5000, R&S ESMD/EB500 и ПК Windows в сети без интернета. Стек: PostgreSQL + zabbix-server (с python3) + zabbix-web + карта `zabbix-map`, всё в Docker. На главном компьютере (Windows 10 LTSC 2019) стек работает в готовой виртуальной машине Hyper-V; запасные варианты — VirtualBox или Docker Desktop на Windows 11.

**Инструкция по развёртыванию: [`docs/DEPLOY.md`](docs/DEPLOY.md).** Памятка: `docs/RUNBOOK.md`. Решения и открытые вопросы: `docs/DECISIONS.md`.

Комплекты для переноса собирает GitHub Actions (вкладка Actions → Artifacts):
- `vm-image` → `zabbix-vm` — диск ВМ (Hyper-V и VirtualBox) и скрипты;
- `offline-bundle` → `zabbix-offline` — образы, агенты, браузеры, установщики, документация.

| Путь | Назначение |
|---|---|
| `docker-compose.yml`, `docker-compose.map.yml`, `.env.example` | стек и карта |
| `server/Dockerfile` | образ сервера с python3 |
| `zabbix/tools` | первичная настройка, экспорт конфигурации (Zabbix API) |
| `zabbix/externalscripts/esmd_check.py` | опрос ESMD/EB500 по SCPI |
| `templates/` | шаблоны Infinet R5000, ESMD, EB500 |
| `map/` | карта Москвы и области, выгрузка в Excel |
| `vm/` | сборка и тест образа ВМ |
| `scripts/` | сборка комплекта; установка, бэкап, восстановление на Windows; Hyper-V, VirtualBox, precheck |
| `tests/`, `.github/workflows/` | автотесты и CI (`offline-bundle`, `vm-image`, `ps-check`) |
| `docs/` | документация |
