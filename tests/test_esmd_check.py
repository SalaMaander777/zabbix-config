"""Тесты zabbix/externalscripts/esmd_check.py на локальном фиктивном SCPI-сервере.

Запуск из корня репозитория:  python3 -B -m unittest discover -s tests -v
"""
import contextlib
import importlib.util
import io
import json
import os
import socket
import subprocess
import sys
import threading
import time
import unittest

sys.dont_write_bytecode = True

SCRIPT = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                      "..", "zabbix", "externalscripts", "esmd_check.py")
_spec = importlib.util.spec_from_file_location("esmd_check", SCRIPT)
esmd_check = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(esmd_check)

IDN = "ROHDE&SCHWARZ,EB500,100.017/002, V01.00-4072.8710.00"
NO_ERROR = '0, "No Error"'


class FakeScpi:
    """Фиктивный прибор: TCP-сервер в потоке, команды и ответы завершаются LF.

    replies: команда -> ответ. Ответ: str (отправить строку + terminator),
    None (молчать, как прибор на неизвестную команду), bytes (отправить как есть),
    callable(conn) (особое поведение). Неизвестная команда - молчание.
    """

    def __init__(self, replies, terminator=b"\n", banner=None):
        self.replies = dict(replies)
        self.terminator = terminator
        self.banner = banner
        self.received = []          # все принятые команды
        self.connections = 0        # сколько соединений было принято
        self.closed_by_client = threading.Event()
        self._stop = threading.Event()
        self._srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self._srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self._srv.bind(("127.0.0.1", 0))
        self._srv.listen(5)
        self._srv.settimeout(0.1)
        self.port = self._srv.getsockname()[1]
        self._threads = []
        self._thread = threading.Thread(target=self._accept, daemon=True)
        self._thread.start()

    def _accept(self):
        while not self._stop.is_set():
            try:
                conn, _ = self._srv.accept()
            except socket.timeout:
                continue
            except OSError:
                return
            self.connections += 1
            t = threading.Thread(target=self._serve, args=(conn,), daemon=True)
            t.start()
            self._threads.append(t)

    def _serve(self, conn):
        buf = b""
        try:
            conn.settimeout(0.1)
            if self.banner:
                conn.sendall(self.banner)
            while not self._stop.is_set():
                try:
                    chunk = conn.recv(4096)
                except socket.timeout:
                    continue
                if not chunk:
                    self.closed_by_client.set()
                    return
                buf += chunk
                while b"\n" in buf:
                    line, _, buf = buf.partition(b"\n")
                    cmd = line.decode().strip()
                    self.received.append(cmd)
                    reply = self.replies.get(cmd)
                    if reply is None:
                        continue
                    if callable(reply):
                        if reply(conn) == "close":
                            return
                    elif isinstance(reply, bytes):
                        conn.sendall(reply)
                    else:
                        conn.sendall(reply.encode() + self.terminator)
        except OSError:
            pass
        finally:
            conn.close()

    def stop(self):
        self._stop.set()
        self._srv.close()
        self._thread.join(2)
        for t in self._threads:
            t.join(2)


def free_port():
    """Порт, на котором заведомо никто не слушает."""
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()
    return port


def run_main(*args):
    """Вызвать main() как из командной строки; вернуть (код, stdout, stderr)."""
    out, err = io.StringIO(), io.StringIO()
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
        rc = esmd_check.main(["esmd_check.py"] + [str(a) for a in args])
    return rc, out.getvalue(), err.getvalue()


class Base(unittest.TestCase):
    replies = {}
    terminator = b"\n"
    banner = None

    def setUp(self):
        self.srv = FakeScpi(self.replies, self.terminator, self.banner)
        self.addCleanup(self.srv.stop)

    def json(self, *args):
        rc, out, _ = run_main("json", "127.0.0.1", self.srv.port, *args)
        self.assertEqual(rc, 0)
        self.assertEqual(out.count("\n"), 1, "ровно одна строка вывода")
        return json.loads(out)


