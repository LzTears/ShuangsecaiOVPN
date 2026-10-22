# Public smoke-test fixture

`test-only.key` is an intentionally public, disposable test key. It is not a user credential and must never be used by a real VPN server or client.

`smoke-test-only.ovpn` embeds this key and a short-lived self-signed test certificate. Its endpoint, `192.0.2.1`, is a documentation address. It is designed for import, encryption/storage and connection-failure tests; it cannot demonstrate successful VPN connectivity.

These files are never embedded in the application HAP. Public verification notes are available in `docs/VALIDATION.md`.
