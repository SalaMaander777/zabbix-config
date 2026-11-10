"""Чтение данных из Zabbix API (только методы *.get) и сборка снимка для карты.

Используется стандартная библиотека. Проверялось на формате ответов Zabbix 7.0.
"""
import json
import re
import time
import urllib.error
import urllib.request

SEVERITY_NAMES = [
    "Не классифицировано", "Информация", "Предупреждение",
    "Средняя", "Высокая", "Чрезвычайная",
]
# Цвета важности по умолчанию из Zabbix (Администрирование -> Общие -> Опции отображения триггеров).
SEVERITY_COLORS = ["97AAB3", "7499FF", "FFC859", "FFA059", "E97659", "E45959"]
OK_COLOR = "59DB8F"

AVAILABILITY_NAMES = {
    "available": "Доступен", "unavailable": "Недоступен",
    "partial": "Частично доступен", "unknown": "Неизвестно",
}
INTERFACE_TYPES = {"1": "Агент", "2": "SNMP", "3": "IPMI", "4": "JMX"}

_RELOGIN_RE = re.compile(r"re-login|not authori[sz]ed|session terminated", re.I)


class ZabbixError(Exception):
    """Ошибка обращения к Zabbix. message - текст для пользователя (по-русски)."""

    def __init__(self, message, detail=""):
        super().__init__(message)
        self.message = message
        self.detail = detail


class ZabbixClient:
    def __init__(self, url, user="", password="", token="", timeout=10.0):
        self.url = url
        self.user = user
        self.password = password
        self.token = token          # постоянный API-токен (если задан, логин не выполняется)
        self.timeout = timeout
        self._session = None        # токен сессии после user.login
        self._id = 0

    def _post(self, method, params, auth):
        headers = {"Content-Type": "application/json-rpc"}
        if auth:
            headers["Authorization"] = "Bearer " + auth
        self._id += 1
        body = json.dumps({"jsonrpc": "2.0", "method": method, "params": params,
                           "id": self._id}).encode("utf-8")
        req = urllib.request.Request(self.url, body, headers)
        try:
            with urllib.request.urlopen(req, timeout=self.timeout) as resp:
                raw = resp.read()
        except urllib.error.HTTPError as e:
            raise ZabbixError("Zabbix вернул ошибку HTTP %d" % e.code, str(e)) from None
        except (urllib.error.URLError, OSError) as e:
            reason = getattr(e, "reason", e)
            raise ZabbixError("Zabbix недоступен (нет связи с веб-интерфейсом Zabbix)",
                              "%s: %s" % (self.url, reason)) from None
        try:
            data = json.loads(raw.decode("utf-8"))
        except (ValueError, UnicodeDecodeError):
            raise ZabbixError("Zabbix вернул неожиданный ответ (не JSON)",
                              raw[:200].decode("utf-8", "replace")) from None
        if not isinstance(data, dict):
            raise ZabbixError("Zabbix вернул неожиданный ответ", "")
        if "error" in data:
            err = data["error"] or {}
            raise _ApiError("%s %s" % (err.get("message", ""), err.get("data", "")))
        return data.get("result")

    def _login(self):
        if not self.user:
            raise ZabbixError("Не заданы учётные данные Zabbix API",
                              "задайте ZBX_API_TOKEN либо ZBX_API_USER и ZBX_API_PASSWORD")
        try:
            self._session = self._post(
                "user.login", {"username": self.user, "password": self.password}, None)
        except _ApiError as e:
            raise ZabbixError("Zabbix отклонил учётные данные API (проверьте пользователя и пароль)",
                              str(e)) from None

    def version(self):
        try:
            return self._post("apiinfo.version", {}, None)
        except _ApiError as e:
            raise ZabbixError("Ошибка Zabbix API", str(e)) from None

    def call(self, method, params):
        if not method.endswith(".get"):
            # Сервис только читает. Защита от случайного добавления изменяющих вызовов.
            raise ValueError("разрешены только методы *.get: " + method)
        if self.token:
            try:
                return self._post(method, params, self.token)
            except _ApiError as e:
                if _RELOGIN_RE.search(str(e)):
                    raise ZabbixError("Zabbix отклонил API-токен (проверьте ZBX_API_TOKEN)",
                                      str(e)) from None
                raise ZabbixError("Ошибка Zabbix API (%s)" % method, str(e)) from None
        for attempt in (1, 2):
            if not self._session:
                self._login()
            try:
                return self._post(method, params, self._session)
            except _ApiError as e:
                if attempt == 1 and _RELOGIN_RE.search(str(e)):
                    self._session = None    # сессия истекла - войти заново один раз
                    continue
                raise ZabbixError("Ошибка Zabbix API (%s)" % method, str(e)) from None


class _ApiError(Exception):
    pass


def parse_coord(value, limit):
    """Строка инвентаря -> float либо None. Допускается запятая как разделитель."""
    if value is None:
        return None
    s = str(value).strip().replace(",", ".")
    if not s:
        return None
    try:
        v = float(s)
    except ValueError:
        return None
    if v != v or abs(v) > limit:
        return None
    return v


def _int(v, default=0):
    try:
        return int(v)
    except (TypeError, ValueError):
        return default


def _availability(host):
    states = {str(i.get("available", "0")) for i in host.get("interfaces") or []
              if str(i.get("main", "1")) == "1"}
    if "2" in states:
        return "partial" if "1" in states else "unavailable"
    if "1" in states:
        return "available"
    active = str(host.get("active_available", "0"))
    if active == "1":
        return "available"
    if active == "2":
        return "unavailable"
    return "unknown"


