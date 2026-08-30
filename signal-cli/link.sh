#!/bin/sh
# Link this signal-cli as a secondary device to your Signal account, rendering
# the linking URI as a QR code in the terminal (no browser needed).
#
#   docker compose run --rm signal-cli link.sh
# Then scan the QR from the Signal app: Settings -> Linked devices -> +
set -e

NAME="${1:-HermesAgent}"
OUT=/tmp/signal-link.out
ERR=/tmp/signal-link.err
: > "$OUT"; : > "$ERR"

echo "Requesting a device-link URI from Signal (the JVM can take ~10s to start)..."
# `signal-cli link` prints the linking URI on its first output line, then blocks
# until you approve it on your phone. Run it in the background and watch its output.
signal-cli --config /data link -n "$NAME" >"$OUT" 2>"$ERR" &
PID=$!

URI=""
i=0
while [ "$i" -lt 60 ]; do
  # The URI looks like  sgnl://linkdevice?...  or  tsdevice:/?...
  # Pipe both files via cat so grep does NOT prefix matches with the filename
  # (grep over multiple files adds "<file>:" which would corrupt the QR/URI).
  URI=$(cat "$OUT" "$ERR" 2>/dev/null | grep -aoE '(sgnl://linkdevice|tsdevice:)[^[:space:]]*' | head -n1 || true)
  [ -n "$URI" ] && break
  kill -0 "$PID" 2>/dev/null || break   # signal-cli exited (probably an error)
  i=$((i + 1)); sleep 1
done

if [ -z "$URI" ]; then
  echo "Could not obtain a link URI. signal-cli said:" >&2
  cat "$ERR" "$OUT" >&2 2>/dev/null || true
  kill "$PID" 2>/dev/null || true
  exit 1
fi

echo
echo "Scan this QR in Signal -> Settings -> Linked devices -> +"
echo
qrencode -t ANSIUTF8 "$URI" || qrencode -t ANSI "$URI" || true
echo
echo "If the QR won't scan, paste this URI into any QR generator on another screen:"
echo "  $URI"
echo
echo "Waiting for you to approve the link on your phone..."
wait "$PID" || true
echo
echo "Done. Verify the account is linked:"
echo "  docker compose run --rm signal-cli signal-cli --config /data listAccounts"
