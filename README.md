# Claude Status

Eine kleine native macOS-Menüleisten-App, die die persönlichen Claude-/Claude-Code-Nutzungsfenster anzeigt. Die App ist ausschließlich für Apple Silicon und macOS 14 oder neuer gebaut.

Öffentlicher Bundle-Identifier: `io.github.phobo-at.ClaudeStatus`.

> [!IMPORTANT]
> Claude Status ist ein unabhängiges, inoffizielles Projekt und steht nicht in Verbindung mit Anthropic. Die bereitgestellten internen Builds sind bewusst **nicht mit einer Apple Developer ID signiert und nicht notarisiert**. macOS kann ihre Herausgeberidentität daher nicht bestätigen und zeigt beim ersten Start eine Gatekeeper-Warnung. Der Quellcode, die Sandbox und der Datenfluss bleiben davon getrennte Sicherheitsaspekte.

## Sicherheitsmodell

- Jeder Nutzer verwendet ausschließlich seinen eigenen, bereits vorhandenen Claude-Code-Login im lokalen macOS-Schlüsselbund.
- Die App liest exakt den generischen Passwort-Eintrag `Claude Code-credentials` für den aktuellen macOS-Benutzernamen. Es gibt keine Suche nach ähnlichen Einträgen und keinen Legacy-Fallback.
- Der Access-Token wird einmal pro App-Start gelesen, nur im Arbeitsspeicher wiederverwendet und nicht gespeichert, geloggt, in die Zwischenablage geschrieben oder an andere Nutzer übertragen. Nach einem `401` stoppt der automatische Abruf; erst eine explizite Nutzeraktion liest den Schlüsselbund erneut.
- Der Token wird ausschließlich als Bearer-Token per HTTPS an `https://api.anthropic.com/api/oauth/usage` gesendet. Das ist technisch notwendig, um die persönliche Nutzung abzurufen.
- HTTP-Weiterleitungen werden abgelehnt. Cookies, URL-Cache und persistente Netzwerkdaten sind deaktiviert.
- Die App startet keine Shell und kein anderes Programm. Nach einem abgelaufenen Login muss der Nutzer `claude auth login` selbst ausführen.
- App Sandbox und Hardened Runtime sind aktiv. Die Sandbox besitzt nur das Entitlement für ausgehende Netzwerkverbindungen.
- Lokal gespeichert wird lediglich der letzte Usage-Snapshot mit Dateirechten `0600`; der Ordner erhält `0700`.
- Keine Analytics, Telemetrie, Werbung, Drittanbieter-SDKs oder externen Swift-Pakete.

Details und Grenzen stehen in [SECURITY.md](SECURITY.md) und [PRIVACY.md](PRIVACY.md).

## Was „unnotarisiert“ konkret bedeutet

Der interne Build ist ad hoc signiert. Dadurch kann macOS erkennen, ob das App-Bundle nach dem Signieren verändert wurde, und die Sandbox-Entitlements anwenden. Die Signatur beweist jedoch **nicht**, wer die App veröffentlicht hat. Außerdem wurde die Binärdatei nicht durch Apples Notarisierungsdienst auf bekannte Schadsoftware und Signaturfehler geprüft.

Empfänger müssen deshalb selbst Vertrauen herstellen, idealerweise durch mindestens eine dieser Methoden:

1. den Quellcode prüfen und die App selbst bauen;
2. die veröffentlichte SHA-256-Prüfsumme über einen getrennten, vertrauenswürdigen Kanal vergleichen;
3. das Paket nur aus dem vereinbarten internen Kanal oder dem offiziellen Repository beziehen.

Die App darf nicht verteilt werden, wenn eure IT-Richtlinien ausschließlich Developer-ID-signierte oder notarisierten Anwendungen zulassen.

## Voraussetzungen

