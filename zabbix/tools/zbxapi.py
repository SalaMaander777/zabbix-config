"""Минимальный клиент Zabbix API (stdlib). Работает внутри контейнера zabbix-server."""
import json, os, urllib.request

URL = os.environ.get("ZBX_API_URL", "http://zabbix-web:8080/api_jsonrpc.php")


class Api:
    def __init__(self):
        self.token = None
        self.token = self.call("user.login", {
            "username": os.environ.get("ZBX_API_USER", "Admin"),
            "password": os.environ.get("ZBX_API_PASSWORD", "zabbix")})

    def call(self, method, params):
        h = {"Content-Type": "application/json-rpc"}
        if self.token:
            h["Authorization"] = "Bearer " + self.token
        body = json.dumps({"jsonrpc": "2.0", "method": method, "params": params, "id": 1}).encode()
        with urllib.request.urlopen(urllib.request.Request(URL, body, h), timeout=60) as r:
            d = json.load(r)
        if "error" in d:
            raise RuntimeError(f"{method}: {d['error']}")
        return d["result"]
