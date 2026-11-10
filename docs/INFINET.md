# Infinet R5000: шаблон
Сделана основа (`templates/infinet_r5000_snmp.yaml`): ICMP, sysUpTime (1.3.6.1.2.1.1.3.0), sysDescr (1.3.6.1.2.1.1.1.0), доступность SNMP — стандартные MIB-II.
Нужно добавить: уровень сигнала, SNR, скорость, состояние линка. OID брать из MIB Infinet (положить в `zabbix/mibs/`, проверить `snmptranslate`/`snmpwalk` на устройстве) и из документации; без MIB не добавлять.