class JsonMode(Base):
    replies = {"*IDN?": IDN, "SYSTem:ERRor:COUNt?": "0", "SYSTem:ERRor?": NO_ERROR,
               "DIAGnostic:MODule:STATe? ALL": "V1,1,S1,1,Z1,1,P1,1,H1,1,M1,1,DC,1,GP,3"}

    def test_several_queries_one_connection(self):
        cmds = ["*IDN?", "SYSTem:ERRor:COUNt?", "SYSTem:ERRor?", "DIAGnostic:MODule:STATe? ALL"]
        d = self.json(*cmds)
        self.assertEqual(d["tcp"], 1)
        self.assertEqual(d["results"], {c: self.replies[c] for c in cmds})
        self.assertEqual(d["errors"], {})
        self.assertEqual(d["error"], "")
        self.assertEqual((d["requested"], d["answered"]), (4, 4))
        self.assertGreaterEqual(d["time"], d["connect"])
        self.assertGreaterEqual(d["connect"], 0)
        self.assertLess(abs(d["clock"] - time.time()), 5)
        self.assertEqual(self.srv.connections, 1)
        self.assertEqual(self.srv.received, cmds, "команды ушли по одной, в заданном порядке")

    def test_connection_is_closed_afterwards(self):
        self.json("*IDN?")
        self.assertTrue(self.srv.closed_by_client.wait(2), "скрипт закрыл соединение")

    def test_all_fields_always_present(self):
        d = self.json("*IDN?")
        self.assertEqual(set(d), {"tcp", "time", "connect", "clock", "connections", "requested",
                                  "answered", "error", "results", "errors"})

    def test_silent_command_times_out_and_next_still_answered(self):
        d = self.json("--timeout=0.3", "*IDN?", "BOGus:QUERy?", "SYSTem:ERRor?")
        self.assertEqual(d["tcp"], 1)
        self.assertEqual(d["results"], {"*IDN?": IDN, "SYSTem:ERRor?": NO_ERROR})
        self.assertEqual(d["errors"], {"BOGus:QUERy?": "timeout"})
        self.assertEqual((d["requested"], d["answered"]), (3, 2))

    def test_device_answers_nothing_at_all(self):
        d = self.json("--timeout=0.2", "BOGus:ONE?", "BOGus:TWO?")
        self.assertEqual(d["tcp"], 1)
        self.assertEqual(d["answered"], 0)
        self.assertEqual(d["results"], {})
        self.assertEqual(d["errors"], {"BOGus:ONE?": "timeout", "BOGus:TWO?": "timeout"})

    def test_deadline_limits_total_time(self):
        t0 = time.monotonic()
        d = self.json("--timeout=0.4", "--deadline=0.6", "BOGus:ONE?", "BOGus:TWO?", "BOGus:THRee?")
        self.assertLess(time.monotonic() - t0, 1.5)
        self.assertEqual(d["errors"]["BOGus:ONE?"], "timeout")
        self.assertEqual(d["errors"]["BOGus:TWO?"], "timeout")
        self.assertEqual(d["errors"]["BOGus:THRee?"], "skipped: deadline")
        self.assertNotIn("BOGus:THRee?", self.srv.received)

    def test_duplicates_and_blank_commands_are_collapsed(self):
        d = self.json("*IDN?", " ", "*IDN?")
        self.assertEqual(d["requested"], 1)
        self.assertEqual(self.srv.received, ["*IDN?"])

    def test_non_queries_are_never_sent(self):
        bad = ["*RST", "*CLS", "FREQuency 100 MHz", "*IDN?;*RST", "SYSTem:ERRor?\n*RST",
               "*TST?", "*tst?", "?", "OUTPut:SQUelch ON"]
        d = self.json("*IDN?", *bad)
        self.assertEqual(d["results"], {"*IDN?": IDN})
        self.assertEqual(self.srv.received, ["*IDN?"], "на прибор ушёл только запрос")
        for c in bad:
            self.assertTrue(d["errors"][c.strip()].startswith("rejected"), c)

    def test_query_filter(self):
        ok = ["*IDN?", "*OPT?", "*idn?", "SYSTem:ERRor?", "SYST:ERR:COUN?", "DIAGnostic:TEMPerature8?",
              "DIAGnostic:MODule:STATe? ALL", "STATus:QUEStionable:CONDition?", "ROSCillator:SOURce?"]
        for c in ok:
            self.assertIsNone(esmd_check.query_rejection(c), c)
        for c in ["*RST", "*TST?", "SYSTem:DATE 2008,4,17", "A?;B", "ABC", "", "? ALL", "*IDN? é"]:
            self.assertIsNotNone(esmd_check.query_rejection(c), c)

    def test_usage_errors(self):
        for args in (["json", "127.0.0.1", self.srv.port],
                     ["json", "127.0.0.1", self.srv.port, "--timeout=5"],
                     ["json", "127.0.0.1", self.srv.port, "--timeout=x", "*IDN?"],
                     ["json", "127.0.0.1", self.srv.port, "--deadline=0", "*IDN?"],
                     ["json", "127.0.0.1", self.srv.port, "--bogus=1", "*IDN?"],
                     ["json", "127.0.0.1", "port", "*IDN?"],
                     ["json", "127.0.0.1"], ["nope", "127.0.0.1", "1"], []):
            rc, out, err = run_main(*args)
            self.assertEqual(rc, 2, args)
            self.assertEqual(out, "")
            self.assertTrue(err)
        self.assertEqual(self.srv.received, [])


