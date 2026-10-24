#!/bin/bash
# Minimal raw probe of a Frida server: sends one length-prefixed JSON hello and
# prints whatever the server sends back. It is not a Frida client; it only shows
# whether the endpoint answers with the Frida wire format.
#
# Usage: frida-hello.sh [host] [port]
#   FRIDA_PROTOCOL_VERSION=19 frida-hello.sh

set -u

HOST="${1:-127.0.0.1}"
PORT="${2:-57042}"
PROTOCOL_VERSION="${FRIDA_PROTOCOL_VERSION:-19}"

HEADER_FILE=/tmp/lemon-frida-header.bin
BODY_FILE=/tmp/lemon-frida-body.bin
rm -f "$HEADER_FILE" "$BODY_FILE"

be32() {
    local value=$1
    printf '%b' "\\x$(printf '%02x' $(((value >> 24) & 255)))"
    printf '%b' "\\x$(printf '%02x' $(((value >> 16) & 255)))"
    printf '%b' "\\x$(printf '%02x' $(((value >> 8) & 255)))"
    printf '%b' "\\x$(printf '%02x' $((value & 255)))"
}

MESSAGE="{\"type\":\"hello\",\"version\":${PROTOCOL_VERSION},\"parameters\":{\"runtime\":\"qjs\"}}"
LENGTH=${#MESSAGE}

exec 3<>"/dev/tcp/${HOST}/${PORT}" || {
    echo "connect ${HOST}:${PORT} failed"
    exit 1
}
echo "connected ${HOST}:${PORT} hello-version=${PROTOCOL_VERSION} payload-bytes=${LENGTH}"

be32 "$LENGTH" >&3
printf '%s' "$MESSAGE" >&3

timeout 4 dd bs=1 count=4 <&3 of="$HEADER_FILE" 2>/dev/null
READ_STATUS=$?
if [ ! -s "$HEADER_FILE" ]; then
    if [ "$READ_STATUS" -eq 124 ]; then
        echo "reply: none (connection stayed open for 4s)"
    else
        echo "reply: none (peer closed the connection, dd status ${READ_STATUS})"
    fi
    exec 3<&-
    exit 0
fi

echo "reply header bytes: $(od -An -tu1 -v "$HEADER_FILE" | tr -s ' ')"

BODY_LENGTH=$(od -An -tu1 -v "$HEADER_FILE" | awk '{ print $1 * 16777216 + $2 * 65536 + $3 * 256 + $4 }')
echo "reply body length: ${BODY_LENGTH}"

timeout 4 dd bs=1 count="$BODY_LENGTH" <&3 of="$BODY_FILE" 2>/dev/null
echo "reply body:"
cat "$BODY_FILE"
echo

exec 3<&-