def _main_interface(host):
    ifaces = [i for i in host.get("interfaces") or [] if str(i.get("main", "1")) == "1"]
    ifaces = ifaces or list(host.get("interfaces") or [])
    ifaces.sort(key=lambda i: _int(i.get("type"), 9))
    return ifaces[0] if ifaces else {}


def _by_prefix(groups, prefix):
    if not prefix:
        return ""
    return ", ".join(g[len(prefix):] for g in groups if g.startswith(prefix))


def collect(client, region_prefix="Регион/", role_prefix="Роль/"):
    """Запросить Zabbix и вернуть снимок: хосты, их проблемы, сводка."""
    version = client.version()
    hosts_raw = client.call("host.get", {
        "output": ["hostid", "host", "name", "status", "maintenance_status", "active_available"],
        "selectHostGroups": ["groupid", "name"],
        "selectInterfaces": ["type", "main", "useip", "ip", "dns", "available", "error"],
        "selectInventory": ["type", "location", "location_lat", "location_lon"],
    }) or []
    problems_raw = client.call("problem.get", {
        "output": ["eventid", "objectid", "name", "severity", "clock", "acknowledged",
                   "suppressed"],
        "source": 0, "object": 0,
        "sortfield": ["eventid"], "sortorder": "DESC",
    }) or []
    trigger_hosts = {}
    trigger_ids = sorted({str(p["objectid"]) for p in problems_raw})
    if trigger_ids:
        # Привязка проблемы к хосту идёт через триггер. monitored - без отключённых хостов/элементов.
        for t in client.call("trigger.get", {
                "output": ["triggerid"], "triggerids": trigger_ids,
                "selectHosts": ["hostid"], "monitored": True}) or []:
            trigger_hosts[str(t["triggerid"])] = [str(h["hostid"]) for h in t.get("hosts") or []]

    by_host = {}
    for p in problems_raw:
        item = {
            "eventid": str(p.get("eventid", "")),
            "name": str(p.get("name", "")),
            "severity": min(max(_int(p.get("severity")), 0), 5),
            "clock": _int(p.get("clock")),
            "acknowledged": str(p.get("acknowledged", "0")) == "1",
            "suppressed": str(p.get("suppressed", "0")) == "1",
        }
        for hid in trigger_hosts.get(str(p.get("objectid")), []):
            by_host.setdefault(hid, []).append(item)

    hosts = []
    all_groups = set()
    for h in hosts_raw:
        hid = str(h["hostid"])
        groups = sorted(g.get("name", "") for g in h.get("hostgroups") or h.get("groups") or [])
        all_groups.update(groups)
        inv = h.get("inventory")
        inv = inv if isinstance(inv, dict) else {}   # при выключенном инвентаре API отдаёт []
        lat_raw = str(inv.get("location_lat") or "").strip()
        lon_raw = str(inv.get("location_lon") or "").strip()
        lat, lon = parse_coord(lat_raw, 90), parse_coord(lon_raw, 180)
        coords_note = ""
        if lat is None or lon is None:
            if lat_raw or lon_raw:
                coords_note = "Некорректные координаты в инвентаре: «%s», «%s»" % (lat_raw, lon_raw)
            lat = lon = None
        iface = _main_interface(h)
        enabled = str(h.get("status", "0")) == "0"
        problems = sorted(by_host.get(hid, []), key=lambda p: (-p["severity"], -p["clock"])) \
            if enabled else []
        active = [p for p in problems if not p["suppressed"]]
        max_sev = max((p["severity"] for p in active), default=-1)
        availability = _availability(h)
        maintenance = str(h.get("maintenance_status", "0")) == "1"
        if not enabled:
            state = "Отключён"
        elif active:
            state = "Проблема: " + SEVERITY_NAMES[max_sev]
        elif availability == "unavailable":
            state = "Недоступен"
        else:
            state = "В норме"
        if maintenance and enabled:
            state += " (обслуживание)"
        role = _by_prefix(groups, role_prefix)
        hosts.append({
            "hostid": hid,
            "host": str(h.get("host", "")),
            "name": str(h.get("name") or h.get("host", "")),
            "enabled": enabled,
            "maintenance": maintenance,
            "groups": groups,
            "region": _by_prefix(groups, region_prefix),
            "role": role,
            "ip": str(iface.get("ip", "")),
            "dns": str(iface.get("dns", "")),
            "interface": INTERFACE_TYPES.get(str(iface.get("type", "")), ""),
            "type": str(inv.get("type") or "") or role,
            "location": str(inv.get("location") or ""),
            "lat": lat,
            "lon": lon,
            "coords_note": coords_note,
            "availability": availability,
            "availability_text": AVAILABILITY_NAMES[availability],
            "state": state,
            "max_severity": max_sev,
            "problem_count": len(active),
            "last_problem_clock": max((p["clock"] for p in active), default=None),
            "problems": problems,
        })
    hosts.sort(key=lambda x: x["name"].lower())

    by_sev = [0] * 6
    for x in hosts:
        for p in x["problems"]:
            if not p["suppressed"]:
                by_sev[p["severity"]] += 1
    return {
        "generated_at": int(time.time()),
        "zabbix_version": str(version),
        "severity_names": SEVERITY_NAMES,
        "severity_colors": SEVERITY_COLORS,
        "ok_color": OK_COLOR,
        "groups": sorted(all_groups),
        "summary": {
            "total": len(hosts),
            "with_coords": sum(1 for x in hosts if x["lat"] is not None),
            "without_coords": sum(1 for x in hosts if x["lat"] is None),
            "with_problems": sum(1 for x in hosts if x["problem_count"]),
            "problems": sum(by_sev),
            "by_severity": by_sev,
        },
        "hosts": hosts,
    }
