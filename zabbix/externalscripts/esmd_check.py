#!/usr/bin/env python3
"""Опрос приёмников R&S ESMD / EB500 по SCPI (сырой TCP-сокет, терминатор LF)
для Zabbix external check. Только стандартная библиотека Python 3.

Режимы:
  tcp   - только проверка TCP-соединения; печатает время соединения в секундах
          или -1. Код возврата 0.
  raw   - отправляет ОДНУ переданную команду, печатает первую строку ответа.
          При ошибке соединения печатает пустую строку, код возврата 1.
  json  - одно TCP-соединение, несколько команд-ЗАПРОСОВ подряд, на выходе один
          JSON-объект (мастер-элемент Zabbix, зависимые элементы берут поля
          через JSONPath). Код возврата 0 и валидный JSON даже при ошибке
          соединения ({"tcp":0,...}).

Использование:
  esmd_check.py tcp  HOST PORT [TIMEOUT]
  esmd_check.py raw  HOST PORT 'КОМАНДА' [TIMEOUT]
  esmd_check.py json HOST PORT [--timeout=СЕК] [--deadline=СЕК] 'ЗАПРОС?' ['ЗАПРОС?' ...]

    --timeout=СЕК   таймаут соединения и ожидания ответа на одну команду (по умолчанию 3)
    --deadline=СЕК  общий предел времени на весь опрос (по умолчанию 8; должен быть
                    меньше таймаута элемента данных Zabbix)

Вывод режима json (поля есть всегда):
  {"tcp": 1,            1 - соединение установлено, 0 - нет
   "time": 0.012,       полное время опроса, с
   "connect": 0.001,    время установки соединения, с (-1 при ошибке)
   "clock": 1700000000, время сервера Zabbix (Unix) в момент опроса
   "connections": 1,    сколько соединений открыто (1; больше - были таймауты, см. ниже)
   "requested": 2,      сколько команд запрошено
   "answered": 2,       на сколько получен непустой ответ
   "error": "",         ошибка соединения (пусто, если её нет)
   "results": {"*IDN?": "...", ...},   ответы (первая строка, без CR/LF)
   "errors":  {"КОМАНДА": "timeout"}}  команды без ответа и причина

Если прибор не ответил на команду за --timeout, ответ считается потерянным
("timeout" в errors), а перед следующей командой соединение закрывается и
открывается заново: иначе запоздавший ответ был бы принят за ответ на следующую
команду. Соединения идут строго по очереди, одновременно открыто не больше одного.

Команды в скрипт не зашиты: их задаёт ключ элемента данных, брать их нужно из
руководства прибора (см. docs/ESMD.md). В режиме json принимаются только запросы
(заголовок оканчивается на "?"), без ";" и переводов строк; *TST? отклоняется:
мониторинг не должен менять настройки прибора и запускать самотест.

Ключи Zabbix (External check):
  esmd_check.py[tcp,{HOST.CONN},{$ESMD.PORT}]
  esmd_check.py[raw,{HOST.CONN},{$ESMD.PORT},"*IDN?"]
  esmd_check.py[json,{HOST.CONN},{$ESMD.PORT},"*IDN?","SYSTem:ERRor?"]
"""
import json
import re
import socket
import sys
import time

DEFAULT_TIMEOUT = 5.0        # tcp/raw (как было)
JSON_TIMEOUT = 3.0           # json: на соединение и на одну команду
JSON_DEADLINE = 8.0          # json: на весь опрос
MAX_LINE = 65536             # предел длины одной строки ответа, байт
MAX_RECONNECTS = 3           # json: сколько раз можно переоткрыть соединение после таймаутов

# Запрос SCPI: мнемоника (или общая команда *XXX), "?", затем необязательные параметры.
_QUERY_RE = re.compile(r"^\*?[A-Za-z][A-Za-z0-9:_]*\?(?: [ -~]*)?$")
_FORBIDDEN = {"*TST?"}       # запускает самотест модулей


class _Usage(Exception):
    pass


def query_rejection(cmd):
    """Причина, по которой команда не будет отправлена в режиме json, или None."""
    if any(c in cmd for c in ";\r\n"):
        return "rejected: compound command or line break"
    if not _QUERY_RE.match(cmd):
        return "rejected: not a query"
    if cmd.split(" ", 1)[0].upper() in _FORBIDDEN:
        return "rejected: forbidden command"
    return None


def _close(sock):
    try:
        sock.shutdown(socket.SHUT_RDWR)
    except OSError:
        pass
    try:
        sock.close()
    except OSError:
        pass


def _drain(sock):
    """Выбросить всё, что уже пришло (хвост многострочного или запоздавшего ответа)."""
    sock.setblocking(False)
    try:
        while True:
            try:
                if not sock.recv(4096):
                    return
            except (BlockingIOError, InterruptedError):
                return
            except OSError:
                return
    finally:
        sock.setblocking(True)


def _read_line(sock, buf, limit):
    """Прочитать одну строку до LF не дольше limit секунд.

    Возвращает (строка_или_None, остаток_буфера, ошибка_или_None).
    """
    end = time.monotonic() + limit
    while b"\n" not in buf:
        left = end - time.monotonic()
        if left <= 0:
            return None, buf, "timeout"
        if len(buf) > MAX_LINE:
            return None, b"", "response too long"
        sock.settimeout(left)
        try:
            chunk = sock.recv(4096)
        except socket.timeout:
            return None, buf, "timeout"
        except OSError as e:
            return None, buf, "receive failed: %s" % e
        if not chunk:
            # Соединение закрыто прибором. Неполная строка без LF - тоже ответ.
            if buf.strip():
                return buf, b"", None
            return None, b"", "connection closed"
        buf += chunk
    line, _, rest = buf.partition(b"\n")
    return line, rest, None


