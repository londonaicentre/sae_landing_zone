#!/usr/bin/env bash
#
# Verify the stack end to end: TLS handshake, credentials, DICOMweb
# plugin, and the STOW-RS endpoint.
#
# Usage:
#   ./scripts/smoke-test.sh
#   HOST=10.36.191.245 ./scripts/smoke-test.sh
#   ./scripts/smoke-test.sh path/to/instance.dcm    # also tests an upload
#
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[[ -f "$ROOT/.env" ]] && set -a && source "$ROOT/.env" && set +a

HOST="${HOST:-localhost}"
PORT="${TLS_PORT:-445}"
USER="${ORTHANC_USER:-admin}"
PASS="${ORTHANC_PASSWORD:-}"
CACERT="$ROOT/certs/orthanc.crt"
BASE="https://${HOST}:${PORT}"
DCM="${1:-}"

if [[ -z "$PASS" ]]; then
  echo "ORTHANC_PASSWORD is not set. Copy .env.example to .env first."
  exit 1
fi

pass() { printf '  \033[32mOK\033[0m   %s\n' "$1"; }
fail() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; }

echo "Testing $BASE"
echo

echo "TLS certificate"
if openssl s_client -connect "${HOST}:${PORT}" </dev/null 2>/dev/null \
     | openssl x509 -noout -subject -dates -ext subjectAltName 2>/dev/null; then
  pass "handshake completed"
else
  fail "could not complete a TLS handshake — is nginx up on ${PORT}?"
  exit 1
fi
echo

echo "Certificate validation"
if curl -sf --cacert "$CACERT" -u "$USER:$PASS" "$BASE/system" >/dev/null 2>&1; then
  pass "validates against certs/orthanc.crt"
else
  fail "does not validate — check the SANs cover ${HOST} (see scripts/gen-certs.sh)"
fi
echo

echo "Authentication"
code=$(curl -sk -o /dev/null -w '%{http_code}' -u "$USER:$PASS" "$BASE/system")
case "$code" in
  200) pass "credentials accepted" ;;
  401) fail "401 — credentials do not match ORTHANC__REGISTERED_USERS" ; exit 1 ;;
  *)   fail "unexpected HTTP $code from /system" ; exit 1 ;;
esac

code=$(curl -sk -o /dev/null -w '%{http_code}' -u "$USER:wrong-on-purpose" "$BASE/system")
[[ "$code" == "401" ]] && pass "bad credentials correctly rejected" \
                       || fail "expected 401 for a bad password, got $code"
echo

echo "DICOMweb plugin"
if curl -sk -u "$USER:$PASS" "$BASE/plugins" | grep -q 'dicom-web'; then
  pass "plugin is loaded"
else
  fail "plugin NOT loaded — everything under /dicom-web/ will return 404"
fi

code=$(curl -sk -o /dev/null -w '%{http_code}' -u "$USER:$PASS" "$BASE/dicom-web/studies")
[[ "$code" == "200" ]] && pass "QIDO-RS /dicom-web/studies returns 200" \
                       || fail "QIDO-RS returned HTTP $code"
echo

if [[ -n "$DCM" ]]; then
  echo "STOW-RS upload"
  if [[ ! -f "$DCM" ]]; then
    fail "file not found: $DCM"
    exit 1
  fi
  B="DICOM DATA BOUNDARY"
  TMP=$(mktemp)
  {
    printf -- "--%s\r\n" "$B"
    printf "Content-Type: application/dicom\r\n\r\n"
    cat "$DCM"
    printf "\r\n--%s--\r\n" "$B"
  } > "$TMP"

  resp=$(curl -sk -u "$USER:$PASS" -X POST \
    -H "Content-Type: multipart/related; type=\"application/dicom\"; boundary=\"$B\"" \
    --data-binary @"$TMP" \
    -w '\n%{http_code}' \
    "$BASE/dicom-web/studies")
  rm -f "$TMP"

  code="${resp##*$'\n'}"
  body="${resp%$'\n'*}"
  if [[ "$code" == "200" ]] && grep -q "ReferencedSOPSequence" <<<"$body"; then
    pass "instance accepted"
  else
    fail "HTTP $code"
    echo "$body" | head -c 800
  fi
  echo
fi

echo "Done."
