# Security Policy

## Datenfluss

1. Erst nach einem expliziten Klick auf „Mit Claude Code verbinden“ fragt die App den lokalen macOS-Schlüsselbund nach genau einem Eintrag ab: Service `Claude Code-credentials`, Account = aktueller macOS-Benutzername.
2. Aus dem JSON wird ausschließlich `claudeAiOauth.accessToken` sowie optional `subscriptionType` decodiert. Unbekannte oder ältere Strukturen werden abgelehnt und nicht rekursiv durchsucht.
3. Der Access-Token wird einmal pro App-Prozess gelesen, im Arbeitsspeicher für die regelmäßigen Abrufe wiederverwendet und als `Authorization: Bearer …` verwendet. Nach einem Authentifizierungsfehler wird die Referenz verworfen; automatische Abrufe lesen den Schlüsselbund nicht erneut.
4. Die einzige im Produktionscode erlaubte Zieladresse ist `https://api.anthropic.com/api/oauth/usage`. Weiterleitungen werden nicht verfolgt.
5. Gespeichert werden ausschließlich Prozentwerte, Reset-Zeitpunkte und der Abrufzeitpunkt. Zugangsdaten sind kein Bestandteil des Cache-Modells.

Der Access-Token verlässt das Gerät notwendigerweise in der TLS-geschützten Anfrage an Anthropic. Ohne diese Authentifizierung kann der persönliche Usage-Endpoint nicht abgefragt werden. Er wird niemals an Kollegen, dieses Repository, einen eigenen Server oder einen Drittanbieter übertragen.

## Plattformschutz

- App Sandbox: aktiv
- Sandbox-Entitlements: ausschließlich `com.apple.security.app-sandbox` und `com.apple.security.network.client`
- Hardened Runtime: aktiv, ohne Runtime-Ausnahmen
- App Transport Security: Standardregeln, keine Ausnahmen
- Netzwerk: ephemere `URLSession`, keine Cookies, kein URL-Cache, TLS 1.2 als Mindestversion
- Interner Build: ad-hoc-signiert, eindeutig als `UNNOTARIZED` gekennzeichnet; keine durch Apple bestätigte Herausgeberidentität und keine Apple-Notarisierung
- Optionaler offizieller Release-Weg: Developer ID, sicherer Timestamp, Apple-Notarisierung, Stapling und Gatekeeper-Prüfung
- Architektur: arm64; keine Intel-Binaries

Die Keychain-Zugriffsentscheidung und einen möglichen Freigabedialog kontrolliert macOS. Die App schreibt und verändert keinen Claude-Code-Keychain-Eintrag.

## Bewusst ausgeschlossene Fähigkeiten

- keine Shell- oder Prozessausführung
- keine Apple Events oder Automation
- kein Lesen beliebiger Dateien im Home-Verzeichnis
- kein Import oder Export von Credentials
- keine eigene Login-Maske
- keine Telemetrie, Crash-Uploads oder Analytics
- keine Update-Komponente
- keine Drittanbieter-Abhängigkeiten

## Bedrohungsgrenzen

Die Architektur schützt nicht gegen ein bereits kompromittiertes Benutzerkonto, Betriebssystem oder Claude-Code-Keychain-Item. Systemweite Proxies, installierte Root-Zertifikate und Endpoint-Security-Produkte unterliegen der Kontrolle des jeweiligen Macs beziehungsweise der Organisation. Der verwendete Anthropic-Endpoint ist undokumentiert; eine Änderung kann die App funktionsunfähig machen und muss vor einem Update erneut auditiert werden.

Eine absolute Garantie, dass ein Geheimnis niemals im Prozessspeicher erscheint, ist bei Bearer-Authentifizierung nicht möglich. Die App minimiert Lebensdauer und Persistenz, besitzt aber keine API, mit der Swift-Strings oder interne `URLSession`-Puffer zuverlässig überschrieben werden können.

## Distributionsmodell

`Scripts/build-shareable.sh` erzeugt bewusst einen ad-hoc-signierten internen Build unter `dist/internal/`. ZIP und Prüfsummendatei tragen dauerhaft den Zusatz `UNNOTARIZED`. Empfänger müssen mit einer Gatekeeper-Warnung rechnen und können die Herausgeberidentität nicht über Apple verifizieren. Die SHA-256-Prüfsumme sollte über einen getrennten, vertrauenswürdigen Kanal verglichen werden; die stärkste Prüfung bleibt ein eigener Build aus dem auditierten Quellcode.

Das Projekt empfiehlt weder das globale Abschalten von Gatekeeper noch das pauschale Entfernen von Quarantäneattributen. Wenn organisatorische Richtlinien eine Developer-ID-Signatur verlangen, darf der unnotarisierte Build nicht eingesetzt werden.

`Scripts/build-notarized.sh` bleibt als optionaler, strenger Release-Weg erhalten und bricht ohne Developer-ID-Identität oder Notarisierungsprofil ab.

## Sicherheitslücken melden

Bitte keine Tokens, Keychain-Auszüge oder personenbezogenen Daten in öffentliche Issues kopieren. Für ein öffentliches GitHub-Repository sollte die Funktion „Private vulnerability reporting“ aktiviert und für vertrauliche Meldungen verwendet werden.

## Referenzen

- [Apple: App Sandbox](https://developer.apple.com/documentation/security/app-sandbox)
- [Apple: Keychain Services](https://developer.apple.com/documentation/security/keychain-services)
- [Apple: Sichere Netzwerkverbindungen mit ATS](https://developer.apple.com/documentation/security/preventing-insecure-network-connections)
- [Apple: macOS-Software notarizieren](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)
