# ========================================================
# 3x-ui panel — pinned to run ONLY on port 1111
# ========================================================
FROM ghcr.io/mhsanaei/3x-ui:latest

# Startup script that forces the panel port to 1111 on every boot
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# The panel listens ONLY on this port
EXPOSE 1111

ENTRYPOINT ["/bin/sh", "/entrypoint.sh"]
