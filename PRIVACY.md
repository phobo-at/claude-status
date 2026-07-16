# Datenschutz

Claude Status verarbeitet nur Daten, die für die lokale Anzeige der Nutzungslimits nötig sind.

## Verarbeitete Daten

- Claude-Code-OAuth-Access-Token: wird nach Nutzerfreigabe einmal pro App-Start aus dem lokalen macOS-Schlüsselbund gelesen, im Arbeitsspeicher für weitere Abrufe wiederverwendet und ausschließlich für die authentifizierte HTTPS-Anfrage an Anthropic verwendet.
- Planart: wird, sofern vorhanden, aus dem Feld `subscriptionType` desselben lokalen Keychain-Payloads abgeleitet.
- Usage-Daten: Prozentwerte, Reset-Zeitpunkte und Abrufzeitpunkt vom Anthropic-Endpoint.
- Lokale Einstellung: ein Boolean merkt sich, ob der Nutzer die Verbindung zur Claude-Code-Anmeldung ausdrücklich aktiviert hat.

## Speicherung

Der Access-Token wird nicht durch Claude Status persistiert. Der lokale Cache enthält ausschließlich Usage-Daten. Im App-Sandbox-Container erhält die Cache-Datei POSIX-Rechte `0600`, ihr Ordner `0700`.

## Übertragung

Die einzige durch die App initiierte Übertragung geht per HTTPS an `api.anthropic.com`. Sie enthält den OAuth-Access-Token im Authorization-Header und keine von Claude Status ergänzten Analyse- oder Gerätekennungen. Es gibt keine eigenen Backend-Systeme und keine Weitergabe an Kollegen oder Drittanbieter durch die App.

Die fehlende Apple-Notarisierung ändert diesen implementierten Datenfluss nicht, nimmt Empfängern aber die Möglichkeit, die Herausgeberidentität über Apple zu prüfen. Deshalb sollten Binärpaket und Prüfsumme nur aus einem vereinbarten vertrauenswürdigen Kanal bezogen werden.

## Löschen

Beim Entfernen der App kann der zugehörige Sandbox-Container unter `~/Library/Containers/io.github.phobo-at.ClaudeStatus` gelöscht werden. Der Claude-Code-Keychain-Eintrag gehört Claude Code und wird von Claude Status weder erstellt noch gelöscht.
