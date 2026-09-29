# orthanc-dicomweb

Orthanc with the DICOMweb plugin, behind an nginx TLS reverse proxy on port 445.

Receives studies over STOW-RS from a Sectra sending service.

## Layout

```
.
├── docker-compose.yml      Orthanc + nginx
├── .env.example            Copy to .env and set the password
├── nginx/orthanc.conf      TLS termination, large-body streaming
├── scripts/gen-certs.sh    Self-signed cert with SANs + DH params
├── scripts/smoke-test.sh   End-to-end verification
└── certs/                  Generated TLS material (gitignored)
```

## Setup

```bash
cp .env.example .env
chmod 600 .env
# edit .env and set ORTHANC_PASSWORD

# Generate the certificate. Set SAN_LIST to every address clients will use.
SAN_LIST="IP:10.36.191.245,DNS:orthanc,DNS:localhost" ./scripts/gen-certs.sh

docker compose up -d
./scripts/smoke-test.sh
```

To also test an upload, pass a DICOM file:

```bash
./scripts/smoke-test.sh /path/to/instance.dcm
```

## Endpoints

With `HOST` as the server address:

| Purpose | URL |
|---|---|
| STOW-RS (upload) | `https://HOST:445/dicom-web/studies` |
| QIDO-RS (query) | `https://HOST:445/dicom-web/studies` |
| WADO-URI | `https://HOST:445/wado` |
| Orthanc Explorer | `https://HOST:445/app/explorer.html` |
| REST API | `https://HOST:445/instances` |
| DICOM C-STORE | `HOST:4242` (DIMSE, not proxied — no TLS) |

All HTTP endpoints require Basic auth with the credentials from `.env`.

## Sectra sender configuration

Two things caused real trouble during setup, both worth re-checking after
any change:

1. **The target must be `/dicom-web/studies`,** and the request must be a
   `POST` to that path. Sectra's documentation is incomplete on this point.
   Pointing at the base URL or any other path returns 404 from Orthanc,
   which surfaces on the Sectra side as a generic not-found error.
2. **The scheme is now `https`,** on the same host and port as before.
   Confirm the sender was updated and did not silently stay on `http`.

### Trusting the certificate

The certificate is self-signed, so it fails validation by default. Send
`certs/orthanc.crt` — the certificate only, **never** `orthanc.key` — to
the Sectra side to import into their trust store.

Most PACS vendors deliberately do not offer a "skip certificate
validation" option. If Sectra's configuration has no way to add a trusted
CA, a self-signed cert will not work and you will need one issued by a CA
their system already trusts — in an NHS trust, usually the internal PKI
rather than a public CA.

### Port 445

445 is the SMB port. Keep in mind:

- It is already in use on Windows hosts, and often on macOS.
- Many firewalls and cloud security groups block it by default because of
  SMB worms, so a client may fail to reach it even when the service is up.
- Some TLS clients assume port 443 means TLS and anything else means plain
  HTTP. If Sectra's connector cannot set the scheme independently of the
  port, TLS on 445 may not work and 443 would be the safer target.

To move to 443, set `TLS_PORT=443` in `.env` and change `listen 445 ssl;`
to `listen 443 ssl;` in `nginx/orthanc.conf`. The certificate needs no
changes — SANs cover names and IPs, not ports.

## Logging

`VERBOSE_ENABLED=true` in `.env` is the sensible default. For deeper
debugging, raise the level at runtime without restarting:

```bash
# Categories: http, dicom, plugins, sqlite, jobs, lua, generic
curl -k -u admin:"$ORTHANC_PASSWORD" -X PUT -d "trace" \
  https://HOST:445/tools/log-level-http

# Put it back afterwards
curl -k -u admin:"$ORTHANC_PASSWORD" -X PUT -d "default" \
  https://HOST:445/tools/log-level-http
```

Trace on `http` and `plugins` is the most useful pair for DICOMweb
routing problems: it shows the request line each client actually sent,
which is how the `/studies` path issue above was identified.

**Trace logs the full `Authorization` header.** HTTP Basic auth is only
base64-encoded, so anyone with access to the logs can read the password.
Turn trace off once you are done, and treat any password that has appeared
in a shared log as compromised.

## Notes on data

This stack terminates TLS at nginx; traffic between nginx and Orthanc is
plain HTTP over the internal Docker network only. Orthanc's database
lives in the `orthanc-db` named volume.

DICOM files contain patient identifiers. The `.gitignore` excludes `*.dcm`
and `test-data/`, but check before committing anything from a test run.
