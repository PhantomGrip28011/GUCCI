#!/usr/bin/env python3
# subshim — presentation-only layer for the 3x-ui subscription feed.
#
# It proxies the REAL panel sub service (127.0.0.1:2096) and, without
# touching any panel setting or config value, re-names/re-orders the
# emitted links into the exact display layout:
#
#   1) 🇩🇪 Germany
#   2) <persian daily-update banner>
#   3) 🇳🇱 Netherlands
#   4) 🇦🇪 UAE
#   5) 🇹🇷 Turkey
#   6) ✅ <email> 📊 <live used traffic> | 🕐 <live days left>
#
# The last entry's numbers are computed PER REQUEST from the panel's own
# subscription-userinfo header, so they always mirror the user's live usage.
# On ANY error the raw upstream response is returned untouched.
import base64
import gzip
import time
import traceback
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

UPSTREAM = "http://127.0.0.1:2096"
LISTEN = ("127.0.0.1", 2097)

PASSTHRU_HEADERS = [
    "subscription-userinfo",
    "profile-update-interval",
    "profile-web-page-url",
    "profile-title",
    "announce",
    "support-url",
    "content-disposition",
    "refresh",
]

COUNTRIES = ["🇩🇪 Germany", "🇳🇱 Netherlands", "🇦🇪 UAE", "🇹🇷 Turkey"]
BANNER = "لطفاً اشتراک خود را هر روز به‌روزرسانی کنید 🔄"

# The inbound remark in the panel. When a remark is set, the panel names
# every feed link "<remark>-<email>"; strip it so the live info card keeps
# showing the pure email (e.g. "✅ xgq2kf133p 📊 344.8 MB | 🕐 ∞").
REMARK = "🇩🇪 🇳🇱 🇦🇪 🇹🇷 GUCCI"


def clone(link, remark):
    base = link.split("#", 1)[0]
    return base + "#" + urllib.parse.quote(remark)


def human(n):
    try:
        n = float(n)
    except Exception:
        return "0 B"
    for unit in ["B", "KB", "MB", "GB", "TB"]:
        if n < 1024 or unit == "TB":
            return f"{n:.1f} {unit}"
        n /= 1024
    return f"{n:.1f} TB"


def pick(lines, needle, fallback):
    for l in lines:
        if needle in l:
            return l
    return fallback


def build(decoded_body, userinfo, subid):
    lines = [l.strip() for l in decoded_body.replace("\r", "").split("\n") if l.strip()]
    vless = [l for l in lines if l.startswith("vless://")]
    if not vless:
        return None  # nothing to restyle -> pass through

    tpl_main = pick(vless, "@gucci.vipermatrix7862.cc.cd", vless[0])
    tpl_ip = pick(vless, "@66.33.22.234", tpl_main)
    tpl_dom = pick(vless, "@mainline.proxy.rlwy.net", tpl_main)

    # client email = fragment remark of the main template (fallback: subId)
    email = subid
    if "#" in tpl_main:
        email = urllib.parse.unquote(tpl_main.rsplit("#", 1)[1]) or subid
    prefix = REMARK + "-"
    if email.startswith(prefix):
        email = email[len(prefix):]

    up = down = total = expire = 0
    for part in (userinfo or "").split(";"):
        if "=" in part:
            k, v = part.split("=", 1)
            k, v = k.strip(), v.strip()
            try:
                if k == "upload":
                    up = int(v)
                elif k == "download":
                    down = int(v)
                elif k == "total":
                    total = int(v)
                elif k == "expire":
                    expire = int(v)
            except ValueError:
                pass

    used_h = human(up + down)
    if expire > 0:
        days = str(max(0, (expire - int(time.time()) + 86399) // 86400))
    else:
        days = "∞"

    info = f"✅ {email} 📊 {used_h} | 🕐 {days}"

    out = [
        clone(tpl_main, COUNTRIES[0]),  # 🇩🇪 Germany
        clone(tpl_ip, BANNER),          # update-daily banner (persian)
        clone(tpl_main, COUNTRIES[1]),  # 🇳🇱 Netherlands
        clone(tpl_main, COUNTRIES[2]),  # 🇦🇪 UAE
        clone(tpl_main, COUNTRIES[3]),  # 🇹🇷 Turkey
        clone(tpl_dom, info),           # live usage card
    ]
    return base64.b64encode(("\n".join(out) + "\n").encode()).decode()


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *a):
        pass

    def _fetch_upstream(self):
        # The panel sub server enforces its configured subDomain for SOME
        # client types and 400s otherwise; prefer the canonical panel
        # domain, and fall back to bare loopback on any failure.
        ua = self.headers.get("User-Agent", "subshim")
        ac = self.headers.get("Accept", "*/*")
        for host in ("vipermatrix7862.cc.cd", "127.0.0.1"):
            req = urllib.request.Request(
                UPSTREAM + self.path,
                data=None,
                headers={"User-Agent": ua, "Accept": ac,
                         "Accept-Encoding": "identity", "Host": host},
            )
            try:
                resp = urllib.request.urlopen(req, timeout=10)
            except urllib.error.HTTPError as e:
                resp = e  # an HTTP error is still a relayable response
            except Exception:
                continue
            if getattr(resp, "status", 200) < 400:
                return resp
            last = resp
        return last

    def do_GET(self):
        resp = None
        try:
            resp = self._fetch_upstream()
            status = resp.status
            body = resp.read()
            if resp.headers.get("Content-Encoding") == "gzip":
                body = gzip.decompress(body)
            uinfo = resp.headers.get("subscription-userinfo", "")
            extra = {}
            for h in PASSTHRU_HEADERS:
                v = resp.headers.get(h)
                if v:
                    extra[h] = v

            content_type = "text/plain; charset=utf-8"
            if self.path.startswith("/sub/"):
                subid = self.path.rstrip("/").rsplit("/", 1)[-1]
                try:
                    decoded = base64.b64decode(body, validate=False).decode()
                    rebuilt = build(decoded, uinfo, subid)
                    if rebuilt:
                        body = rebuilt.encode()
                    else:
                        # pass through non-vless feeds untouched
                        content_type = resp.headers.get("Content-Type", content_type)
                except Exception:
                    content_type = resp.headers.get("Content-Type", content_type)
            else:
                content_type = resp.headers.get("Content-Type", content_type)

            self.send_response(status)
            self.send_header("Content-Type", content_type)
            for h, v in extra.items():
                self.send_header(h, v)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            if self.command == "GET":
                self.wfile.write(body)
        except Exception:
            # log the real cause to the container logs, then degrade gracefully
            try:
                print("[subshim] ERROR on", self.path)
                traceback.print_exc()
            except Exception:
                pass
            try:
                if resp is not None:
                    resp.close()
            except Exception:
                pass
            self.send_response(502)
            self.send_header("Content-Length", "0")
            self.end_headers()

    do_HEAD = do_GET


if __name__ == "__main__":
    ThreadingHTTPServer(LISTEN, Handler).serve_forever()
