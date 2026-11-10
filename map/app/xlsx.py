"""Выгрузка снимка в Excel (openpyxl)."""
import io
import re
from datetime import datetime, timezone

from openpyxl import Workbook
from openpyxl.styles import Alignment, Font, PatternFill
from openpyxl.utils import get_column_letter

from .zbx import OK_COLOR, SEVERITY_COLORS, SEVERITY_NAMES

_ILLEGAL = re.compile(r"[\x00-\x08\x0b\x0c\x0e-\x1f]")
_DT_FORMAT = "DD.MM.YYYY HH:MM:SS"


def _local(ts, tz):
    """Unix-время -> «наивное» местное время (Excel не хранит часовой пояс)."""
    if ts is None:
        return None
    return datetime.fromtimestamp(ts, timezone.utc).astimezone(tz).replace(tzinfo=None)


def format_duration(seconds):
    seconds = max(int(seconds), 0)
    d, rem = divmod(seconds, 86400)
    h, rem = divmod(rem, 3600)
    m = rem // 60
    if d:
        return "%d д %02d ч %02d мин" % (d, h, m)
    if h:
        return "%d ч %02d мин" % (h, m)
    return "%d мин" % m


def _put(ws, row, col, value, fmt=None):
    cell = ws.cell(row=row, column=col)
    if isinstance(value, str):
        # Явный строковый тип: имя вида «=1+1» не должно стать формулой в Excel.
        cell.value = _ILLEGAL.sub(" ", value)[:32000]
        cell.data_type = "s"
    elif value is not None:
        cell.value = value
        if fmt:
            cell.number_format = fmt
    return cell


def _sheet(wb, title, headers, widths):
    ws = wb.create_sheet(title)
    for col, (name, width) in enumerate(zip(headers, widths), 1):
        c = ws.cell(row=1, column=col, value=name)
        c.font = Font(bold=True)
        c.fill = PatternFill("solid", fgColor="DDE3EA")
        c.alignment = Alignment(vertical="center", wrap_text=True)
        ws.column_dimensions[get_column_letter(col)].width = width
    ws.freeze_panes = "A2"
    return ws


def _finish(ws, ncols):
    ws.auto_filter.ref = "A1:%s%d" % (get_column_letter(ncols), max(ws.max_row, 1))


def build_workbook(snapshot, tz, stale_note=""):
    wb = Workbook()
    wb.remove(wb.active)
    now = snapshot["generated_at"]

    headers = ["Имя", "Узел (техническое имя)", "Группы", "Регион", "Роль", "IP", "DNS", "Тип",
               "Адрес", "Широта", "Долгота", "Состояние", "Доступность", "Проблем",
               "Макс. важность", "Последняя проблема"]
    ws = _sheet(wb, "Устройства", headers,
                [32, 26, 44, 22, 18, 16, 22, 18, 30, 11, 11, 30, 18, 10, 20, 20])
    for r, h in enumerate(snapshot["hosts"], 2):
        sev = h["max_severity"]
        values = [h["name"], h["host"], "; ".join(h["groups"]), h["region"], h["role"], h["ip"],
                  h["dns"], h["type"], h["location"], h["lat"], h["lon"], h["state"],
                  h["availability_text"], h["problem_count"],
                  SEVERITY_NAMES[sev] if sev >= 0 else "",
                  _local(h["last_problem_clock"], tz)]
        for c, v in enumerate(values, 1):
            _put(ws, r, c, v, _DT_FORMAT if c == 16 else None)
        if h["enabled"]:
            color = SEVERITY_COLORS[sev] if sev >= 0 else OK_COLOR
            ws.cell(row=r, column=12).fill = PatternFill("solid", fgColor=color)
    _finish(ws, len(headers))

    headers = ["Хост", "Проблема", "Важность", "Код важности", "С какого времени", "Длительность",
               "Длительность, ч", "Подтверждена", "Подавлена", "Группы", "IP"]
    ws = _sheet(wb, "Проблемы", headers, [32, 60, 20, 10, 20, 20, 12, 14, 12, 44, 16])
    rows = [(h, p) for h in snapshot["hosts"] for p in h["problems"]]
    rows.sort(key=lambda hp: (-hp[1]["severity"], hp[1]["clock"]))
    for r, (h, p) in enumerate(rows, 2):
        dur = max(now - p["clock"], 0)
        values = [h["name"], p["name"], SEVERITY_NAMES[p["severity"]], p["severity"],
                  _local(p["clock"], tz), format_duration(dur), round(dur / 3600.0, 2),
                  "да" if p["acknowledged"] else "нет", "да" if p["suppressed"] else "нет",
                  "; ".join(h["groups"]), h["ip"]]
        for c, v in enumerate(values, 1):
            _put(ws, r, c, v, _DT_FORMAT if c == 5 else None)
        ws.cell(row=r, column=3).fill = PatternFill("solid", fgColor=SEVERITY_COLORS[p["severity"]])
    _finish(ws, len(headers))

    ws = wb.create_sheet("Сведения")
    s = snapshot["summary"]
    info = [("Сформировано", _local(now, tz)), ("Часовой пояс", str(tz)),
            ("Версия Zabbix", snapshot["zabbix_version"]),
            ("Устройств всего", s["total"]), ("С координатами", s["with_coords"]),
            ("Без координат", s["without_coords"]), ("Устройств с проблемами", s["with_problems"]),
            ("Проблем всего", s["problems"])]
    if stale_note:
        info.append(("Внимание", stale_note))
    for r, (k, v) in enumerate(info, 1):
        _put(ws, r, 1, k).font = Font(bold=True)
        _put(ws, r, 2, v, _DT_FORMAT)
        ws.cell(row=r, column=2).alignment = Alignment(horizontal="left")
    ws.column_dimensions["A"].width = 28
    ws.column_dimensions["B"].width = 60

    buf = io.BytesIO()
    wb.save(buf)
    return buf.getvalue()