class JsonNoConnection(unittest.TestCase):
    def check(self, host, port, *extra):
        rc, out, _ = run_main("json", host, port, *extra, "*IDN?", "SYSTem:ERRor?")
        self.assertEqual(rc, 0)
        d = json.loads(out)
        self.assertEqual(d["tcp"], 0)
        self.assertEqual(d["connect"], -1)
        self.assertEqual(d["answered"], 0)
        self.assertEqual(d["requested"], 2)
        self.assertEqual(d["results"], {})
        self.assertEqual(d["errors"], {"*IDN?": "no connection", "SYSTem:ERRor?": "no connection"})
        self.assertTrue(d["error"].startswith("connect: "))
        return d

    def test_connection_refused(self):
        self.check("127.0.0.1", free_port())

    def test_unresolvable_host(self):
        self.check("no-such-host.invalid", 5555, "--timeout=2")

    def test_port_out_of_range(self):
        self.check("127.0.0.1", 99999)

    def test_output_is_ascii(self):
        rc, out, _ = run_main("json", "127.0.0.1", free_port(), "*IDN?")
        out.encode("ascii")


class JsonOddDevices(Base):
    def test_crlf_terminator(self):
        self.srv.terminator = b"\r\n"
        self.srv.replies = {"*IDN?": IDN, "SYSTem:ERRor?": NO_ERROR}
        d = self.json("*IDN?", "SYSTem:ERRor?")
        self.assertEqual(d["results"], {"*IDN?": IDN, "SYSTem:ERRor?": NO_ERROR})

    def test_empty_response(self):
        self.srv.replies = {"*OPT?": "", "*IDN?": IDN}
        d = self.json("*OPT?", "*IDN?")
        self.assertEqual(d["errors"], {"*OPT?": "empty response"})
        self.assertEqual(d["results"], {"*IDN?": IDN})
        self.assertEqual(d["answered"], 1)

    def test_response_split_into_chunks(self):
        def slow(conn):
            for part in (b"ROHDE&SCH", b"WARZ,ESMD,", b"1/2,V1\n"):
                conn.sendall(part)
                time.sleep(0.05)
        self.srv.replies = {"*IDN?": slow}
        self.assertEqual(self.json("*IDN?")["results"], {"*IDN?": "ROHDE&SCHWARZ,ESMD,1/2,V1"})

    def test_device_closes_connection_mid_poll(self):
        self.srv.replies = {"*IDN?": IDN, "*OPT?": lambda conn: "close", "SYSTem:ERRor?": NO_ERROR}
        d = self.json("*IDN?", "*OPT?", "SYSTem:ERRor?", "SYSTem:ERRor:COUNt?")
        self.assertEqual(d["tcp"], 1)
        self.assertEqual(d["results"], {"*IDN?": IDN})
        self.assertEqual(d["errors"], {"*OPT?": "connection closed", "SYSTem:ERRor?": "connection closed",
                                       "SYSTem:ERRor:COUNt?": "connection closed"})
        self.assertNotIn("SYSTem:ERRor:COUNt?", self.srv.received)

    def test_partial_line_then_close_is_kept(self):
        def partial(conn):
            conn.sendall(b"ROHDE&SCHWARZ,ESMD")
            return "close"
        self.srv.replies = {"*IDN?": partial}
        self.assertEqual(self.json("*IDN?")["results"], {"*IDN?": "ROHDE&SCHWARZ,ESMD"})

    def test_multiline_response_tail_is_not_taken_for_next_answer(self):
        self.srv.replies = {"DIAGnostic:INFO:MODule? ALL": b"V1,1\nS1,1\nP1,1\n", "*IDN?": IDN}
        d = self.json("DIAGnostic:INFO:MODule? ALL", "*IDN?")
        self.assertEqual(d["results"]["DIAGnostic:INFO:MODule? ALL"], "V1,1")
        self.assertEqual(d["results"]["*IDN?"], IDN)

    def test_late_answer_is_not_taken_for_next_answer(self):
        def late(conn):
            time.sleep(0.4)
            conn.sendall(b"LATE\n")
        self.srv.replies = {"*OPT?": late, "*IDN?": IDN}
        d = self.json("--timeout=0.2", "*OPT?", "*IDN?")
        self.assertEqual(d["errors"], {"*OPT?": "timeout"})
        self.assertEqual(d["results"], {"*IDN?": IDN})

    def test_overlong_response(self):
        self.srv.replies = {"*IDN?": b"x" * (esmd_check.MAX_LINE + 10000), "*OPT?": "PS"}
        d = self.json("--timeout=1", "*IDN?", "*OPT?")
        self.assertEqual(d["errors"]["*IDN?"], "response too long")
        self.assertNotIn("*IDN?", d["results"])

    def test_non_utf8_bytes_do_not_break_json(self):
        self.srv.replies = {"*IDN?": b"R&S,\xff\xfeESMD\n"}
        d = self.json("*IDN?")
        self.assertIn("ESMD", d["results"]["*IDN?"])

    def test_quotes_survive_json(self):
        self.srv.replies = {"SYSTem:ERRor?": '-113,"Undefined header;SYSTEM:EROR?"'}
        d = self.json("SYSTem:ERRor?")
        self.assertEqual(d["results"]["SYSTem:ERRor?"], '-113,"Undefined header;SYSTEM:EROR?"')


