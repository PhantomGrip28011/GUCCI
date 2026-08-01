#!/bin/sh
# ---------------------------------------------------------------
# Force the 3x-ui panel to listen on port 1111 before it starts.
# "x-ui setting" initializes the settings database automatically
# on the first boot and just updates the port on later boots.
# ---------------------------------------------------------------
set -e

# Locate the x-ui binary (path differs between image versions)
if [ -x /app/x-ui ]; then
    XUI_BIN=/app/x-ui
else
    XUI_BIN=/usr/local/x-ui/x-ui
fi

# Pin the panel port to 1111
"$XUI_BIN" setting -port 1111

# Continue with the original image entrypoint (fail2ban + start),
# otherwise start the panel directly
if [ -f /app/DockerEntrypoint.sh ]; then
    exec sh /app/DockerEntrypoint.sh
fi
exec "$XUI_BIN"
