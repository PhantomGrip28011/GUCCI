# ========================================================
# 3x-ui — single public port (default 1111)
# Web Panel      ->  /
# Subscription   ->  /sub/   (same address as the panel)
# NGINX sits in front and fans out to the internal
# services; only ONE port (${PORT:-1111}) is exposed.
# ========================================================
FROM ghcr.io/mhsanaei/3x-ui:latest

RUN apk add --no-cache nginx sqlite gettext

COPY nginx.conf.template /etc/nginx/nginx.conf.template
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# The ONLY public port (panel + subscription together)
EXPOSE 1111

ENTRYPOINT ["/bin/sh", "/entrypoint.sh"]
