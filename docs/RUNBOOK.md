# Инструкция

## Развёртывание с нуля (Windows, без интернета)
1. Windows 11: `scripts\install-docker-win11.ps1` (WSL + Docker Desktop из `installers/`), перезагрузка. Windows 10 LTSC: см. `docs/WINDOWS-TARGET.md`.
2. Скопировать папку комплекта на диск, например `C:\zabbix`.
3. PowerShell от администратора: `cd C:\zabbix; .\scripts\load-and-start.ps1` (проверит SHA256SUMS, выполнит `docker load`, `docker compose up -d`). При первом запуске откроется `.env`: задать `POSTGRES_PASSWORD`.
4. Первичная настройка: `docker compose exec zabbix-server python3 /opt/zbx-tools/post_setup.py` (хранение 90 д/тренды 365 д, группы, шаблоны).
5. Открыть `http://<IP главного ПК>/` , вход `Admin` / `zabbix`, сразу сменить пароль и вписать новый в `.env` (`ZBX_API_PASSWORD`).
6. Файрвол Windows: открыть TCP 80 (веб) и 10051 (активные агенты) для сети.
7. Уведомления только на экране: в профиле пользователя включить Frontend notifications, звук выключить. Почту/мессенджеры не настраивать. Дашборд «Проблемы».

## Добавить устройство
Конфигурация → Узлы сети → Создать. Группа из «Регион/…» и «Роль/…».
- Cisco: интерфейс SNMP (v2c — community, v3 — security name/level), шаблон из встроенных `Cisco ...`/`Network Generic Device by SNMP`.
- Infinet: интерфейс SNMP, шаблон `Infinet Wireless R5000 (SNMP, основа)`.
- Windows: интерфейс агента, шаблон `Windows by Zabbix agent`; на ПК поставить агент, `Server=<IP сервера>`.
- ESMD / EB500: интерфейс агента не нужен; шаблоны `R&S ESMD ...` / `R&S EB500 ...`, порт в макросах `{$ESMD.PORT}` / `{$EB500.PORT}` (5555). Группа `Роль/EB500` создаётся `post_setup.py`.

## Бэкап и восстановление
- Бэкап: `scripts\backup.ps1` (pg_dump + экспорт JSON в `backups\`). Планировщик: `schtasks /Create /SC DAILY /ST 03:00 /TN ZabbixBackup /TR "powershell -File C:\zabbix\scripts\backup.ps1" /RU SYSTEM`.
- Восстановление: `scripts\restore.ps1 backups\zabbix-<дата>.dump`. Приёмочная проверка восстановления на чистой копии обязательна и пока не проводилась.
- Папку `backups` периодически копировать на внешний носитель.

## Обновление
Только по решению заказчика: на Mac изменить `ZBX_VERSION`, прогнать `scripts/build-offline-bundle.sh`, сделать бэкап, перенести комплект, `load-and-start.ps1`. Читать upgrade notes Zabbix.

## Время
Контейнеры берут время хоста. На Windows задать источник времени в сети: `w32tm /config /manualpeerlist:"<NTP-сервер>" /syncfromflags:manual /update`. Если NTP нет, выбрать один эталон (часы главного ПК) и синхронизировать остальные с ним. Часовой пояс: `PHP_TZ` в `.env`.

## Автозапуск
Контейнеры имеют `restart: unless-stopped`. Остаётся запустить сам Docker после перезагрузки: см. вопрос в DECISIONS. Проверить принудительной перезагрузкой.
