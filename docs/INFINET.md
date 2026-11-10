# Infinet Wireless R5000 (SkyMan): шаблон SNMP

Шаблон: `templates/infinet_r5000_snmp.yaml` (техническое имя `Infinet R5000 SNMP`).

**Статус: OID взяты из текста MIB производителя, на реальном устройстве не проверены.** До ввода в эксплуатацию снять `snmpwalk` с вашего R5000 (раздел «Проверка») и согласовать пороги.

## Источники (поиск 2026-11-10)

| Что | Ссылка | Что сказано в источнике |
|---|---|---|
| INFINET-MIB | [страница](https://mibs.observium.org/mib/INFINET-MIB/), [текст MIB](https://mibs.observium.org/mibs/infinet/INFINET-MIB) | `infinet ::= { enterprises 3942 }`, `iwrouter ::= { infinet 1 }` («Infinet wireless router»), `wanflex ::= { iwrouter 1 }` («Wanflex OS for Infinet wireless router») |
| AQUAMINT-MIB | [страница](https://mibs.observium.org/mib/AQUAMINT-MIB/), [текст MIB](https://mibs.observium.org/mibs/infinet/AQUAMINT-MIB) | «The mib module for MINT», `{ wanflex 5 }`, Infinet Wireless Ltd., последняя ревизия 2016-04-04 |
| AQUASYSTEM-MIB | [страница](https://mibs.observium.org/mib/AQUASYSTEM-MIB/), [текст MIB](https://mibs.observium.org/mibs/infinet/AQUASYSTEM-MIB) | «The mib module, containing various WanFlex options», `{ wanflex 3 }`, ревизии до 2018-02-26 |
| AQUARADIO-MIB | [страница](https://mibs.observium.org/mib/AQUARADIO-MIB/), [текст MIB](https://mibs.observium.org/mibs/infinet/AQUARADIO-MIB) | «The mib module for Revolution radio modules», `{ wanflex 2 }`. В шаблоне не используется |
| INFINET-XG-MIB, INFINET-XGRADIO-MIB | [XG](https://mibs.observium.org/mib/INFINET-XG-MIB), [XGRADIO](https://mibs.observium.org/mib/INFINET-XGRADIO-MIB) | «XG bridge options», ветка `{ infinet 4 }`. Это поколение InfiLINK XG, **не R5000**, в шаблоне не используется |
| Вики Infinet (сниппет поисковой выдачи) | [wiki.infinetwireless.com/x/CQSS](https://wiki.infinetwireless.com/x/CQSS) | SNMP-агент на R5000 по умолчанию выключен, его нужно включить до подключения к мониторингу. Сама страница из среды сборки недоступна («Not available in your Country») |

Где искали и не нашли: LibreNMS (ОС `infinity` там это LigoWave, не Infinet; MIB Infinet в репозитории нет), netdisco-mibs, Zabbix community templates, circitor.fr, web.archive.org (соединение сбрасывается).

### Относятся ли эти MIB к R5000

- Прямого упоминания «R5000», «InfiLINK 2x2», «InfiMAN 2x2» в текстах MIB **нет**.
- Косвенно: ветка `wanflex` описана как «Wanflex OS for Infinet wireless router», AQUAMINT-MIB как модуль протокола MINT, AQUARADIO-MIB как модуль «Revolution radio modules». R5000 работает под WANFleX с MINT (руководство R5000 называет версию ПО «MINTv1.90.11»). MIB поколения XG лежат в другой ветке (`infinet 4`) и сюда не входят.
- Про Evolution/Quanta/другие семейства в текстах MIB ничего не сказано.
- Вывод: это MIB ОС WANFleX/MINT, с высокой вероятностью применимые к R5000, но окончательное подтверждение даёт только `snmpwalk` с устройства.

### MIB-файлы в репозитории

В `zabbix/mibs/` файлы **не положены**: в текстах MIB нет лицензии или разрешения на распространение, источник (каталог Observium) условий тоже не указывает. Шаблон использует числовые OID и без MIB-файлов работает. MIB нужны только для удобства чтения `snmpwalk` по именам. Если распространение согласовано, скачать на машине с интернетом и добавить в офлайн-комплект:

```sh
cd zabbix/mibs
for m in INFINET-MIB AQUASYSTEM-MIB AQUAMINT-MIB AQUARADIO-MIB; do
  curl -fsSO "https://mibs.observium.org/mibs/infinet/$m"
done
```

SHA-256 файлов, по которым составлен шаблон:

```
5ca445a114b0a0f518289922894c60e9a82c03d116399795dd90710d1bc334d2  INFINET-MIB
b93f16ef4603d0840253629a62b1952c94fcb95c644eda0907cca458b092731c  AQUAMINT-MIB
91cb1e0c2c0840c5f1fa25c0ded1b6a6077cab1c286e8d0ffff97cc9e4cdd38a  AQUASYSTEM-MIB
24afd4289b1a7fd0944672bc471c8ac49aa6d0481b26000f52d0ac10d05fafb6  AQUARADIO-MIB
```

## Таблица OID шаблона

Цепочка: `enterprises(1.3.6.1.4.1).infinet(3942).iwrouter(1).wanflex(1)`; `aquasystemMIB = wanflex.3`, `aquamintMIB = wanflex.5`, `mintMIBObjects = aquamintMIB.1`, `mint = mintMIBObjects.1`.

Единицы и множители приведены по DESCRIPTION из MIB.

### Скаляры

| Объект | OID | Единицы по MIB | В Zabbix | MIB |
|---|---|---|---|---|
| sysUpTime | 1.3.6.1.2.1.1.3.0 | 1/100 с | ×0.01, uptime | MIB-II |
| sysDescr | 1.3.6.1.2.1.1.1.0 | текст | текст | MIB-II |
| mintLinkStatus | 1.3.6.1.4.1.3942.1.1.5.1.1.5.0 | up(1), down(2), multipoint(3) | value map | AQUAMINT-MIB |
| sysTemperature | 1.3.6.1.4.1.3942.1.1.3.7.0 | десятые доли °C | ×0.1, °C | AQUASYSTEM-MIB |
| sysCpu | 1.3.6.1.4.1.3942.1.1.3.6.0 | % | % | AQUASYSTEM-MIB |
| sysSoftwareVersion | 1.3.6.1.4.1.3942.1.1.3.14.0 | текст | текст | AQUASYSTEM-MIB |
| sysModel | 1.3.6.1.4.1.3942.1.1.3.15.0 | текст (PN из лицензии) | текст | AQUASYSTEM-MIB |

### LLD «MINT: радиоинтерфейсы», mintNodesTable

База `1.3.6.1.4.1.3942.1.1.5.1.1.1.1`, индекс `nodeInterfaceId` (равен ifIndex радиоинтерфейса).

| Объект | Столбец | Единицы по MIB | В Zabbix |
|---|---|---|---|
| nodeName (для обнаружения, `{#NODENAME}`) | .8 | текст | макрос LLD |
| linksCount | .4 | число соседей | шт. |
| nodesCount | .5 | число узлов сети | шт. |
| noiseFloor | .26 | dBm | dBm |

### LLD «MINT: радиолинки с соседями», mintLinksTable

База `1.3.6.1.4.1.3942.1.1.5.1.1.2.1`, индекс `mintInterfaceId.neighborAddress` (ifIndex и 6 октетов MAC соседа).

| Объект | Столбец | Единицы по MIB | В Zabbix |
|---|---|---|---|
| linkName (для обнаружения, `{#LINKNAME}`) | .3 | текст | макрос LLD |
| monitorAmpIn | .5 | «Input reference signal level (SNR) in dB» | dB |
| monitorAmpOut | .6 | «Output reference signal level (SNR) in dB» | dB |
| curBitrateRX | .9 | Kb/s | ×1000, bps |
| curBitrateTX | .10 | Kb/s | ×1000, bps |
| retriesPercentTX | .19 | % | % |
| curTXpower | .28 | десятые доли dBm | ×0.1, dBm |
| rxRSSI | .30 | dBm | dBm |

### LLD «Сетевые интерфейсы», IF-MIB ifTable (RFC 2863)

База `1.3.6.1.2.1.2.2.1`, индекс ifIndex. Обнаружение по ifDescr (.2), фильтр ifAdminStatus (.7) = 1.

| Объект | Столбец | В Zabbix |
|---|---|---|
| ifOperStatus | .8 | value map |
| ifInOctets | .10 | изменение/с ×8, bps |
| ifOutOctets | .16 | изменение/с ×8, bps |
| ifInErrors | .14 | изменение/с |
| ifOutErrors | .20 | изменение/с |

## Триггеры и макросы

| Триггер | Условие | Важность |
|---|---|---|
| Радиолинк MINT не установлен | mintLinkStatus = down(2) два опроса подряд | High |
| Соседей MINT меньше ожидаемого | linksCount < `{$INFINET.LINKS.MIN}` три опроса подряд | Average |
| Низкий SNR на приёме / на передаче | максимум за 5 мин < `{$INFINET.SNR.MIN}` | Warning |
| Низкий уровень сигнала | максимум rxRSSI за 5 мин < `{$INFINET.RSSI.MIN}` | Warning |
| Много повторов передачи | минимум за 10 мин > `{$INFINET.RETRIES.MAX}` | Warning |
| Высокая температура платы | минимум за 15 мин > `{$INFINET.TEMP.MAX}` | Warning |
| Интерфейс: линк упал | ifOperStatus перешёл в down(2) | Average |
| Интерфейс: ошибки на приёме / передаче | минимум за 15 мин > `{$INFINET.IF.ERRORS.MAX}` | Warning |

Все пороги заданы по умолчанию и **требуют согласования**:

| Макрос | По умолчанию | Смысл |
|---|---|---|
| `{$INFINET.SNR.MIN}` | 15 | минимальный SNR, dB |
| `{$INFINET.RSSI.MIN}` | -80 | минимальный RSSI, dBm |
| `{$INFINET.RETRIES.MAX}` | 20 | повторы передачи, % |
| `{$INFINET.LINKS.MIN}` | 1 | ожидаемое число соседей (PtP: 1; базовая станция: число абонентов, задать на узле) |
| `{$INFINET.TEMP.MAX}` | 70 | температура платы, °C |
| `{$INFINET.IF.ERRORS.MAX}` | 2 | ошибок/с на интерфейсе |

Особенности:
- При пропадании соседа его строка исчезает из mintLinksTable, элементы линка становятся «не поддерживается». Падение линка ловят триггеры по mintLinkStatus и linksCount, а не по элементам линка.
- На базовой станции mintLinkStatus = multipoint(3), триггер «down» там не сработает; рабочим остаётся триггер по linksCount.

## Не подтверждено / не проверено

- Работа любого из OID ветки 3942 на реальном R5000 (нет доступа к устройству).
- Наличие на вашей прошивке `mintLinkStatus` (добавлен в MIB ревизией 2016-04-04) и `rxRSSI` (последний столбец таблицы). На старых версиях MINT их может не быть: элементы будут «не поддерживается», остальное работает.
- Наличие датчика температуры на конкретной аппаратной платформе (`sysTemperature`).
- Поддержка ifXTable (64-битные счётчики ifHCInOctets, ifName, ifAlias) на WANFleX: поэтому взяты 32-битные счётчики ifTable. При опросе раз в минуту счётчик не переполняется до примерно 570 Мбит/с.
- Команды включения SNMP в CLI WANFleX: вики производителя недоступна, синтаксис не приводим.
- Версия SNMP (v1/v2c/v3), поддерживаемая вашей прошивкой.
- Объекты, которые есть в MIB, но в шаблон не включены: скаляры PtP-линка `mintPtpLink` (1.3.6.1.4.1.3942.1.1.5.1.1.4.x, дублируют таблицу линков), нагрузка и счётчики по линку, дистанция, errorsPercent, AQUARADIO-MIB (частота, полоса, статистика пакетов).
- Импорт шаблона в Zabbix 7.0 (проверяется в CI; локально проверен только разбор YAML и соответствие ключей в триггерах).

## Как включить SNMP на устройстве

По данным вики Infinet SNMP-агент на R5000 по умолчанию **выключен**.
1. В веб-интерфейсе устройства найти раздел настроек SNMP, включить агент, задать community только для чтения (v2c) или пользователя (v3). Точное название раздела и команды CLI сверить с руководством к вашей версии ПО.
2. Ограничить доступ к SNMP адресом сервера Zabbix, если прошивка это позволяет.
3. В Zabbix: на узле добавить интерфейс SNMP (порт 161), указать community в настройках интерфейса (напрямую или через макрос узла `{$SNMP_COMMUNITY}`; в шаблоне этот макрос не задаётся) и привязать шаблон.

## Проверка snmpwalk

С машины с net-snmp в одной сети с устройством (в контейнере zabbix-server утилит net-snmp может не быть):

```sh
# модель, версия, ветка OID
snmpget  -v2c -c <community> <IP> 1.3.6.1.2.1.1.1.0 1.3.6.1.2.1.1.2.0
# вся ветка WANFleX: сохранить и приложить к проекту
snmpwalk -v2c -On -c <community> <IP> 1.3.6.1.4.1.3942.1.1 > infinet-walk.txt
# точечно
snmpget  -v2c -On -c <community> <IP> 1.3.6.1.4.1.3942.1.1.5.1.1.5.0   # mintLinkStatus: 1 up, 2 down, 3 multipoint
snmpget  -v2c -On -c <community> <IP> 1.3.6.1.4.1.3942.1.1.3.7.0       # sysTemperature, десятые доли °C
snmpwalk -v2c -On -c <community> <IP> 1.3.6.1.4.1.3942.1.1.5.1.1.1     # mintNodesTable
snmpwalk -v2c -On -c <community> <IP> 1.3.6.1.4.1.3942.1.1.5.1.1.2     # mintLinksTable
snmpwalk -v2c -On -c <community> <IP> 1.3.6.1.2.1.2.2                  # ifTable
```

С MIB-файлами (если положены в каталог): добавить `-M +zabbix/mibs -m +AQUAMINT-MIB:AQUASYSTEM-MIB`, имена вместо чисел.

Что сверить:
- значения SNR, RSSI, битрейта совпадают с веб-интерфейсом устройства (и множители верны: битрейт в Kb/s, температура и мощность в десятых долях);
- какие столбцы mintLinksTable реально отдаются (есть ли `.30` rxRSSI);
- отдаётся ли `mintLinkStatus`.

После проверки в Zabbix: «Последние данные» узла, правила обнаружения должны создать элементы по радиоинтерфейсу, соседям и сетевым интерфейсам.
