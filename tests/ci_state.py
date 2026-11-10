"""CI: проверки состояния после перезапуска/восстановления.
  ci_state.py mark ИМЯ         создать пустой хост-метку
  ci_state.py present ИМЯ...   хосты есть
  ci_state.py absent ИМЯ...    хостов нет
  ci_state.py config           шаблоны, правила LLD и хранение (результат post_setup) на месте"""
import sys
sys.path.insert(0, "/opt/zbx-tools")
from zbxapi import Api
a = Api()
cmd, args = sys.argv[1], sys.argv[2:]


def have(name):
    return bool(a.call("host.get", {"filter": {"host": [name]}, "output": ["hostid"]}))


if cmd == "mark":
    gid = a.call("hostgroup.get", {"filter": {"name": ["Linux servers"]}})[0]["groupid"]
    a.call("host.create", {"host": args[0], "groups": [{"groupid": gid}]})
    print("создан хост", args[0])
elif cmd == "present":
    bad = [n for n in args if not have(n)]
    assert not bad, f"хосты должны быть, но их нет: {bad}"
    print("есть:", args)
elif cmd == "absent":
    bad = [n for n in args if have(n)]
    assert not bad, f"хосты должны были исчезнуть: {bad}"
    print("нет (как и должно быть):", args)
elif cmd == "config":
    want = {"Infinet R5000 SNMP": 3, "ESMD ICMP and TCP": 0, "EB500 ICMP and SCPI": 0}   # минимум правил LLD
    for name, min_lld in want.items():
        t = a.call("template.get", {"filter": {"host": [name]}, "output": ["templateid"]})
        assert len(t) == 1, f"шаблон {name!r}: найдено {len(t)}"
        n = len(a.call("discoveryrule.get", {"templateids": t[0]["templateid"], "output": ["itemid"]}))
        assert n >= min_lld, f"{name}: правил LLD {n}, ожидалось не меньше {min_lld} (импорт без discoveryRules?)"
        print(f"шаблон {name!r}: ок, правил LLD {n}")
    hk = a.call("housekeeping.get", {})
    assert hk["hk_history"] == "90d" and hk["hk_trends"] == "365d", hk
    assert hk["hk_history_global"] == "1" and hk["hk_trends_global"] == "1", hk
    print("housekeeping: история 90d, тренды 365d")
    names = {g["name"] for g in a.call("hostgroup.get", {"output": ["name"]})}
    miss = {"Регион/Москва", "Регион/Московская область", "Роль/Cisco", "Роль/Infinet", "Роль/Windows ПК",
            "Роль/ESMD", "Роль/EB500"} - names
    assert not miss, f"нет групп: {miss}"
    print("группы: ок")
else:
    sys.exit("неизвестная команда")
