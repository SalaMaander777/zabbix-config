"""Фиктивный SCPI-прибор для CI (TCP, LF). Отвечает как EB500 по примерам из руководства."""
import socketserver, sys
ANS = {"*IDN?": 'ROHDE&SCHWARZ,EB500,100.017/002, V01.10-4072.8710.00',
       "*OPT?": "0", "SYSTEM:ERROR:COUNT?": "0", "SYSTEM:ERROR?": '0, "No Error"',
       "SYST:ERR:COUN?": "0", "SYST:ERR?": '0, "No Error"'}

class H(socketserver.StreamRequestHandler):
    def handle(self):
        for line in self.rfile:
            cmd = line.decode().strip()
            if cmd:
                self.wfile.write((ANS.get(cmd.upper(), ANS.get(cmd, "")) + "\n").encode())

socketserver.ThreadingTCPServer.allow_reuse_address = True
socketserver.ThreadingTCPServer(("0.0.0.0", int(sys.argv[1]) if len(sys.argv) > 1 else 5555), H).serve_forever()
