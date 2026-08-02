#!/bin/sh
# ---------------------------------------------------------------
# Single public port entrypoint for 3x-ui
#
#   nginx (public)  ->  2053  (+ platform $PORT if different)
#     /      ->  web panel             (127.0.0.1:12053)
#     /sub/  ->  subscription service  (127.0.0.1:2096)
#
# Panel and the sub service only listen on loopback inside the
# container, so the ONLY port reachable from outside is nginx.
# ---------------------------------------------------------------
set -e

FIXED_PORT=2053
PORT="${PORT:-$FIXED_PORT}"
export PORT
DB_FOLDER="${XUI_DB_FOLDER:-/etc/x-ui}"
DB="$DB_FOLDER/x-ui.db"

# Public URL for sub links: explicit PUBLIC_URL wins, otherwise auto-detect
# from well-known platform variables (Railway / Render / Koyeb).
if [ -z "$PUBLIC_URL" ]; then
    if [ -n "$RAILWAY_PUBLIC_DOMAIN" ]; then
        PUBLIC_URL="https://$RAILWAY_PUBLIC_DOMAIN"
    elif [ -n "$RENDER_EXTERNAL_HOSTNAME" ]; then
        PUBLIC_URL="https://$RENDER_EXTERNAL_HOSTNAME"
    elif [ -n "$KOYEB_PUBLIC_DOMAIN" ]; then
        PUBLIC_URL="https://$KOYEB_PUBLIC_DOMAIN"
    fi
fi
[ -n "$PUBLIC_URL" ] && echo "[gucci] Public URL: $PUBLIC_URL"
# Dedicated sub domain (targetPort 2096) — panel advertises THIS for sub links
SUB_URI="${SUB_URI:-https://vipermatrix7862.cc.cd:2096}"
export SUB_URI

# Locate the x-ui binary (path differs between image versions)
if [ -x /app/x-ui ]; then
    XUI_BIN=/app/x-ui
else
    XUI_BIN=/usr/local/x-ui/x-ui
fi

echo "[gucci] Pinning panel settings: internal port 12053, secret path /gucciBMW/, root path, loopback only"
"$XUI_BIN" setting -port 12053 -webBasePath /gucciBMW/ -listenIP 127.0.0.1 \
    || echo "[gucci] WARN: could not apply panel settings"

# Upsert helper: settings.key is only indexed (not unique), so UPDATE first,
# then INSERT if the row does not exist yet.
set_setting() {
    sqlite3 "$DB" "UPDATE settings SET value='$2' WHERE key='$1';"
    sqlite3 "$DB" "INSERT INTO settings(key, value) SELECT '$1', '$2' WHERE NOT EXISTS (SELECT 1 FROM settings WHERE key='$1');"
}

