# Zabbix в виртуальной машине Hyper-V (Windows 10 Enterprise LTSC 2019)

Docker Desktop и WSL2 на сборке 17763 невозможны (см. WINDOWS-TARGET.md). Поэтому стек работает в готовой ВМ Linux (Debian 12 + Docker Engine) под Hyper-V. Всё уже внутри образа, интернет не нужен.

## Что в комплекте (артефакт `zabbix-vm`)
- `zabbix-vm-debian12.zip` - внутри `zabbix-vm-debian12.vhdx` (диск 40 ГБ, динамический; после распаковки около 4-5 ГБ)
- `SHA256SUMS` - контрольные суммы (проверить: `Get-FileHash <файл> -Algorithm SHA256`)
- `hyperv-install.ps1`, `hyperv-create-vm.ps1` - скрипты для Windows
- этот документ

Скопируйте всё на USB-носитель, на сервере распакуйте zip на диск с запасом места (не менее 15 ГБ свободно: распакованный VHDX + его копия в `C:\Hyper-V\ZabbixVM\`).

## Требования
- Windows 10 Enterprise (подходит и LTSC 2019), x64, права администратора.
- Процессор с виртуализацией и SLAT, включённой в BIOS/UEFI (Intel VT-x, EPT). Pentium G3430 (Haswell) их имеет, но **включённость в BIOS надо проверить на месте**.
- 2 ядра и 10 ГБ ОЗУ: ВМ получает 2 vCPU и 5 ГБ, Windows остаётся ~5 ГБ.

## Почему Debian nocloud и Generation 2
- Образ основан на официальном `debian-12-nocloud-amd64` (cloud.debian.org), **не** `genericcloud`: у genericcloud урезанное облачное ядро без части драйверов, а Hyper-V нужны модули `hv_vmbus`, `hv_storvsc`, `hv_netvsc`, `hv_utils`. В nocloud стандартное ядро `linux-image-amd64`. В образ дополнительно прописаны эти модули в initramfs. cloud-init в nocloud отсутствует, загрузка без метаданных не зависает.
- В образе есть EFI-раздел и подписанный shim, поэтому ВМ создаётся как **Generation 2** с шаблоном Secure Boot `MicrosoftUEFICertificateAuthority` (для Linux его и нужно выбирать). Если Gen 2 не загрузится, создайте ВМ с параметром `-Generation 1` (образ содержит и BIOS-загрузчик).

## Шаг 1. Включить Hyper-V (один раз)
PowerShell от имени администратора, в папке со скриптами:
```
Set-ExecutionPolicy -Scope Process Bypass
.\hyperv-install.ps1
```
Скрипт проверяет виртуализацию и включает роль Hyper-V. **Перезагрузите Windows.** Если Hyper-V уже включён, скрипт сообщит об этом.

## Шаг 2. Создать и запустить ВМ
```
Set-ExecutionPolicy -Scope Process Bypass
.\hyperv-create-vm.ps1 -VhdxPath D:\zabbix-vm-debian12.vhdx
```
Скрипт покажет список физических сетевых адаптеров и попросит ввести имя того, что смотрит в локальную сеть (или передайте `-NetAdapterName "Ethernet"`). Он создаст внешний коммутатор `ZabbixExternal` (если внешнего уже нет), скопирует VHDX в `C:\Hyper-V\ZabbixVM\`, создаст ВМ `ZabbixVM` (2 vCPU, 5 ГБ, статическая память), включит автозапуск, запустит её и выведет IP. **При создании коммутатора сеть Windows пропадает на несколько секунд.** Повторный запуск безопасен: существующую ВМ скрипт не пересоздаёт.

## Шаг 3. Первый вход
Консоль: `vmconnect localhost ZabbixVM` (или Диспетчер Hyper-V, двойной щелчок по ВМ).
Логин `zbxadmin`, пароль `zbxadmin`. Система **сразу потребует сменить пароль** - задайте новый и запишите. Root-вход отключён, `sudo` у zbxadmin есть.

## Шаг 4. Статический IP
```
sudo zbx-netconfig
```
Выберите DHCP или статический адрес (IP/маска, шлюз, DNS), при необходимости - NTP-сервер. Рекомендуется статический адрес (или резервирование по MAC на DHCP-сервере), чтобы рабочие места не теряли сервер. Изменения применяются сразу, перезагрузка не нужна (SSH-сессия при этом оборвётся). Проверка: `ip -br a`.

То же без вопросов (для скриптов), адрес и шлюз проверяются:
```
sudo zbx-netconfig --static 192.168.1.10/24 --gw 192.168.1.1 --dns "192.168.1.1 8.8.8.8" --ntp ntp.local
sudo zbx-netconfig --dhcp
```

## Шаг 5. Веб-интерфейс
Откройте `http://<IP ВМ>/` с любого компьютера сети. Вход `Admin` / `zabbix`. **Сразу смените пароль Admin** в веб-интерфейсе, затем в консоли ВМ выполните `sudo zbx-setapipass` и введите тот же новый пароль: команда проверит его через API, запишет в `/opt/zabbix/.env` (`ZBX_API_PASSWORD`) и пересоздаст контейнеры `zabbix-server` и `zabbix-map`. Править `.env` вручную недостаточно: пароль попадает в контейнеры только при их пересоздании (`sudo docker compose up -d`). Пока пароль в `.env` устаревший, `backup.sh` делает дамп БД, но завершается с кодом 2 (экспорт конфигурации не прошёл), а карта не получает данные.

Карта устройств: `http://<IP ВМ>:8081/`.

**Первый запуск занимает до ~10 минут**: ВМ загружает образы Docker, поднимает БД и применяет настройку (шаблоны Infinet R5000 SNMP, ESMD ICMP and TCP, EB500 ICMP and SCPI). До этого сайт не отвечает - это нормально. Контроль:
```
systemctl status zabbix-firstboot      # active (exited) / "готово" - всё сделано
journalctl -u zabbix-firstboot -f      # ход выполнения
cd /opt/zabbix && sudo docker compose ps   # 4 контейнера Up (postgres, zabbix-server, zabbix-web, zabbix-map)
```
Если firstboot завершился ошибкой, исправьте причину и запустите `sudo systemctl restart zabbix-firstboot` (скрипт повторяем, маркер `/var/lib/zabbix-firstboot.done` создаётся только при успехе).

## Система
- Журнал systemd постоянный (переживает перезагрузку), не более 200 МБ; логи контейнеров Docker ротируются (3 файла по 10 МБ).
- Создаётся файл подкачки 2 ГБ (`/swapfile`, при первой загрузке): ОЗУ ВМ 5 ГБ.
- Автоматические обновления apt отключены (сервер офлайн); ключи хоста SSH, `machine-id` и пароль БД создаются при первой загрузке, у каждой копии образа свои.
- При каждой загрузке `zabbix-stack.service` запускает контейнеры (после `docker.service`; после первичной настройки).
- В образе нет секретов, кроме известного начального пароля `zbxadmin` (его нужно сменить при первом входе) и `Admin`/`zabbix` в веб-интерфейсе.

## Время
- Hyper-V передаёт ВМ время хоста (служба интеграции «Синхронизация времени» включена по умолчанию), chrony в ВМ использует его как источник (`/dev/ptp_hyperv`). Часовой пояс Europe/Moscow.
- Если в сети есть свой NTP-сервер, укажите его в `zbx-netconfig`. Проверка: `chronyc sources`, `timedatectl`.
- Следите, чтобы время на самой Windows было верным (иначе будет неверно и в ВМ).

## Бэкапы
Каждый день в 03:00 (`zabbix-backup.timer`) создаётся дамп БД `/opt/zabbix/backups/zabbix-ГГГГММДД-ЧЧММ.dump` (проверяется `pg_restore -l`) и экспорт конфигурации `/opt/zabbix/backups/config-ДАТА/`; хранятся 30 последних. Коды `backup.sh`: 0 - успех, 1 - дамп не создан, 2 - дамп есть, экспорт конфигурации не удался (см. `zbx-setapipass`), 3 - уже идёт другой бэкап. Вручную: `sudo /opt/zabbix/scripts/backup.sh`. Статус: `systemctl list-timers zabbix-backup.timer`.

Забрать бэкап на Windows:
```
scp -r zbxadmin@<IP ВМ>:/opt/zabbix/backups C:\ZabbixBackups
```
Про `scp` на Windows: согласно документации Microsoft, клиент OpenSSH на Windows 10 (с сборки 1809) - необязательный компонент (Feature on Demand), и **по умолчанию в 1809/LTSC он может не стоять**; добавление через «Параметры - Приложения - Дополнительные компоненты» берёт файлы из интернета, а на машине без интернета не сработает. Проверьте на месте: `ssh -V`. Если команды нет - принесите заранее на USB переносимый WinSCP (portable-версия) и копируйте им по SFTP (хост - IP ВМ, пользователь zbxadmin, папка `/opt/zabbix/backups`). Общая папка и монтирование VHDX не используются.

## Если Hyper-V включить нельзя
Запасной вариант: VirtualBox с тем же образом (диск `zabbix-vm-debian12-vdi.zip`, скрипты `virtualbox-install.ps1`, `virtualbox-create-vm.ps1`). Порядок и ограничения: `docs/DEPLOY.md`, раздел 3.7.

## Восстановление
Внутри ВМ (`/opt/zabbix`), файл дампа лежит в `/opt/zabbix/backups` (принесённый с Windows - скопируйте туда `scp`/WinSCP):
```
cd /opt/zabbix
sudo docker compose stop zabbix-server zabbix-web
sudo docker compose exec -T postgres sh -c 'pg_restore -U $POSTGRES_USER -d $POSTGRES_DB --clean --if-exists /backups/zabbix-ГГГГММДД-ЧЧММ.dump'
sudo docker compose start zabbix-server zabbix-web
```
(это аналог `scripts/restore.ps1`). Полная переустановка: образы остаются в `/opt/zabbix/images.tar`; при необходимости `sudo docker load -i /opt/zabbix/images.tar` и `sudo docker compose up -d --no-build`.

## Автозапуск после перезагрузки Windows
`hyperv-create-vm.ps1` задаёт ВМ `AutomaticStartAction=Start` с задержкой 30 с и `AutomaticStopAction=ShutDown` (при выключении Windows ВМ корректно завершается). Служба Hyper-V стартует вместе с Windows, вход пользователя не нужен. Внутри ВМ `zabbix-stack.service` при каждой загрузке запускает контейнеры. Проверка: перезагрузить Windows и через 3-5 минут открыть веб-интерфейс.

## Что проверяет CI (`vm/test-vm.sh`)
Образ грузится в QEMU дважды: UEFI + virtio (как Hyper-V Gen 2) и BIOS + AHCI + e1000 с диском VDI (как VirtualBox). В копии диска (оверлее; поставляемый образ не меняется) тест добавляет ключ SSH и `sudo` без пароля, затем проверяет: образ до загрузки (нет ключей хоста, `.env`, маркеров, `machine-id` пуст, `chage -d 0`); API и шаблоны; по SSH - службы docker/chrony/zabbix-stack/ssh, отсутствие упавших юнитов (кроме демонов `hv-*` Hyper-V, которых в QEMU быть не может), `chronyc tracking`, права `.env` 600, 4 контейнера, swap, журнал, диск, часовой пояс; `backup.sh`, ротацию 30 копий, `pg_restore` по командам из этого документа; `zbx-netconfig` (содержимое файлов, применение статики и возврат к DHCP без перезагрузки); смену пароля Admin и `zbx-setapipass`; перезагрузку ВМ - стек поднимается сам, firstboot не запускается повторно, ключи хоста и данные сохраняются.

## Что не проверено
- Реальная загрузка в Hyper-V на LTSC 2019 (в CI образ проверен только в QEMU/KVM, UEFI-прошивка OVMF, виртуальные устройства virtio): драйверы Hyper-V (модули `hv_*`), синхронизация времени через PTP, Secure Boot с шаблоном Microsoft UEFI CA и скрипты PowerShell 5.1 проверены только чтением, не запуском.
- Поддержка SLAT/виртуализации в BIOS конкретного компьютера.
- Наличие `ssh/scp` на целевой Windows (см. выше).
- Если Gen 2 не загрузится: пересоздать ВМ с `-Generation 1` (удалить ВМ в Диспетчере Hyper-V, повторить шаг 2).
