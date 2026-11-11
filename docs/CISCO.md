# Cisco: как определить модель и версию

Два маршрутизатора: Cisco 1921/K9 (ArbatRouter) и Cisco 2901/K9 (по словам заказчика; ранее предполагалась 2811).

## По железу
Модель на шильдике на корпусе (задняя/нижняя сторона, строка `Model`/`PID`, например `CISCO2811`).

## По командной строке (консоль, SSH или Telnet)
```
show version      ! модель, версия IOS, имя образа, uptime
show inventory    ! PID/серийный номер шасси и модулей
show running-config | include snmp    ! настроен ли SNMP, community / v3-группы
show snmp user    ! пользователи SNMPv3, если есть
```
В выводе `show version` строка вида `Cisco 2811 (revision ...)` — модель; `Cisco IOS Software, 2800 Software (C2800NM-...), Version 12.4(...)` или `15.x` — версия IOS. По имени образа видно, есть ли шифрование: `k9` в имени (например `...k9...`) указывает на crypto-образ, который нужен для SNMPv3 с шифрованием (priv) (требует проверки по описанию образа).

## По SNMP (если SNMP уже включён)
`snmpget -v2c -c <community> <IP> 1.3.6.1.2.1.1.1.0` (sysDescr) — в ответе обычно модель и версия IOS; `1.3.6.1.2.1.47.1.1.1.1.13` (ENTITY-MIB, entPhysicalModelName, `snmpwalk`) — модель шасси и модулей. Это стандартные OID.

## Включить SNMP (если не включён), пример для v2c только на чтение
```
configure terminal
 snmp-server community <СЛОЖНАЯ_СТРОКА> RO <ACL>
 end
write memory
```
Для v3 нужны группа и пользователь (`snmp-server group`, `snmp-server user`); синтаксис и поддержка зависят от версии IOS (сверить с `show version`). `ACL` — список доступа с адресом сервера Zabbix; community задать свою, не `public`.

## Шаблон в Zabbix
Для Cisco используются встроенные шаблоны Zabbix 7.0 (например `Cisco IOS by SNMP`); их наличие и набор метрик для 2811 проверить после импорта на реальном устройстве.

## Известные устройства (по `show version` от заказчика)
| Имя | Модель | Лицензия | Примечание |
|---|---|---|---|
| ArbatRouter | Cisco 1921/K9 (rev 1.0), платформа c1900 | `ipbasek9` (Permanent), security/data: None | версия IOS в снимок не попала, нужна верхняя часть вывода `show version` |
| (второй) | Cisco 2901/K9 (со слов заказчика) | не известна | `show version` не получен, версию IOS и SNMP-настройки выяснить |

Суффикс `k9` и пакет `ipbasek9` означают образ с криптографией, значит SNMPv3 с шифрованием на 1921, скорее всего, доступен (требует проверки на устройстве).

## SNMPv3 (authPriv, только чтение) - команды для 1921 и 2901
Подставить `<ZBX_IP>` (IP главного компьютера с Zabbix), `<AUTHPASS>` и `<PRIVPASS>` (разные, не короче 8 символов). Синтаксис стандартный для IOS 12.4/15.x, на конкретных версиях проверить.
```
configure terminal
 ip access-list standard ZBX-SNMP
  permit host <ZBX_IP>
  deny any log
 exit
 snmp-server view ZBX-VIEW iso included
 snmp-server group ZBX-GRP v3 priv read ZBX-VIEW access ZBX-SNMP
 snmp-server user zbxmon ZBX-GRP v3 auth sha <AUTHPASS> priv aes 128 <PRIVPASS> access ZBX-SNMP
 snmp-server ifindex persist
 end
write memory
```
Проверка на роутере: `show snmp user`, `show snmp group`. Строка `snmp-server user` в running-config не отображается (так и должно быть).
Проверка с сервера/Mac:
`snmpget -v3 -l authPriv -u zbxmon -a SHA -A '<AUTHPASS>' -x AES -X '<PRIVPASS>' <IP> 1.3.6.1.2.1.1.1.0`
Zabbix, интерфейс SNMP хоста: версия SNMPv3, Security name `zbxmon`, Security level `authPriv`, Authentication protocol `SHA1`, Authentication passphrase, Privacy protocol `AES128`, Privacy passphrase, Context name пусто. Рекомендуется хранить пароли в макросах `{$SNMPV3_AUTH}`/`{$SNMPV3_PRIV}` (тип «секрет»).

## Проверено в CI
Названия встроенных шаблонов Zabbix 7.0.32 подтверждены в CI по базе сервера: `Cisco IOS by SNMP`, `Windows by Zabbix agent` (есть также `... active`). Настройки SNMPv3 из раздела выше (пользователь `zbxmon`, authPriv, SHA1 + AES128, пароли в секретных макросах `{$SNMPV3_AUTH}`/`{$SNMPV3_PRIV}`) проверяются в CI на имитаторе: те же команды `snmpget -v3 ...`, затем хост Zabbix с такими параметрами интерфейса получает значения. Сам роутер Cisco в CI не участвует.

## Коммутаторы Cisco (Catalyst, IOS)
Команды SNMPv3 те же, что для маршрутизаторов (ACL `ZBX-SNMP`, view, group, user, `snmp-server ifindex persist`). Отличия:
- У коммутатора адрес управления — на VLAN-интерфейсе (SVI). Проверить: `show ip interface brief` (строка `VlanN` с IP, статус up/up). Если адреса нет:
  ```
  interface Vlan<N>
   ip address <IP> <маска>
   no shutdown
  exit
  ip default-gateway <шлюз>
  ```
- Шифрование SNMPv3 (priv AES) есть только в образе с криптографией (`k9` в имени образа в `show version`). Если команда `snmp-server group ... v3 priv` не принимается — образ без криптографии: используйте `v3 auth` (группа и пользователь без `priv ...`), в Zabbix уровень `authNoPriv`.
- Шаблон в Zabbix: `Cisco IOS by SNMP` (встроенный). На 24/48-портовом коммутаторе обнаружение интерфейсов создаст много элементов — это нормально.
