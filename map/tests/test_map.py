import io
import json
import os
import tempfile
import threading
import unittest
import urllib.error
import urllib.request

from openpyxl import load_workbook

from app import server
from tests import mock_zabbix


def get(url, headers=None):
    try:
        with urllib.request.urlopen(urllib.request.Request(url, headers=headers or {}), timeout=10) as r:
            return r.status, dict(r.headers), r.read()
    except urllib.error.HTTPError as e:
        return e.code, dict(e.headers), e.read()


class MapTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.zbx = mock_zabbix.serve(0)
        threading.Thread(target=cls.zbx.serve_forever, daemon=True).start()
        cls.tmp = tempfile.TemporaryDirectory()
        cls.tiles = os.path.join(cls.tmp.name, "t.pmtiles")
        with open(cls.tiles, "wb") as f:
            f.write(bytes(range(256)) * 4)
        server.TILES = cls.tiles
        cls.start("secret")

    @classmethod
    def start(cls, password):
        from app.zbx import ZabbixClient
        client = ZabbixClient("http://127.0.0.1:%d/" % cls.zbx.server_address[1], "Admin", password, timeout=5)
        cls.srv = server.Server(("127.0.0.1", 0), server.make_handler(server.Cache(client), ""))
        threading.Thread(target=cls.srv.serve_forever, daemon=True).start()
        cls.base = "http://127.0.0.1:%d" % cls.srv.server_address[1]

    @classmethod
    def tearDownClass(cls):
        cls.srv.shutdown(); cls.zbx.shutdown(); cls.tmp.cleanup()

    def test_healthz_and_static(self):
        self.assertEqual(get(self.base + "/healthz")[0], 200)
        st, h, body = get(self.base + "/")
        self.assertEqual(st, 200); self.assertIn(b"leaflet", body)
        self.assertEqual(get(self.base + "/static/vendor/leaflet.js")[0], 200)
        self.assertEqual(get(self.base + "/static/../app/server.py")[0], 404)
        self.assertEqual(get(self.base + "/static/%2e%2e/app/server.py")[0], 404)

    def test_hosts(self):
        st, h, body = get(self.base + "/api/hosts")
        self.assertEqual(st, 200)
        d = json.loads(body)
        by = {x["host"]: x for x in d["hosts"]}
        self.assertEqual(by["msk-1"]["max_severity"], 4)
        self.assertEqual(by["msk-1"]["problem_count"], 2)
        self.assertAlmostEqual(by["khimki"]["lat"], 55.897)       # запятая как разделитель
        self.assertIsNone(by["nocoords"]["lat"])
        self.assertIsNone(by["bad"]["lat"]); self.assertTrue(by["bad"]["coords_note"])
        self.assertEqual(by["kolomna"]["state"], "Недоступен")
        self.assertEqual(by["serpukhov"]["max_severity"], 5); self.assertEqual(by["nocoords"]["max_severity"], -1)
        self.assertEqual(d["summary"]["with_coords"], 4)
        self.assertNotIn("secret", body.decode())
        self.assertNotIn("tok123", body.decode())

    def test_export(self):
        st, h, body = get(self.base + "/export.xlsx")
        self.assertEqual(st, 200); self.assertEqual(body[:2], b"PK")
        self.assertIn("attachment", h["Content-Disposition"])
        wb = load_workbook(io.BytesIO(body))
        self.assertIn("Устройства", wb.sheetnames); self.assertIn("Проблемы", wb.sheetnames)
        rows = list(wb["Устройства"].iter_rows(values_only=True))
        self.assertEqual(len(rows), 7)
        self.assertEqual(rows[0][0], "Имя")
        self.assertEqual(len(list(wb["Проблемы"].iter_rows(values_only=True))), 5)

    def test_tiles_range(self):
        st, h, body = get(self.base + "/tiles.pmtiles", {"Range": "bytes=10-19"})
        self.assertEqual(st, 206); self.assertEqual(body, bytes(range(10, 20)))
        self.assertEqual(h["Content-Range"], "bytes 10-19/1024")
        st, h, body = get(self.base + "/tiles.pmtiles", {"Range": "bytes=-4"})
        self.assertEqual(body, bytes([252, 253, 254, 255]))
        st, h, body = get(self.base + "/tiles.pmtiles")
        self.assertEqual((st, len(body)), (200, 1024))
        self.assertEqual(get(self.base + "/tiles.pmtiles", {"Range": "bytes=5000-"})[0], 416)

    def test_wrong_password(self):
        from app.zbx import ZabbixClient
        c = ZabbixClient("http://127.0.0.1:%d/" % self.zbx.server_address[1], "Admin", "bad", timeout=5)
        srv = server.Server(("127.0.0.1", 0), server.make_handler(server.Cache(c), ""))
        threading.Thread(target=srv.serve_forever, daemon=True).start()
        st, h, body = get("http://127.0.0.1:%d/api/hosts" % srv.server_address[1])
        srv.shutdown()
        self.assertEqual(st, 502); self.assertIn("error", json.loads(body))


if __name__ == "__main__":
    unittest.main()
