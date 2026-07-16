import AppKit
import SwiftUI

struct StatusPopoverView: View {
    @ObservedObject var store: UsageStore
    @State private var didCopyLoginCommand = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            Divider()
                .padding(.vertical, 14)

            content

            Divider()
                .padding(.top, 16)

            footer
        }
        .padding(.horizontal, 18)
        .padding(.top, 16)
        .frame(width: 340)
        .background(.background)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Text("Plan-Nutzungslimits")
                .font(.system(size: 16, weight: .semibold))
            if let planName = store.planName {
                Text(planName)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var content: some View {
        if !store.isConnectionAuthorized {
            switch store.state {
            case .authenticationRequired:
                authenticationView
            case let .failed(message):
                errorView(message)
            default:
                connectionView
            }
        } else if let snapshot = store.snapshot {
            limitsView(snapshot)
        } else {
            switch store.state {
            case .authenticationRequired:
                authenticationView
            case let .failed(message):
                errorView(message)
            default:
                loadingView
            }
        }
    }

    private var connectionView: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Mit Claude Code verbinden", systemImage: "key.fill")
                .font(.system(size: 14, weight: .semibold))

            Text("Claude Status liest nach deiner Freigabe den vorhandenen Claude-Code-Login einmal pro App-Start aus dem macOS-Schlüsselbund. Danach bleibt er nur im Arbeitsspeicher und wird weder gespeichert noch protokolliert.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                Task {
                    await store.connect()
                }
            } label: {
                if store.isRefreshing {
                    ProgressView()
                        .controlSize(.small)
                        .frame(maxWidth: .infinity)
                } else {
                    Text("Mit Claude Code verbinden")
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(store.isRefreshing)
        }
    }

    private func limitsView(_ snapshot: UsageSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if let currentSession = snapshot.currentSession {
                UsageRowView(title: "Aktuelle Sitzung", window: currentSession, resetStyle: .relative)
            }

            if let weeklyAllModels = snapshot.weeklyAllModels {
                Text("Wöchentliche Limits")
                    .font(.system(size: 14, weight: .semibold))
                    .padding(.top, snapshot.currentSession == nil ? 0 : 22)
                    .padding(.bottom, 12)

                UsageRowView(title: "Alle Modelle", window: weeklyAllModels, resetStyle: .weekly)
            }

            if let weeklySonnet = snapshot.weeklySonnet {
                UsageRowView(title: "Nur Sonnet", window: weeklySonnet, resetStyle: .weekly)
                    .padding(.top, 16)
            }

            if let weeklyOpus = snapshot.weeklyOpus {
                UsageRowView(title: "Nur Opus", window: weeklyOpus, resetStyle: .weekly)
                    .padding(.top, 16)
            }

            statusMessage
        }
    }

    @ViewBuilder
    private var statusMessage: some View {
        switch store.state {
        case let .stale(message):
            compactBanner(message, color: .orange, symbol: "clock.arrow.circlepath")
                .padding(.top, 14)
        case let .authenticationRequired(message):
            VStack(alignment: .leading, spacing: 9) {
                compactBanner(message, color: .orange, symbol: "person.crop.circle.badge.exclamationmark")
                loginCommandButtons
            }
            .padding(.top, 14)
        default:
            EmptyView()
        }
    }

    private var authenticationView: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Claude-Anmeldung erforderlich", systemImage: "person.crop.circle.badge.exclamationmark")
                .font(.system(size: 14, weight: .semibold))
            Text("Führe den folgenden Befehl in Terminal aus und prüfe die Verbindung danach erneut.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            loginCommandButtons
        }
    }

    private var loginCommandButtons: some View {
        HStack(spacing: 8) {
            Button(didCopyLoginCommand ? "Kopiert" : "claude auth login kopieren") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString("claude auth login", forType: .string)
                didCopyLoginCommand = true
            }
            .buttonStyle(.bordered)

            Button("Erneut prüfen") {
                Task {
                    await store.retryAuthentication()
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(store.isRefreshing)
        }
        .controlSize(.small)
    }

    private var loadingView: some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
            Text("Nutzung wird geladen …")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 12)
    }

    private func errorView(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            compactBanner(message, color: .red, symbol: "exclamationmark.triangle.fill")
            Button("Erneut versuchen") {
                Task {
                    await store.retryAuthentication()
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(store.isRefreshing)
        }
    }

    private func compactBanner(_ message: String, color: Color, symbol: String) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: symbol)
                .foregroundStyle(color)
            Text(message)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if let fetchedAt = store.snapshot?.fetchedAt {
                HStack(spacing: 5) {
                    if store.isStale {
                        Circle()
                            .fill(.orange)
                            .frame(width: 6, height: 6)
                    }
                    Text(UsageFormatting.updatedText(fetchedAt: fetchedAt))
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            } else {
                Text("Noch nicht aktualisiert")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                Task {
                    await store.manualRefresh()
                }
            } label: {
                if store.isRefreshing {
                    ProgressView()
                        .controlSize(.mini)
                } else {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .buttonStyle(.plain)
            .disabled(!store.canRefresh)
            .help("Nutzung aktualisieren")

            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Image(systemName: "power")
            }
            .buttonStyle(.plain)
            .help("Claude Status beenden")
        }
        .padding(.vertical, 11)
    }
}