class LegacyModes(Base):
    """Ключи существующих шаблонов: режимы tcp и raw ведут себя как раньше."""
    replies = {"*IDN?": IDN, "SYSTem:ERRor?": NO_ERROR}

    def test_tcp_ok(self):
        rc, out, _ = run_main("tcp", "127.0.0.1", self.srv.port)
        self.assertEqual(rc, 0)
        self.assertGreaterEqual(float(out), 0)

    def test_tcp_with_timeout_argument(self):
        rc, out, _ = run_main("tcp", "127.0.0.1", self.srv.port, 2)
        self.assertEqual(rc, 0)
        self.assertGreaterEqual(float(out), 0)

    def test_tcp_refused(self):
        rc, out, err = run_main("tcp", "127.0.0.1", free_port())
        self.assertEqual((rc, out), (0, "-1\n"))
        self.assertTrue(err)

    def test_raw_ok(self):
        rc, out, _ = run_main("raw", "127.0.0.1", self.srv.port, "*IDN?")
        self.assertEqual((rc, out), (0, IDN + "\n"))
        self.assertEqual(self.srv.received, ["*IDN?"])
        self.assertTrue(self.srv.closed_by_client.wait(2))

    def test_raw_with_timeout_argument(self):
        rc, out, _ = run_main("raw", "127.0.0.1", self.srv.port, "SYSTem:ERRor?", "2")
        self.assertEqual((rc, out), (0, NO_ERROR + "\n"))

    def test_raw_no_answer(self):
        rc, out, err = run_main("raw", "127.0.0.1", self.srv.port, "BOGus?", "0.2")
        self.assertEqual((rc, out), (1, "\n"))
        self.assertTrue(err)

    def test_raw_refused(self):
        rc, out, _ = run_main("raw", "127.0.0.1", free_port(), "*IDN?")
        self.assertEqual((rc, out), (1, "\n"))

    def test_raw_peer_closes_without_answer(self):
        self.srv.replies = {"*IDN?": lambda conn: "close"}
        rc, out, _ = run_main("raw", "127.0.0.1", self.srv.port, "*IDN?")
        self.assertEqual((rc, out), (0, "\n"))

    def test_raw_without_command(self):
        rc, out, _ = run_main("raw", "127.0.0.1", self.srv.port)
        self.assertEqual((rc, out), (2, ""))


class CommandLine(Base):
    """Запуск файла так, как это делает Zabbix (исполняемый файл с аргументами)."""
    replies = {"*IDN?": IDN, "SYSTem:ERRor?": NO_ERROR}

    def run_script(self, *args):
        self.assertTrue(os.access(SCRIPT, os.X_OK), "скрипт должен быть исполняемым")
        env = dict(os.environ, PYTHONDONTWRITEBYTECODE="1", LC_ALL="C")
        return subprocess.run([SCRIPT] + [str(a) for a in args], env=env, timeout=20,
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE)

    def test_json(self):
        p = self.run_script("json", "127.0.0.1", self.srv.port, "*IDN?", "SYSTem:ERRor?")
        self.assertEqual(p.returncode, 0)
        self.assertEqual(json.loads(p.stdout)["results"], self.replies)

    def test_json_refused(self):
        p = self.run_script("json", "127.0.0.1", free_port(), "*IDN?")
        self.assertEqual(p.returncode, 0)
        self.assertEqual(json.loads(p.stdout)["tcp"], 0)

    def test_raw(self):
        p = self.run_script("raw", "127.0.0.1", self.srv.port, "*IDN?")
        self.assertEqual((p.returncode, p.stdout.decode()), (0, IDN + "\n"))

    def test_usage_in_c_locale(self):
        p = self.run_script()
        self.assertEqual(p.returncode, 2)
        self.assertEqual(p.stdout, b"")


if __name__ == "__main__":
    unittest.main()