if command -v sqlite3 >/dev/null 2>&1 && [ -f "$DB" ]; then
    echo "[gucci] Enabling subscription service on loopback 2096 (/sub/)"
    set_setting subEnable true
    set_setting subListen ''    # all interfaces: the dedicated sub domain hits :2096 directly
    set_setting subPath  /sub/

    # If the public URL is provided, tell 3x-ui to build sub links with it
    if [ -n "$PUBLIC_URL" ]; then
        set_setting subURI "$SUB_URI"
        echo "[gucci] subURI = $SUB_URI"
    fi

    # Clear leftover hosts-table rows (written by 3.x panel eras): in v2.9 a
    # hosts row wins over externalProxy in sub links — the stale 66.33.22.234
    # entry lived exactly there. Empty hosts => externalProxy decides.
    sqlite3 "$DB" "DELETE FROM hosts;" 2>&1 || true
    echo "[gucci] hosts table cleared (stale sub-link entries gone)"

    # Drop ghost inline clients whose tgId is a STRING (added via v2.9-era API).
    # 3.x unmarshals inbounds.settings into int64 tgId and then EVERY inbound
    # update fails. They re-live in the clients table via the 3.x API instead.
    sqlite3 "$DB" "UPDATE inbounds SET settings = json_set(settings, '\$.clients', COALESCE((SELECT json_group_array(json(j.value)) FROM json_each(settings,'\$.clients') j WHERE json_extract(j.value,'\$.email') NOT IN ('gucci-sub2')), json('[]'))) WHERE id=1 AND settings LIKE '%\"tgId\": \"\"%';" 2>&1 || true
    echo "[gucci] ghost inline clients (string tgId) purged from inbound settings"

    # Version-aware cleanup for gucci-sub2:
    #  - v2.x schema (no external_proxy column): a clients-table row crashes
    #    the 2.9 sub renderer ("Error!" 400); 2.9 reads the inline settings
    #    copy instead => delete the table row there.
    #  - v3.x schema (external_proxy column exists): the clients TABLE is the
    #    source of truth for the sub service => the row MUST be kept.
    if sqlite3 "$DB" "PRAGMA table_info(inbounds);" 2>/dev/null | grep -q 'external_proxy'; then
        echo "[gucci] 3.x schema detected — keeping clients-table rows (source of truth)"
    else
        sqlite3 "$DB" "DELETE FROM clients WHERE email='gucci-sub2';" 2>&1 || true
        echo "[gucci] 2.x schema — stale clients-table row for gucci-sub2 cleared"
    fi

    # Pin inbound #1 externalProxy to the live Railway TCP proxy, so vless/sub
    # links ALWAYS carry the working public address (kills the flip-flop that
    # used to revert links to the stale 66.33.22.234 entry on every redeploy).
    if [ -n "$RAILWAY_TCP_PROXY_DOMAIN" ] && [ -n "$RAILWAY_TCP_PROXY_PORT" ]; then
        sqlite3 "$DB" "UPDATE inbounds SET external_proxy='[{\"forceTls\":\"same\",\"dest\":\"$RAILWAY_TCP_PROXY_DOMAIN\",\"port\":$RAILWAY_TCP_PROXY_PORT,\"remark\":\"rlwy-proxy\",\"security\":\"reality\"}]' WHERE id=1;" 2>&1 || true
        sqlite3 "$DB" "SELECT id, port, external_proxy FROM inbounds;" 2>&1 | head -5 || true
        echo "[gucci] externalProxy pinned -> $RAILWAY_TCP_PROXY_DOMAIN:$RAILWAY_TCP_PROXY_PORT"
    else
        echo "[gucci] WARN: tcp proxy env missing — externalProxy left as-is"
    fi
fi

# ---------------------------------------------------------------
# Collision guard: if an xray inbound squats on the public port
# (e.g. user created one on 2053), nginx could never bind and the
# container crash-loops. Move those inbounds to loopback:38080 and,
# when they use WebSocket, expose them through nginx on their path.
# ---------------------------------------------------------------
INTERNAL_INBOUND_PORT=38080
EXTRA_LOCATION=""
if command -v sqlite3 >/dev/null 2>&1 && [ -f "$DB" ]; then
    echo "[gucci] diagnostics — DB tables:"
    sqlite3 "$DB" ".tables" 2>&1 | head -5 || true
    echo "[gucci] diagnostics — inbound rows (id/enable/listen/port/protocol):"
    sqlite3 "$DB" "SELECT id, enable, listen, port, protocol FROM inbounds;" 2>&1 | head -10 || true

    CONFLICT_ID=$(sqlite3 "$DB" "SELECT id FROM inbounds WHERE port=$FIXED_PORT LIMIT 1;" 2>/dev/null || true)
    if [ -n "$CONFLICT_ID" ]; then
        echo "[gucci] Inbound(s) found on public port $FIXED_PORT -> moving to 127.0.0.1:$INTERNAL_INBOUND_PORT"
        sqlite3 "$DB" "UPDATE inbounds SET port=$INTERNAL_INBOUND_PORT, listen='127.0.0.1' WHERE port=$FIXED_PORT;" 2>/dev/null || true
        STREAM=$(sqlite3 "$DB" "SELECT stream_settings FROM inbounds WHERE id=$CONFLICT_ID;" 2>/dev/null || true)
        WS_PATH=$(printf '%s' "$STREAM" | grep -o '"path"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/.*: *"\([^"]*\)"/\1/')
        if [ -n "$WS_PATH" ] && [ "$WS_PATH" != "/" ]; then
            echo "[gucci] Routing inbound WebSocket path $WS_PATH via nginx"
            EXTRA_LOCATION="location $WS_PATH {
            proxy_pass http://127.0.0.1:$INTERNAL_INBOUND_PORT;
            proxy_http_version 1.1;
            proxy_set_header Upgrade \$http_upgrade;
            proxy_set_header Connection \"upgrade\";
            proxy_set_header Host \$host;
            proxy_set_header X-Real-IP \$remote_addr;
            proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        }"
        fi
    else
        echo "[gucci] No inbound occupies the public port — all clear"
    fi
fi

