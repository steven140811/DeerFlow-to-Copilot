#!/usr/bin/env bash
#
# wait-for-port.sh - Wait for a TCP port to become available
#
# Usage: ./scripts/wait-for-port.sh <port> [timeout_seconds] [service_name]
#
# Arguments:
#   port             - TCP port to wait for (required)
#   timeout_seconds  - Max seconds to wait (default: 60)
#   service_name     - Display name for messages (default: "Service")
#
# Exit codes:
#   0 - Port is listening
#   1 - Timed out waiting

PORT="${1:?Usage: wait-for-port.sh <port> [timeout] [service_name]}"
TIMEOUT="${2:-60}"
SERVICE="${3:-Service}"

elapsed=0
interval=1

is_port_listening() {
    if command -v lsof >/dev/null 2>&1; then
        if lsof -nP -iTCP:"$PORT" -sTCP:LISTEN -t >/dev/null 2>&1; then
            return 0
        fi
    fi

    if command -v ss >/dev/null 2>&1; then
        if ss -ltn "( sport = :$PORT )" 2>/dev/null | tail -n +2 | grep -q .; then
            return 0
        fi
    fi

    if command -v netstat >/dev/null 2>&1; then
        if netstat -ltn 2>/dev/null | awk '{print $4}' | grep -Eq "(^|[.:])${PORT}$"; then
            return 0
        fi
    fi

    # Windows Git Bash often lacks lsof/ss, and `netstat -ltn` is not portable
    # there. Fall back to a TCP connect probe through Python when available.
    if command -v python >/dev/null 2>&1; then
        if python -c "import socket, sys; port = int(sys.argv[1]); sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM); sock.settimeout(0.5); rc = sock.connect_ex(('127.0.0.1', port)); sock.close(); sys.exit(0 if rc == 0 else 1)" "$PORT" >/dev/null 2>&1; then
            return 0
        fi
    elif command -v python3 >/dev/null 2>&1; then
        if python3 -c "import socket, sys; port = int(sys.argv[1]); sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM); sock.settimeout(0.5); rc = sock.connect_ex(('127.0.0.1', port)); sock.close(); sys.exit(0 if rc == 0 else 1)" "$PORT" >/dev/null 2>&1; then
            return 0
        fi
    fi

    return 1
}

while ! is_port_listening; do
    if [ "$elapsed" -ge "$TIMEOUT" ]; then
        echo ""
        echo "✗ $SERVICE failed to start on port $PORT after ${TIMEOUT}s"
        exit 1
    fi
    printf "\r  Waiting for %s on port %s... %ds" "$SERVICE" "$PORT" "$elapsed"
    sleep "$interval"
    elapsed=$((elapsed + interval))
done

printf "\r  %-60s\r" ""   # clear the waiting line
