#!/bin/sh
# ---------------------------------------------------------------
# Single public port entrypoint for 3x-ui
#
#   nginx (public)  ->  ${PORT:-62789}
#     /      ->  web panel             (127.0.0.1:2053)
#     /sub/  ->  subscription service  (127.0.0.1:2096)
#
# Panel and the sub service only listen on loopback inside the
# container, so the ONLY port reachable from outside is nginx.
# ---------------------------------------------------------------
set -e

PUBLIC_PORT="${PORT:-1111}"
DB_FOLDER="${XUI_DB_FOLDER:-/etc/x-ui}"
DB="$DB_FOLDER/x-ui.db"

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

echo "[gucci] Rendering nginx.conf (public port: $PUBLIC_PORT)"
envsubst '${PORT}' < /etc/nginx/nginx.conf.template > /etc/nginx/nginx.conf

echo "[gucci] Starting x-ui (internal services)..."
if [ -f /app/DockerEntrypoint.sh ]; then
    sh /app/DockerEntrypoint.sh &
else
    "$XUI_BIN" &
fi

sleep 2

echo "[gucci] Public entrypoint ready: http://<address>:$PUBLIC_PORT/  (+ /sub/)"
exec nginx -g "daemon off;"