# Bind ONLY the fixed public port on the container's primary IP.
# NOTE: Railway injects $PORT that now follows the TCP-proxied app port
# (40089) — an earlier fallback that also listened on $PORT collided
# with the user's inbound and crash-looped the service, so it is gone.
HOST_IP=$(hostname -i 2>/dev/null | awk '{print $1}')
if [ -z "$HOST_IP" ]; then
    HOST_IP=$(ip -4 addr show eth0 2>/dev/null | grep -o 'inet [0-9.]*' | awk '{print $2}')
fi
LISTEN_ADDR="${HOST_IP:-0.0.0.0}"
export LISTEN_ADDR FIXED_PORT EXTRA_LOCATION

# ------------------------------------------------------------------
# Static subscription feed, served by nginx at /subfix/gucci
# (base64 of the working vless links with the public TCP-proxy address)
# ------------------------------------------------------------------
SUBFIX_B64="dmxlc3M6Ly9kZjlkZmM2Yy0wNDA3LTQzNzUtYjc1OC0yMmQyNWE3Y2I0MzNAaGF5YWJ1c2EucHJveHkucmx3eS5uZXQ6MTEyNzk/ZW5jcnlwdGlvbj1ub25lJmZwPWNocm9tZSZwYms9NUxMZ0RwaEthMTdCYnlOeGJ3SUYyRnItdTFmZThlYlh3SGU0Q1JuekRYMCZzZWN1cml0eT1yZWFsaXR5JnNpZD0wMGMxZDgyMWI2YzYmc25pPXlhaG9vLmNvbSZzcHg9JTJGMjcxMmRkMTJiNjE2YWNlJnR5cGU9dGNwI3hncTJrZjEzM3AKdmxlc3M6Ly80NTM4MjYxMi0xNjEwLTRhODEtODk4MC1kNDY4ODM3MDM5YjJAaGF5YWJ1c2EucHJveHkucmx3eS5uZXQ6MTEyNzk/ZW5jcnlwdGlvbj1ub25lJmZwPWNocm9tZSZwYms9NUxMZ0RwaEthMTdCYnlOeGJ3SUYyRnItdTFmZThlYlh3SGU0Q1JuekRYMCZzZWN1cml0eT1yZWFsaXR5JnNpZD1jYzgyYTBhNGQ2JnNuaT15YWhvby5jb20mc3B4PSUyRjg2MTZjN2Q4MjRhMDJkNiZ0eXBlPXRjcCNndWNjaS1zdWIxCnRnOi8vcHJveHk/c2VydmVyPXplcGh5ci5wcm94eS5ybHd5Lm5ldCZwb3J0PTU3MDczJnNlY3JldD00ZTViMmRkN2M1ZjE3YjMwMWU0MDhiODMxOTFiNzEwZA=="

SUBFIX_LOCATION="location = /subfix/gucci {
            default_type text/plain;
            add_header profile-update-interval 1;
            return 200 \"$SUBFIX_B64\";
        }"
export SUBFIX_LOCATION

# Pure-black page served for / and any unknown path (panel stays
# undiscoverable; no railway error page ever leaks through)
BLACK_BODY='<!doctype html><html lang=en><head><meta charset=utf-8><title></title><style>html,body{margin:0;height:100%;background:#000}</style></head><body></body></html>'
export BLACK_BODY

echo "[gucci] Rendering nginx.conf (public port: $FIXED_PORT on $LISTEN_ADDR)"
envsubst '${LISTEN_ADDR} ${FIXED_PORT} ${EXTRA_LOCATION} ${SUBFIX_LOCATION} ${BLACK_BODY}' < /etc/nginx/nginx.conf.template > /etc/nginx/nginx.conf

echo "[gucci] Starting x-ui (internal services)..."
if [ -f /app/DockerEntrypoint.sh ]; then
    sh /app/DockerEntrypoint.sh &
else
    "$XUI_BIN" &
fi

# subshim: presentation layer for /sub/ (names/links + live usage card);
# safely falls back to raw upstream on any error.
if command -v python3 >/dev/null 2>&1; then
    echo "[gucci] Starting subshim on 127.0.0.1:2097"
    ( while true; do python3 /usr/local/bin/subshim.py; sleep 2; done ) &
fi

sleep 3

echo "[gucci] listeners right before nginx starts:"
netstat -lnt 2>/dev/null || netstat -lntp 2>/dev/null || true

echo "[gucci] Public entrypoint ready: http://<address>:$FIXED_PORT/  (+ /sub/)"
exec nginx -g "daemon off;"
