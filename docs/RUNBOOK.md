# Краткая памятка

Полная инструкция: `DEPLOY.md`. Здесь — команды на каждый день. `<IP>` — адрес сервера (IP ВМ на пути A/A2, IP Windows на пути B).

| Действие | Путь A/A2 (ВМ, консоль или `ssh zbxadmin@<IP>`) | Путь B (Docker Desktop, PowerShell в `C:\zabbix`) |
|---|---|---|
| Состояние | `cd /opt/zabbix && sudo docker compose ps` | `docker compose -f docker-compose.yml -f docker-compose.map.yml ps` |
| Логи сервера | `sudo docker compose logs zabbix-server --tail 100` | то же без `sudo`, с `-f ...` |
| Перезапуск стека | `sudo systemctl restart zabbix-stack` | `docker compose -f docker-compose.yml -f docker-compose.map.yml up -d` |
| Бэкап вручную | `sudo /opt/zabbix/scripts/backup.sh` | `.\scripts\backup.ps1` |
| Восстановление | `DEPLOY.md`, 6.4 | `.\scripts\restore.ps1 <файл.dump>` |
| Сменили пароль Admin | `sudo zbx-setapipass` | правка `ZBX_API_PASSWORD` в `.env` + `up -d` |
| Сеть ВМ | `sudo zbx-netconfig` / `--static ... --gw ... --dns ...` / `--dhcp` | — |
| Время | `timedatectl`, `chronyc sources` | часы Windows, `w32tm /query /status` |
| Переимпорт шаблонов | `sudo docker compose exec zabbix-server python3 /opt/zbx-tools/post_setup.py` | то же без `sudo` |
| Выгрузка конфигурации | `sudo docker compose exec zabbix-server python3 /opt/zbx-tools/export_config.py` | то же без `sudo` |

Адреса: веб-интерфейс `http://<IP>/`, карта и Excel `http://<IP>:8081/`.

Добавление устройств — `DEPLOY.md`, 5.4 (Cisco SNMPv3 — `CISCO.md`, Infinet — `INFINET.md`, ESMD/EB500 — `ESMD.md`).

Уведомления — только на экране: профиль пользователя → Messaging → Frontend messaging включить, звук «Never».

Обновление версии Zabbix (сейчас 7.0.32) — только по решению заказчика: `DEPLOY.md`, 6.5.
