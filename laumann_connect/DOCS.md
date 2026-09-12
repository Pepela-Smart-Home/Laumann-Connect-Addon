# Laumann Connect

Secure remote access to your Home Assistant installation via Pepela Cloud.

## Setup

1. Request a **pairing code** from Laumann Technology (8 characters, e.g.
   `K7QM-3XRA`). The code is valid for **15 minutes** and can only be used
   **once**.
2. Open this add-on's configuration and enter the code in the **Pairing
   code** field. Case and dashes don't matter.
3. Start the add-on. On success, the log shows a message with your client ID
   and subdomain, and the pairing-code field is cleared automatically.
4. Your Home Assistant is now reachable via the Pepela Cloud tunnel. A
   restart of the add-on recognizes the existing pairing automatically — no
   need to enter a code again.

## Options

| Option | Description |
|---|---|
| `pairing_code` | The pairing code. Only needed for the initial setup. |
| `portal_base_url` | Address of the portal server. Only change this if Laumann Technology explicitly asks you to. |
| `log_level` | Verbosity of the log output. Default: `info`. |

## What happens on a restart

Once successfully paired, the add-on does not check again against the
portal server — it reuses the configuration stored the first time. The
certificate for the encrypted connection is re-provisioned on every start,
because that part of the container does not survive a restart; this is
normal and requires no action on your part.

A value in the **Pairing code** field is always ignored and never consumed
on an already-paired installation (the add-on log points this out on the
next start) — regardless of whether it's the code that was last used
successfully (the field is normally cleared automatically after a
successful pairing, but can in rare cases remain set) or a newly entered
one. If the old, already-used code is still there, you can simply clear the
field. To make a **new** code take effect, you must first reset the
add-on's data and then pair again.

## If something goes wrong

The add-on log explains every failure case in plain language — e.g. an
expired code, a wrong portal address, or an unreachable server. After too
many failed attempts in a row, the add-on automatically waits for a
server-specified duration and tries exactly one more time before giving
up — repeatedly restarting manually instead would otherwise lock your
internet address out at the portal server for 15 minutes.

## Backups

Your tunnel access key lives in the add-on's data (`/data`) and is
therefore part of every Home Assistant backup created after a successful
pairing. This is intentional: without it, a restored backup would be
useless, since a new pairing would be required. A backup from **before**
the last pairing already contains a key that is invalid anyway, because
each pairing rotates the key server-side.

## Onboarding guide for Laumann developers

The section above is the customer-facing quick start, assuming a pairing code has
already been issued. This section walks through the complete flow end to end —
relevant for Laumann's own developers, who are the first users of this add-on before
any external customer is onboarded (decision 2026-09-10, see the vault's tunnel
architecture note).

### Part A — Create a tunnel client (Platform Admin)

1. Open `https://platform-admin.laumanntechnology.ge` and log in.
2. Navigate to **"Pepela Cloud tunnel clients"**.
3. Under **"Create a new tunnel client"**, fill in:
   - **Client ID** — e.g. `laumann-dev-<name>`
   - **Subdomain** — chosen randomly, not guessable (do not derive it from the
     developer's name)
   - **Label** — e.g. `Laumann developer <name>`
4. Click **"Create tunnel client"**. A reveal panel opens with:
   - A **QR code for the Companion App** (shown immediately, above the fold)
   - Under **"Show pairing code / secret / frpc.toml"** (collapsed by default): the
     **pairing code** (8 characters, e.g. `K7QM-3XRA`) — **valid for 15 minutes,
     single use**
5. **Copy the pairing code now** — it cannot be shown again after clicking "Done"
   (rotating the secret would be needed to issue a fresh one).

### Part B — Set up the tunnel add-on on the developer's own HA instance

1. In Home Assistant: **Settings → Add-ons → Add-on Store → ⋮ → Repositories**.
2. Add the repository URL: `https://github.com/Pepela-Smart-Home/Laumann-Connect-Addon`.
3. Install the **"Laumann Connect"** add-on (v0.2.0).
4. In the add-on's configuration, enter the **pairing code** from Part A, step 5
   (case and hyphens do not matter).
5. **Start** the add-on.
6. Check the log — on success it shows a message with the client ID and subdomain,
   and the pairing-code field is cleared automatically.
7. The HA instance is now reachable at `https://<subdomain>.laumannconnect.ge`. A
   restart of the add-on recognizes the existing pairing automatically.

### Part C — Connect the Companion App (Android/iOS)

1. Install the app (Play Store/App Store — still private, distribute a debug build
   directly if needed).
2. During setup, tap **"Scan QR code"** on the server-discovery screen and scan the
   QR code from Part A, step 4.
3. The app confirms the invitation and connects automatically to
   `https://<subdomain>.laumannconnect.ge`.
4. **Important**: immediately also set the **internal URL** (the local HA address)
   and the **home Wi-Fi SSID** in settings — do not rely on automatic discovery for
   these (a known pitfall).

### Verification

- `curl -4 https://<subdomain>.laumannconnect.ge/` → `200`/`302`
- In the Platform Admin UI: **"Check reachability"** next to the tunnel client shows
  `REACHABLE`, not one of the error classifications.
- Test over a **real mobile network**, not just Wi-Fi.