def _decode(line):
    return line.decode("utf-8", errors="replace").strip("\r\n\t \x00")


def poll(host, port, commands, timeout=JSON_TIMEOUT, deadline=JSON_DEADLINE):
    """Опросить прибор списком запросов в одном соединении. Возвращает dict."""
    t0 = time.monotonic()
    out = {"tcp": 0, "time": 0.0, "connect": -1, "clock": int(time.time()),
           "connections": 0, "requested": 0, "answered": 0, "error": "",
           "results": {}, "errors": {}}
    cmds = []
    for c in commands:
        c = c.strip()
        if c and c not in cmds:
            cmds.append(c)
    out["requested"] = len(cmds)
    results, errors = out["results"], out["errors"]

    def finish():
        out["answered"] = len(results)
        out["time"] = round(time.monotonic() - t0, 4)
        return out

    def connect():
        left = deadline - (time.monotonic() - t0)
        return socket.create_connection((host, port), timeout=max(0.05, min(timeout, left)))

    try:
        sock = connect()
    except (OSError, OverflowError, ValueError) as e:
        out["error"] = "connect: %s" % e
        for c in cmds:
            errors[c] = "no connection"
        return finish()

    out["tcp"] = 1
    out["connect"] = round(time.monotonic() - t0, 4)
    out["connections"] = 1
    resync = False               # после таймаута поток ответов мог разойтись с командами
    try:
        for c in cmds:
            reason = query_rejection(c)
            if reason:
                errors[c] = reason
                continue
            left = deadline - (time.monotonic() - t0)
            if left <= 0.05:
                errors[c] = "skipped: deadline"
                continue
            if sock is None:
                errors[c] = "connection closed"
                continue
            if resync:
                # Запоздавший ответ на предыдущую команду нельзя принять за ответ
                # на следующую: закрываем соединение и открываем новое.
                _close(sock)
                sock = None
                if out["connections"] > MAX_RECONNECTS:
                    errors[c] = "skipped: too many timeouts"
                    continue
                try:
                    sock = connect()
                except (OSError, OverflowError, ValueError) as e:
                    errors[c] = "reconnect failed: %s" % e
                    continue
                out["connections"] += 1
                resync = False
                left = deadline - (time.monotonic() - t0)
            _drain(sock)
            try:
                sock.settimeout(max(0.05, min(timeout, left)))
                sock.sendall(c.encode("ascii", errors="replace") + b"\n")
            except OSError as e:
                errors[c] = "send failed: %s" % e
                _close(sock)
                sock = None
                continue
            line, _rest, err = _read_line(sock, b"", max(0.05, min(timeout, left)))
            if err:
                errors[c] = err
                if err == "timeout":
                    resync = True
                else:
                    _close(sock)
                    sock = None
                continue
            text = _decode(line)
            if text:
                results[c] = text
            else:
                errors[c] = "empty response"
    finally:
        if sock is not None:
            _close(sock)
    return finish()


def _legacy(mode, host, port, rest):
    """Режимы tcp и raw: поведение и формат вывода прежние."""
    cmd = None
    if mode == "raw":
        if not rest:
            raise _Usage("raw: команда не указана")
        cmd = rest.pop(0)
    try:
        timeout = float(rest[0]) if rest else DEFAULT_TIMEOUT
    except ValueError:
        raise _Usage("таймаут должен быть числом")
    t0 = time.monotonic()
    try:
        sock = socket.create_connection((host, port), timeout=timeout)
    except (OSError, OverflowError, ValueError) as e:
        print(-1 if mode == "tcp" else "")
        print("ошибка: %s" % e, file=sys.stderr)
        return 0 if mode == "tcp" else 1
    try:
        if mode == "tcp":
            print(round(time.monotonic() - t0, 4))
            return 0
        try:
            sock.settimeout(timeout)
            sock.sendall(cmd.encode("ascii", errors="replace") + b"\n")
        except OSError as e:
            print("")
            print("ошибка: %s" % e, file=sys.stderr)
            return 1
        line, _rest, err = _read_line(sock, b"", timeout)
        if err and err != "connection closed":
            print("")
            print("ошибка: %s" % err, file=sys.stderr)
            return 1
        print(_decode(line) if line else "")
        return 0
    finally:
        _close(sock)


def _json_mode(host, port, rest):
    timeout, deadline, cmds = JSON_TIMEOUT, JSON_DEADLINE, []
    for a in rest:
        if a.startswith("--"):
            name, _, val = a.partition("=")
            try:
                num = float(val)
            except ValueError:
                raise _Usage("параметр %s: нужно число" % name)
            if num <= 0:
                raise _Usage("параметр %s: нужно число больше 0" % name)
            if name == "--timeout":
                timeout = num
            elif name == "--deadline":
                deadline = num
            else:
                raise _Usage("неизвестный параметр %s" % name)
        else:
            cmds.append(a)
    if not [c for c in cmds if c.strip()]:
        raise _Usage("json: не указано ни одной команды")
    print(json.dumps(poll(host, port, cmds, timeout, deadline), ensure_ascii=True))
    return 0


def main(argv):
    try:
        if len(argv) < 4 or argv[1] not in ("tcp", "raw", "json"):
            raise _Usage("")
        mode, host = argv[1], argv[2]
        try:
            port = int(argv[3])
        except ValueError:
            raise _Usage("порт должен быть числом")
        if mode == "json":
            return _json_mode(host, port, list(argv[4:]))
        return _legacy(mode, host, port, list(argv[4:]))
    except _Usage as e:
        if str(e):
            print("ошибка: %s" % e, file=sys.stderr)
        print(__doc__, file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
