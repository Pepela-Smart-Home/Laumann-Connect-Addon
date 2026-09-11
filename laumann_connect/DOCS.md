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

## Platzhalter-Branding

Symbol und Logo dieses Add-ons sind derzeit generische Platzhalter. Das
Laumann-Technology-Branding folgt in einer Folgewelle.
