# Changelog

## Unreleased

- Fix: the generated `frpc.toml` now sets `loginFailExit = false`. frpc's own
  default (`true`) made a single failed login attempt after a restart (e.g.
  the customer's router/DNS not yet back up after a reboot) exit the process,
  which `frpc/finish` then turned into a full add-on halt — precisely on the
  already-paired, zero-network-calls restart path with no watchdog to bring
  it back. frpc now retries the login instead of exiting.
- Fix: the CA certificate write during pairing now goes through the same
  write-to-temp-then-`mv` discipline as `frpc.toml` (`lc::write_ca_pem`),
  with its own customer-facing error message instead of a raw bash error on
  failure. The already-paired startup check (`lc::ca_pem_looks_valid`) now
  verifies the stored CA actually contains a PEM certificate terminator
  instead of only checking that the file is non-empty, so a truncated CA
  from an interrupted write is rejected with a clear message up front
  instead of failing later at frpc's TLS handshake.

## 0.1.0

- First implemented version. Redeems a pairing code against the Portal-Server
  pairing endpoint, adapts the returned `frpc.toml` for the add-on's own
  container networking, and runs `frpc` (pinned to 0.61.1) as an s6-rc
  longrun service.
- Pairing is idempotent across restarts: once paired, the add-on skips the
  network round-trip and reuses the stored configuration, re-provisioning
  only the CA certificate (which does not survive a container restart).
- The pairing code field is cleared automatically after a successful
  pairing.
