#!/usr/bin/env python3
"""Проверка R&S ESMD для Zabbix external check (только стандартная библиотека).

Протокол ESMD НЕ подтверждён (требует проверки по руководству/на приборе).
Поэтому скрипт ничего не выдумывает:
  tcp-режим  - только проверка TCP-соединения, печатает время в секундах или -1.
  raw-режим  - отправляет ПЕРЕДАННУЮ вызывающим команду (без значения по умолчанию),
               печатает первую строку ответа. Команды брать из руководства.

Использование:
  esmd_check.py tcp HOST PORT [TIMEOUT]
  esmd_check.py raw HOST PORT 'КОМАНДА' [TIMEOUT]
Ключ Zabbix (External check, имя файла = ключ): esmd_check.py[raw,{HOST.CONN},{$ESMD.PORT},"*IDN?"]
"""
import socket, sys, time


def main(argv):
    if len(argv) < 4 or argv[1] not in ("tcp", "raw"):
        print(__doc__, file=sys.stderr)
        return 2
    mode, host, port = argv[1], argv[2], int(argv[3])
    rest = argv[4:]
    cmd = rest.pop(0) if mode == "raw" and rest else None
    if mode == "raw" and cmd is None:
        print("raw: команда не указана", file=sys.stderr)
        return 2
    timeout = float(rest[0]) if rest else 5.0
    t0 = time.monotonic()
    try:
        with socket.create_connection((host, port), timeout=timeout) as s:
            if mode == "tcp":
                print(round(time.monotonic() - t0, 4))
                return 0
            s.settimeout(timeout)
            s.sendall(cmd.encode() + b"\n")
            data = s.recv(4096).decode(errors="replace").strip()
            print(data.splitlines()[0] if data else "")
            return 0
    except OSError as e:
        print(-1 if mode == "tcp" else "", end="\n")
        print(f"ошибка: {e}", file=sys.stderr)
        return 0 if mode == "tcp" else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
