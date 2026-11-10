"""Мок Zabbix API для тестов и ручной проверки: python3 -m tests.mock_zabbix [порт]"""
import json
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

NOW = int(time.time())
HOSTS = [
    {"hostid": "1", "host": "msk-1", "name": "Москва-центр", "status": "0", "maintenance_status": "0",
     "active_available": "0", "hostgroups": [{"groupid": "1", "name": "Регион/Москва"}, {"groupid": "2", "name": "Роль/ЭСМД"}],
     "interfaces": [{"type": "2", "main": "1", "ip": "10.0.0.1", "dns": "", "available": "1"}],
     "inventory": {"type": "ЭСМД", "location": "Тверская 1", "location_lat": "55.7570", "location_lon": "37.6150"}},
    {"hostid": "2", "host": "khimki", "name": "Химки <img src=x onerror=alert(1)>", "status": "0", "maintenance_status": "0",
     "active_available": "0", "hostgroups": [{"groupid": "3", "name": "Регион/МО"}],
     "interfaces": [{"type": "1", "main": "1", "ip": "10.0.1.1", "dns": "", "available": "1"}],
     "inventory": {"location_lat": "55,8970", "location_lon": "37.4297"}},
    {"hostid": "3", "host": "kolomna", "name": "Коломна", "status": "0", "maintenance_status": "0",
     "active_available": "0", "hostgroups": [{"groupid": "3", "name": "Регион/МО"}],
     "interfaces": [{"type": "2", "main": "1", "ip": "10.0.2.1", "dns": "", "available": "2"}],
     "inventory": {"location_lat": "55.0794", "location_lon": "38.7783"}},
    {"hostid": "4", "host": "nocoords", "name": "Без координат", "status": "0", "maintenance_status": "0",
     "active_available": "0", "hostgroups": [{"groupid": "3", "name": "Регион/МО"}],
     "interfaces": [{"type": "2", "main": "1", "ip": "10.0.3.1", "dns": "", "available": "1"}],
     "inventory": []},
    {"hostid": "5", "host": "serpukhov", "name": "Серпухов", "status": "0", "maintenance_status": "0",
     "active_available": "0", "hostgroups": [{"groupid": "3", "name": "Регион/МО"}],
     "interfaces": [{"type": "2", "main": "1", "ip": "10.0.4.1", "dns": "", "available": "1"}],
     "inventory": {"location_lat": "54.9157", "location_lon": "37.4110"}},
    {"hostid": "6", "host": "bad", "name": "Кривые координаты", "status": "0", "maintenance_status": "0",
     "active_available": "0", "hostgroups": [], "interfaces": [],
     "inventory": {"location_lat": "abc", "location_lon": "37"}},
]
PROBLEMS = [
    {"eventid": "10", "objectid": "100", "name": "Нет связи по ICMP", "severity": "4", "clock": str(NOW - 3600), "acknowledged": "0", "suppressed": "0"},
    {"eventid": "11", "objectid": "101", "name": "Высокая температура", "severity": "2", "clock": str(NOW - 90000), "acknowledged": "1", "suppressed": "0"},
    {"eventid": "12", "objectid": "102", "name": "Диск 90%", "severity": "3", "clock": str(NOW - 600), "acknowledged": "0", "suppressed": "0"},
    {"eventid": "13", "objectid": "103", "name": "Чрезвычайная", "severity": "5", "clock": str(NOW - 60), "acknowledged": "0", "suppressed": "0"},
]
TRIGGERS = {"100": ["1"], "101": ["1"], "102": ["2"], "103": ["5"]}


class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def do_POST(self):
        req = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        m, p = req["method"], req.get("params")
        auth = self.headers.get("Authorization", "")
        if m == "apiinfo.version":
            res = "7.0.32"
        elif m == "user.login":
            if p.get("password") != "secret":
                return self._send({"jsonrpc": "2.0", "error": {"code": -32602, "message": "Invalid params.", "data": "Incorrect user name or password"}, "id": req["id"]})
            res = "tok123"
        elif auth != "Bearer tok123":
            return self._send({"jsonrpc": "2.0", "error": {"code": -32602, "message": "Session terminated, re-login, please.", "data": ""}, "id": req["id"]})
        elif m == "host.get":
            res = HOSTS
        elif m == "problem.get":
            res = PROBLEMS
        elif m == "trigger.get":
            res = [{"triggerid": t, "hosts": [{"hostid": h} for h in TRIGGERS[t]]} for t in p["triggerids"] if t in TRIGGERS]
        else:
            res = []
        self._send({"jsonrpc": "2.0", "result": res, "id": req["id"]})

    def _send(self, obj):
        b = json.dumps(obj).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(b)))
        self.end_headers()
        self.wfile.write(b)


def serve(port=0):
    srv = ThreadingHTTPServer(("127.0.0.1", port), H)
    srv.daemon_threads = True
    return srv


if __name__ == "__main__":
    s = serve(int(sys.argv[1]) if len(sys.argv) > 1 else 18080)
    print("mock on", s.server_address, flush=True)
    s.serve_forever()
