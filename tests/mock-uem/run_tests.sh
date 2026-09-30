#!/usr/bin/env bash
# Starts the HTTPS mock UEM, trusts its self-signed cert for .NET, runs the PowerShell tests.
# Needs: python3, openssl, pwsh (PowerShell 7+). Usage: PWSH=/path/to/pwsh ./run_tests.sh
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
PWSH="${PWSH:-pwsh}"
T="$(mktemp -d)"
trap 'kill $SRV 2>/dev/null || true; rm -rf "$T"' EXIT
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$T/key.pem" -out "$T/cert.pem" -days 2 \
  -subj "/CN=localhost" -addext "subjectAltName=DNS:localhost,IP:127.0.0.1" >/dev/null 2>&1
python3 "$HERE/mock_uem_server.py" 8443 "$T/cert.pem" "$T/key.pem" >"$T/server.log" 2>&1 &
SRV=$!
sleep 1
export SSL_CERT_FILE="$T/cert.pem"
export DOTNET_SYSTEM_GLOBALIZATION_INVARIANT=1
"$PWSH" -NoProfile -File "$HERE/Test-Ws1Scripts.ps1" -Pwsh "$PWSH"
