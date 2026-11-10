# Офлайн-комплект

## Перенос
Интернета нет ни на одном компьютере объекта (ни на сервере, ни на рабочих местах, ни на тестовой Windows 11). Комплект скачивается на машине с интернетом (Mac), копируется на USB-носитель (NTFS или exFAT: `images.tar` и установщик Docker больше 500 МБ) и переносится. На объекте после копирования проверяется `SHA256SUMS` (делает `load-and-start.ps1`). Ни один скрипт целевой машины в сеть не ходит.

## Как получить
1. **GitHub Actions** (рекомендуется): workflow `offline-bundle` собирает комплект на amd64, запускает стек, импортирует шаблоны, проверяет бэкап и выкладывает артефакт `zabbix-offline` (страница запуска workflow → Artifacts). Бинарные файлы в git не хранятся (ограничение размера), поэтому «всё необходимое» лежит в артефакте.
2. **Вручную на Mac**: `scripts/build-offline-bundle.sh` → `dist/zabbix-offline-<дата>/`.

## Состав
- `images.tar`: postgres, zabbix-server-custom (с python3), zabbix-web-nginx-pgsql, zabbix-agent2 (все linux/amd64).
- `installers/`:
  - `DockerDesktopInstaller.exe` (последняя версия на момент сборки; лицензию проверить);
  - `wsl.*.x64.msi` (WSL с GitHub Releases microsoft/WSL);
  - `zabbix_agent2-<версия>-windows-amd64-openssl.msi` для Windows 10/11;
  - `zabbix_agent-<версия>-windows-amd64/i386-openssl.msi` (классический агент) для Windows 7. По требованиям Zabbix 7.0 агент 2 поддерживается начиная с Windows 10/Server 2016, классический агент - с Windows XP/Server 2003 (сверить с документацией, проверить на тестовой Win7).
- `docker-compose.yml`, `.env.example`, `scripts/`, `zabbix/`, `templates/`, `docs/`, `SHA256SUMS`.

## Чего в комплекте нет
- Всё для варианта «ВМ Linux в Hyper-V» (целевая Windows 10 LTSC, см. `docs/WINDOWS-TARGET.md`): добавляется после решения заказчика.
- MIB Infinet, руководства R&S, PDF документации Zabbix.
- Подложка/тайлы карты (после выбора варианта, `docs/MAPS.md`).

## Установка на Windows 11
1. Скопировать папку комплекта, например в `C:\zabbix`.
2. PowerShell от администратора: `Set-ExecutionPolicy -Scope Process Bypass; cd C:\zabbix; .\scripts\install-docker-win11.ps1`
3. Перезагрузка, запустить Docker Desktop, принять лицензию, включить автозапуск при входе.
4. `.\scripts\load-and-start.ps1`, далее `docs/RUNBOOK.md` с шага 4.
