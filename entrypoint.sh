#!/bin/sh
# ---------------------------------------------------------------
# Single public port entrypoint for 3x-ui
#
#   nginx (public)  ->  62789  (+ platform $PORT if different)
#     /      ->  web panel             (127.0.0.1:2053)
#     /sub/  ->  subscription service  (127.0.0.1:2096)
#
# Panel and the sub service only listen on loopback inside the
# container, so the ONLY port reachable from outside is nginx.
# ---------------------------------------------------------------
set -e

FIXED_PORT=62789
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

# Locate the x-ui binary (path differs between image versions)
if [ -x /app/x-ui ]; then
    XUI_BIN=/app/x-ui
else
    XUI_BIN=/usr/local/x-ui/x-ui
fi

echo "[gucci] Pinning panel settings: internal port 2053, root path, loopback only"
"$XUI_BIN" setting -port 2053 -webBasePath / -listenIP 127.0.0.1 \
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
    set_setting subListen 127.0.0.1
    set_setting subPath  /sub/

    # If the public URL is provided, tell 3x-ui to build sub links with it
    if [ -n "$PUBLIC_URL" ]; then
        set_setting subURI "$PUBLIC_URL"
        echo "[gucci] subURI = $PUBLIC_URL"
    fi
fi

# ---------------------------------------------------------------
# Collision guard: if an xray inbound squats on the public port
# (e.g. user created one on 62789), nginx could never bind and the
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

echo "[gucci] Rendering nginx.conf (public port: $FIXED_PORT on $LISTEN_ADDR)"
envsubst '${LISTEN_ADDR} ${FIXED_PORT} ${EXTRA_LOCATION}' < /etc/nginx/nginx.conf.template > /etc/nginx/nginx.conf

echo "[gucci] Starting x-ui (internal services)..."
if [ -f /app/DockerEntrypoint.sh ]; then
    sh /app/DockerEntrypoint.sh &
else
    "$XUI_BIN" &
fi

sleep 3

echo "[gucci] listeners right before nginx starts:"
netstat -lnt 2>/dev/null || netstat -lntp 2>/dev/null || true

echo "[gucci] Public entrypoint ready: http://<address>:$FIXED_PORT/  (+ /sub/)"
exec nginx -g "daemon off;"
