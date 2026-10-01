#!/usr/bin/env python3
"""Mac ekranini eski TV tarayicilarina MJPEG olarak yansitir.

Kullanim: python3 tv_yansit.py [--port 8080] [--fps 15] [--genislik 1280] [--kalite 5]
TV tarayicisinda ekranda yazan adresi ac.
"""
import argparse
import atexit
import socket
import subprocess
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

SAYFA = b"""<!DOCTYPE html>
<html><head><meta charset="utf-8"><title>Mac Ekrani</title>
<style>
html,body{margin:0;padding:0;width:100%;height:100%;background:#000;overflow:hidden}
img{width:100%;height:100%;object-fit:contain;display:block}
</style></head>
<body><img id="ekran" src="/akis">
<script>
// Baglanti koparsa akisi yeniden baslat (ES5, eski tarayicilar icin)
var img = document.getElementById('ekran');
img.onerror = function () {
  setTimeout(function () { img.src = '/akis?t=' + new Date().getTime(); }, 1000);
};
</script>
</body></html>"""

SINIR = b"cerceve"


class Kare:
    """ffmpeg'den gelen son JPEG karesini tutar."""

    def __init__(self):
        self.veri = None
        self.sayac = 0
        self.kosul = threading.Condition()

    def koy(self, veri):
        with self.kosul:
            self.veri = veri
            self.sayac += 1
            self.kosul.notify_all()

    def bekle(self, son_sayac):
        with self.kosul:
            self.kosul.wait_for(lambda: self.sayac != son_sayac, timeout=5)
            return self.veri, self.sayac


kare = Kare()


def ekran_yakala(args):
    komut = [
        "ffmpeg", "-hide_banner", "-loglevel", "error", "-nostdin",
        "-f", "avfoundation", "-capture_cursor", "1", "-pixel_format", "nv12",
        "-framerate", "30", "-i", f"{args.ekran}:none",
        # fps filtresi + passthrough: ffmpeg'in kare kopyalayip akisi sisirmesini onler
        "-vf", f"fps={args.fps},scale={args.genislik}:-2",
        "-fps_mode", "passthrough",
        "-q:v", str(args.kalite),
        "-f", "image2pipe", "-vcodec", "mjpeg", "-",
    ]
    surec = subprocess.Popen(komut, stdout=subprocess.PIPE)
    atexit.register(surec.kill)
    tampon = b""
    while True:
        parca = surec.stdout.read(65536)
        if not parca:
            print("ffmpeg durdu. Terminal'e Ekran Kaydi izni verildi mi?", file=sys.stderr)
            break
        tampon += parca
        while True:
            bas = tampon.find(b"\xff\xd8")
            son = tampon.find(b"\xff\xd9", bas + 2)
            if bas == -1 or son == -1:
                break
            kare.koy(tampon[bas:son + 2])
            tampon = tampon[son + 2:]


class Isleyici(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path.startswith("/akis"):
            self.akis()
        else:
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(SAYFA)))
            self.end_headers()
            self.wfile.write(SAYFA)

    def akis(self):
        self.send_response(200)
        self.send_header("Content-Type", "multipart/x-mixed-replace; boundary=" + SINIR.decode())
        self.send_header("Cache-Control", "no-cache, no-store")
        self.send_header("Connection", "close")
        self.end_headers()
        son = -1
        try:
            while True:
                veri, son = kare.bekle(son)
                if veri is None:
                    continue
                self.wfile.write(b"--" + SINIR + b"\r\n")
                self.wfile.write(b"Content-Type: image/jpeg\r\n")
                self.wfile.write(b"Content-Length: " + str(len(veri)).encode() + b"\r\n\r\n")
                self.wfile.write(veri + b"\r\n")
        except (BrokenPipeError, ConnectionResetError):
            pass

    def log_message(self, *_):
        pass


def yerel_ip():
    # Varsayilan ag gecidine giden arayuzun adresi (fazladan eklenmis IP'leri atlar)
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.connect(("8.8.8.8", 80))
        return s.getsockname()[0]
    finally:
        s.close()


def main():
    p = argparse.ArgumentParser(description="Mac ekranini TV tarayicisina yansit")
    p.add_argument("--port", type=int, default=8080)
    p.add_argument("--fps", type=int, default=15)
    p.add_argument("--genislik", type=int, default=1280, help="Yayin genisligi (piksel)")
    p.add_argument("--kalite", type=int, default=5, help="JPEG kalitesi: 2 en iyi, 31 en kotu")
    p.add_argument("--ekran", default="Capture screen 0", help="ffmpeg avfoundation ekran adi veya numarasi")
    args = p.parse_args()

    threading.Thread(target=ekran_yakala, args=(args,), daemon=True).start()

    sunucu = ThreadingHTTPServer(("0.0.0.0", args.port), Isleyici)
    sunucu.daemon_threads = True
    print(f"\nTV tarayicisinda ac:  http://{yerel_ip()}:{args.port}\n")
    print("Durdurmak icin Ctrl+C")
    try:
        sunucu.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
