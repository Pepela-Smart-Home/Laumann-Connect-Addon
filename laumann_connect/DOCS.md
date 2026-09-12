# Laumann Connect

Sicherer Fernzugriff auf Ihre Home Assistant-Installation über Pepela Cloud.

## Einrichtung

1. Fordern Sie bei Laumann Technology einen **Kopplungscode** an (8 Zeichen,
   z. B. `K7QM-3XRA`). Der Code gilt **15 Minuten** und kann nur **einmal**
   verwendet werden.
2. Öffnen Sie die Konfiguration dieses Add-ons und tragen Sie den Code in das
   Feld **Kopplungscode** ein. Groß-/Kleinschreibung und Bindestriche spielen
   keine Rolle.
3. Starten Sie das Add-on. Im Protokoll erscheint bei Erfolg eine Meldung mit
   Ihrer Client-Kennung und Subdomain, und das Kopplungscode-Feld wird
   automatisch geleert.
4. Ab jetzt ist Ihr Home Assistant über den Pepela-Cloud-Tunnel erreichbar.
   Ein Neustart des Add-ons erkennt die bestehende Kopplung automatisch
   wieder — es ist kein erneutes Eintragen eines Codes nötig.

## Optionen

| Option | Beschreibung |
|---|---|
| `pairing_code` | Der Kopplungscode. Nur beim ersten Einrichten nötig. |
| `portal_base_url` | Adresse des Portal-Servers. Nur auf ausdrückliche Anweisung von Laumann Technology ändern. |
| `log_level` | Ausführlichkeit der Protokollausgabe. Standard: `info`. |

## Was bei einem erneuten Start passiert

Wenn bereits erfolgreich gekoppelt wurde, prüft das Add-on das nicht erneut
gegen den Portal-Server — es verwendet die beim ersten Mal gespeicherte
Konfiguration. Das Zertifikat für die verschlüsselte Verbindung wird bei
jedem Start neu bereitgestellt, weil dieser Teil des Containers keinen
Neustart übersteht; das ist normal und erfordert keine Aktion Ihrerseits.

Ein Wert im Feld **Kopplungscode** wird bei einer bereits gekoppelten
Installation immer ignoriert und nicht verbraucht (das Add-on-Protokoll weist
beim nächsten Start darauf hin) — unabhängig davon, ob es sich um den zuletzt
erfolgreich verwendeten Code handelt (das Feld wird nach erfolgreicher
Kopplung normalerweise automatisch geleert, kann in seltenen Fällen aber
stehen bleiben) oder um einen neu eingetragenen. Steht dort noch der alte,
bereits verwendete Code, können Sie das Feld einfach leeren. Nur um einen
**neuen** Code wirksam zu machen, müssen Sie zuvor die Add-on-Daten
zurücksetzen und danach erneut koppeln.

## Wenn etwas schiefgeht

Das Add-on-Protokoll erklärt jeden Fehlerfall in Klartext — z. B. einen
abgelaufenen Code, eine falsche Portal-Adresse, oder einen nicht erreichbaren
Server. Bei zu vielen Fehlversuchen hintereinander wartet das Add-on
automatisch eine vom Server vorgegebene Zeit und versucht es genau ein
weiteres Mal, bevor es aufgibt — ein wiederholtes manuelles Neustarten sperrt
sonst Ihre Internetadresse für 15 Minuten beim Portal-Server.

## Datensicherung

Ihr Tunnel-Zugangsschlüssel liegt in den Add-on-Daten (`/data`) und ist damit
Teil jedes Home-Assistant-Backups, das nach einer erfolgreichen Kopplung
erstellt wird. Das ist beabsichtigt: ohne ihn wäre ein wiederhergestelltes
Backup nutzlos, weil eine neue Kopplung nötig wäre. Ein Backup von **vor**
der letzten Kopplung enthält ohnehin einen bereits ungültigen Schlüssel, weil
jede Kopplung den Schlüssel serverseitig rotiert.

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

