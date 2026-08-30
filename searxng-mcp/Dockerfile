# SearXNG MCP server exposed over streamable HTTP, using the SAME supergateway
# pattern as filesystem-mcp (which is confirmed working with this Hermes build).
# This avoids the third-party image's localhost-only bind / env quirks.
# supergateway wraps the stdio `mcp-searxng` server and serves it at /mcp on
# 0.0.0.0:8090. The wrapped server reads SEARXNG_URL from the environment.
FROM node:22-alpine

RUN npm install -g supergateway mcp-searxng

EXPOSE 8090
CMD ["supergateway", \
     "--stdio", "mcp-searxng", \
     "--outputTransport", "streamableHttp", \
     "--port", "8090"]
