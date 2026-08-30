# signal-cli running as an HTTP daemon — the transport the Hermes agent's native
# Signal adapter speaks (GET /api/v1/check, SSE GET /api/v1/events, JSON-RPC
# POST /api/v1/rpc). This is NOT the bbernhard/signal-cli-rest-api (different
# endpoints); Hermes needs signal-cli's own `daemon --http` interface.
#
# signal-cli 0.14.x is compiled for Java 25 (class file v69) — using an older JRE
# fails at launch with UnsupportedClassVersionError. Keep the JRE >= the signal-cli
# build target; bump both together if you change the version.
FROM eclipse-temurin:25-jre

ARG SIGNAL_CLI_VERSION=0.14.5

RUN apt-get update \
 && apt-get install -y --no-install-recommends qrencode ca-certificates wget \
 && wget -qO /tmp/signal-cli.tar.gz \
      "https://github.com/AsamK/signal-cli/releases/download/v${SIGNAL_CLI_VERSION}/signal-cli-${SIGNAL_CLI_VERSION}.tar.gz" \
 && tar -xzf /tmp/signal-cli.tar.gz -C /opt \
 && ln -s "/opt/signal-cli-${SIGNAL_CLI_VERSION}/bin/signal-cli" /usr/local/bin/signal-cli \
 && rm /tmp/signal-cli.tar.gz \
 && apt-get purge -y wget && apt-get autoremove -y && rm -rf /var/lib/apt/lists/*

# All signal-cli state (the linked-device keys, contacts, etc.) lives under
# /data, bind-mounted to a named volume so the link survives container rebuilds.
ENV SIGNAL_CONFIG_DIR=/data
COPY link.sh /usr/local/bin/link.sh
# Strip any CR (the file may be authored on Windows) so /bin/sh doesn't choke on
# a "\r" in the shebang/commands, then make it executable.
RUN sed -i 's/\r$//' /usr/local/bin/link.sh && chmod +x /usr/local/bin/link.sh

EXPOSE 8080

# Serve the HTTP daemon on all interfaces so the hermes-agent container can reach
# it over the compose network. SIGNAL_ACCOUNT is provided at runtime via env.
CMD ["sh", "-c", "exec signal-cli --config /data -a \"$SIGNAL_ACCOUNT\" daemon --http 0.0.0.0:8080"]
