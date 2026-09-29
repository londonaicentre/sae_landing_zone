#!/usr/bin/env bash
#
# Generate a self-signed TLS certificate and DH parameters for the
# nginx proxy in front of Orthanc.
#
# The certificate MUST carry the IP or hostname that clients use to
# connect, in its Subject Alternative Name. A certificate with only a
# CN will fail validation on modern TLS clients.
#
# Usage:
#   ./scripts/gen-certs.sh                       # uses SAN_LIST below
#   SAN_LIST="IP:10.36.191.245,DNS:orthanc" ./scripts/gen-certs.sh
#
set -euo pipefail

CERT_DIR="${CERT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/certs}"

# Every address a client might use to reach this server. Add extras now:
# changing the SAN list later means regenerating the cert and
# re-importing it on every client that trusts it.
SAN_LIST="${SAN_LIST:-IP:10.36.191.245,DNS:orthanc,DNS:localhost,IP:127.0.0.1}"

SUBJECT="${SUBJECT:-/C=GB/O=GSTT/CN=orthanc}"
DAYS="${DAYS:-825}"
DH_BITS="${DH_BITS:-2048}"

mkdir -p "$CERT_DIR"

if [[ -f "$CERT_DIR/orthanc.crt" && "${FORCE:-0}" != "1" ]]; then
  echo "Certificate already exists at $CERT_DIR/orthanc.crt"
  echo "Re-run with FORCE=1 to overwrite it."
  echo
  echo "Current certificate:"
  openssl x509 -in "$CERT_DIR/orthanc.crt" -noout -subject -dates
  openssl x509 -in "$CERT_DIR/orthanc.crt" -noout -ext subjectAltName
  exit 0
fi

echo "Generating self-signed certificate"
echo "  subject: $SUBJECT"
echo "  SANs:    $SAN_LIST"
echo "  validity: $DAYS days"
echo

openssl req -x509 -nodes -newkey rsa:4096 \
  -keyout "$CERT_DIR/orthanc.key" \
  -out "$CERT_DIR/orthanc.crt" \
  -days "$DAYS" -sha256 \
  -subj "$SUBJECT" \
  -addext "subjectAltName=$SAN_LIST" \
  -addext "keyUsage=digitalSignature,keyEncipherment" \
  -addext "extendedKeyUsage=serverAuth"

chmod 600 "$CERT_DIR/orthanc.key"
chmod 644 "$CERT_DIR/orthanc.crt"

if [[ ! -f "$CERT_DIR/dhparam.pem" ]]; then
  echo
  echo "Generating ${DH_BITS}-bit DH parameters (this takes a minute or two)..."
  openssl dhparam -out "$CERT_DIR/dhparam.pem" "$DH_BITS" 2>/dev/null
  chmod 644 "$CERT_DIR/dhparam.pem"
fi

echo
echo "Done. Files written to $CERT_DIR:"
ls -l "$CERT_DIR"
echo
openssl x509 -in "$CERT_DIR/orthanc.crt" -noout -subject -dates -ext subjectAltName
echo
echo "Send certs/orthanc.crt (the certificate ONLY, never orthanc.key)"
echo "to the sending system so it can trust this server."
