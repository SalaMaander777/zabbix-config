"""Минимальный клиент Zabbix API (stdlib). Работает внутри контейнера zabbix-server.

Переменные окружения: ZBX_API_URL, ZBX_API_USER, ZBX_API_PASSWORD,
ZBX_API_TIMEOUT (с, на один запрос, по умолчанию 60), ZBX_API_WAIT (с, сколько ждать
готовности API при входе, по умолчанию 300)."""
import json, os, sys, time, urllib.error, urllib.request

URL = os.environ.get("ZBX_API_URL", "http://zabbix-web:8080/api_jsonrpc.php")
TIMEOUT = float(os.environ.get("ZBX_API_TIMEOUT", "60"))
WAIT = float(os.environ.get("ZBX_API_WAIT", "300"))


class ApiError(RuntimeError):
    """Ошибка API Zabbix (ответ с полем error)."""


class TransportError(RuntimeError):
    """Нет связи с веб-интерфейсом или ответ не JSON (веб ещё не готов)."""


def _post(body, headers):
    req = urllib.request.Request(URL, body, headers)
    try:
        with urllib.request.urlopen(req, timeout=TIMEOUT) as r:
            raw = r.read()
    except urllib.error.HTTPError as e:
        raise TransportError(f"HTTP {e.code} от {URL}") from None
    except (urllib.error.URLError, OSError) as e:
        raise TransportError(f"нет связи с {URL}: {getattr(e, 'reason', e)}") from None
    try:
        return json.loads(raw.decode("utf-8"))
    except ValueError:
        raise TransportError(f"ответ {URL} не JSON: {raw[:120]!r}") from None


class Api:
    def __init__(self, wait=None):
        """Вход в API. Пока веб-интерфейс/БД не готовы (первый запуск, перезапуск),
        повторяет попытки до `wait` секунд (по умолчанию ZBX_API_WAIT).
        Неверный логин/пароль - сразу ошибка."""
        self.token = None
        self._id = 0
        deadline = time.monotonic() + (WAIT if wait is None else wait)
        while True:
            try:
                self.token = self.call("user.login", {
                    "username": os.environ.get("ZBX_API_USER", "Admin"),
                    "password": os.environ.get("ZBX_API_PASSWORD", "zabbix")})
                return
            except (TransportError, ApiError) as e:
                bad_creds = isinstance(e, ApiError) and "ncorrect user name or password" in str(e)
                if bad_creds or time.monotonic() >= deadline:
                    raise
                print(f"ожидание готовности API Zabbix: {e}", file=sys.stderr, flush=True)
                time.sleep(5)

    def call(self, method, params):
        h = {"Content-Type": "application/json-rpc"}
        if self.token:
            h["Authorization"] = "Bearer " + self.token
        self._id += 1
        body = json.dumps({"jsonrpc": "2.0", "method": method, "params": params, "id": self._id}).encode()
        d = _post(body, h)
        if "error" in d:
            e = d["error"] or {}
            raise ApiError(f"{method}: {e.get('message', '')} {e.get('data', '')}".strip())
        return d["result"]
