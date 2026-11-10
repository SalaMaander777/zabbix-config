# Infinet Wireless R5000 (SkyMan): шаблон

## Что найдено в открытом доступе (поиск 2026-11-10)
- Enterprise-номер Infinet: `1.3.6.1.4.1.3942` (по [Observium: INFINET-XG-MIB](https://mibs.observium.org/mib/INFINET-XG-MIB)).
- Единственные найденные радио-MIB Infinet (INFINET-XG-MIB, [INFINET-XGRADIO-MIB](https://mibs.observium.org/mib/INFINET-XGRADIO-MIB)) относятся к поколению **InfiLINK XG**, а не к R5000/InfiLINK 2x2 (MINT). OID сигнала/CINR/состояния линка из них **для R5000 не использовать**: соответствие не подтверждено, а на странице Observium нет описаний и единиц измерения.
- MIB для R5000 в открытых каталогах не найден. Вики производителя (wiki.infinetwireless.com) из этой среды недоступна («Not available in your Country»). Из поисковой выдачи: SNMP-агент на R5000 по умолчанию выключен, включить до подключения к мониторингу (требует проверки).
- Руководство R5000 (MINT 1.90.11, 2014) в найденном виде сведений об SNMP/MIB не содержит.

## Что сделано
`templates/infinet_r5000_snmp.yaml`: ICMP, sysUpTime, sysDescr (стандартные MIB-II), доступность SNMP. Метрики радиоканала не добавлены: OID не подтверждены.

## Как получить настоящие OID (нужен доступ к устройству)
1. Включить SNMP-агент на R5000 (веб-интерфейс или CLI MINT), задать community (v2c) или пользователя (v3). Уточнить поддерживаемую версию SNMP.
2. С Mac (`brew install net-snmp`) или любой машины с net-snmp, в одной сети с устройством:
   - `snmpget -v2c -c <community> <IP> 1.3.6.1.2.1.1.1.0 1.3.6.1.2.1.1.2.0` (sysDescr, sysObjectID: модель/версия ПО и ветка OID);
   - `snmpwalk -v2c -On -c <community> <IP> 1.3.6.1.4.1.3942 > infinet-walk.txt`.
   Прислать вывод: по нему видно, какие объекты есть именно на вашей прошивке.
3. MIB-файлы: из комплекта ПО/прошивки устройства, с портала поддержки Infinet или у поставщика. Положить в `zabbix/mibs/`.
4. По MIB и walk выбрать OID: уровень сигнала (RSSI), SNR/CINR, скорость/MCS, состояние линка, температура. Единицы и множители брать из DESCRIPTION в MIB.