- Apple-Silicon-Mac mit macOS 14 oder neuer
- Claude Code mit einem aktiven Login (`claude auth login`)
- Zum Selbstbauen: Xcode mit Swift 6
- Optional: [XcodeGen](https://github.com/yonaskolb/XcodeGen), wenn `project.yml` geändert wird

## Internes Paket bauen

```sh
./Scripts/build-shareable.sh
```

Das Skript führt zuerst die statischen Sicherheitsregeln aus, baut ausschließlich `arm64`, signiert ad hoc und erzeugt:

- `dist/internal/ClaudeStatus.app`
- `dist/internal/ClaudeStatus-Apple-Silicon-UNNOTARIZED.zip`
- `dist/internal/ClaudeStatus-Apple-Silicon-UNNOTARIZED.zip.sha256`

Die Bezeichnung `UNNOTARIZED` ist absichtlich Bestandteil des Dateinamens und darf für die Weitergabe nicht entfernt werden.

## Installation durch Kollegen

ZIP und Prüfsummendatei im selben Ordner ablegen und zuerst prüfen:

```sh
shasum -a 256 -c ClaudeStatus-Apple-Silicon-UNNOTARIZED.zip.sha256
```

Anschließend:

1. ZIP entpacken und `ClaudeStatus.app` nach `/Applications` ziehen.
2. Die App im Finder mit Rechtsklick → **Öffnen** starten.
3. Falls macOS weiterhin blockiert: **Systemeinstellungen → Datenschutz & Sicherheit → Dennoch öffnen** verwenden.
4. Im Menüleisten-Popover auf **Mit Claude Code verbinden** klicken.
5. Den macOS-Schlüsselbunddialog sorgfältig prüfen und den Zugriff erlauben. Bei unverändertem, verifiziertem Build kann „Immer erlauben“ gewählt werden.

Nicht empfohlen werden das globale Abschalten von Gatekeeper oder Befehle zum pauschalen Entfernen von Quarantäneattributen. Die Warnung ist bei diesem Distributionsmodell erwartetes Sicherheitsverhalten von macOS.

Weil die App keine stabile Developer-ID-Identität besitzt, kann macOS nach einem App-Update erneut nach dem Schlüsselbundzugriff fragen. Während eines laufenden App-Prozesses wird der Keychain-Eintrag nur einmal gelesen.

## Lokal entwickeln und testen

Das eingecheckte Xcode-Projekt direkt öffnen:

```sh
open ClaudeStatus.xcodeproj
```

Lokaler Build mit vorhandener Apple-Development-Identität, andernfalls ad hoc:

```sh
./Scripts/build-local.sh
```

Tests:

```sh
xcodebuild \
  -project ClaudeStatus.xcodeproj \
  -scheme ClaudeStatus \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /tmp/ClaudeStatusDerivedData \
  CODE_SIGNING_ALLOWED=NO \
  test
```

Statische Sicherheitsregeln:

```sh
./Scripts/security-check.sh
```

## Optional: notarisiertes Paket

Falls ein Fork oder ein späterer Maintainer eine Apple Developer ID besitzt, bleibt der notarisierten Release-Weg erhalten:

```sh
xcrun notarytool store-credentials "ClaudeStatus-Notary"

DEVELOPER_ID_APPLICATION="Developer ID Application: ORGANISATION (TEAMID)" \
NOTARY_PROFILE="ClaudeStatus-Notary" \
./Scripts/build-notarized.sh
```

Das Skript veröffentlicht nur nach erfolgreicher Signatur, Notarisierung, Stapling- und Gatekeeper-Prüfung ein Paket unter `dist/release/`.

## GitHub-Veröffentlichung

`dist/`, `.build/`, Xcode-Benutzerdaten, Zertifikate und Umgebungsdateien werden ignoriert. Vor einem Push sollten Tests und `./Scripts/security-check.sh` erfolgreich sein. GitHub Actions wiederholt die Prüfungen auf einem arm64-macOS-Runner; die Checkout-Action ist auf einen festen Commit gepinnt und persistiert keine Git-Credentials.

Für Releases sollten immer gemeinsam veröffentlicht werden:

- das eindeutig als `UNNOTARIZED` bezeichnete ZIP;
- die dazugehörige `.sha256`-Datei;
- ein Hinweis auf diese Installations- und Sicherheitsinformationen;
- der zugehörige Quellcode-Stand beziehungsweise Git-Tag.

Im GitHub-Repository sollte „Private vulnerability reporting“ aktiviert werden. Keine Tokens, Keychain-Auszüge oder personenbezogenen Daten in öffentliche Issues kopieren.

Aktuell enthält das Repository keine `LICENSE`. Damit ist der Code öffentlich einsehbar, aber nicht automatisch Open Source und Dritte erhalten keine pauschale Erlaubnis zur Nutzung oder Weiterverbreitung. Vor einer echten Open-Source-Veröffentlichung muss der Eigentümer bewusst eine Lizenz auswählen.

## Technische und organisatorische Grenzen

- Die App verwendet den von Claude Code genutzten Endpoint `/api/oauth/usage`. Er ist keine dokumentierte öffentliche Anthropic-API, kann sich ändern oder künftig gesperrt werden.
- Eine ad-hoc-signierte App besitzt keine durch Apple bestätigte Herausgeberidentität und keine Apple-Notarisierung.
- Der Access-Token muss für den authentifizierten Abruf per TLS an Anthropic gesendet werden; „der Token verlässt niemals das Gerät“ wäre deshalb falsch.
- Die Architektur schützt nicht gegen einen bereits kompromittierten Mac, Benutzeraccount, System-Proxy oder Claude-Code-Keychain-Eintrag.
- Interne Verteilung sollte mit der zuständigen IT-/Security-Richtlinie abgestimmt werden.
