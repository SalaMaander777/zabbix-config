# Что готовить заранее (с интернетом)
Автоматически (`scripts/build-offline-bundle.sh` на Mac): `images.tar` (amd64), compose, скрипты, `SHA256SUMS`.

Вручную, положить в `installers/` (версии и ссылки не зафиксированы: требует проверки на момент сборки):
- Docker Desktop for Windows (проверить лицензию) или пакеты для Docker Engine в WSL2.
- Обновление WSL2 / компоненты Windows, нужные для Docker (проверить сборку Windows 10 на целевой машине).
- Zabbix agent для Windows 10/11 (линейка 7.0 LTS) и **отдельно для Windows 7**: какая версия поддерживает Win7, определить по документации Zabbix и проверить на тесте.
- MIB Cisco (при необходимости) и Infinet → `zabbix/mibs/`.
- PDF документации Zabbix 7.0 и руководства R&S ESMD.
- Подложка/тайлы карты: после выбора варианта (`docs/MAPS.md`).
