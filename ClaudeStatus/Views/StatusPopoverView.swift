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
            Text("Plan usage limits")
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
            case .reauthorizationRequired:
                reauthorizationView
            case let .failed(message):
                errorView(message)
            default:
                loadingView
            }
        }
    }

    private var connectionView: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Connect to Claude Code", systemImage: "key.fill")
                .font(.system(size: 14, weight: .semibold))

            Text("When you connect, macOS asks for Keychain access. Claude Code renews its login a few times a day, and macOS drops that permission every time it does — so the dialog comes back. Claude Status raises it only at app launch and when you ask for it, never from a background update. The login is kept in memory only, never stored or logged.")
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
                    Text("Connect to Claude Code")
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
                UsageRowView(title: "Current session", window: currentSession, resetStyle: .relative)
            }

            if let weeklyAllModels = snapshot.weeklyAllModels {
                Text("Weekly limits")
                    .font(.system(size: 14, weight: .semibold))
                    .padding(.top, snapshot.currentSession == nil ? 0 : 22)
                    .padding(.bottom, 12)

                UsageRowView(title: "All models", window: weeklyAllModels, resetStyle: .weekly)
            }

            if let weeklySonnet = snapshot.weeklySonnet {
                UsageRowView(title: "Sonnet only", window: weeklySonnet, resetStyle: .weekly)
                    .padding(.top, 16)
            }

            if let weeklyOpus = snapshot.weeklyOpus {
                UsageRowView(title: "Opus only", window: weeklyOpus, resetStyle: .weekly)
                    .padding(.top, 16)
            }

            statusMessage
        }
    }

    @ViewBuilder
    private var statusMessage: some View {
        switch store.state {
        case let .stale(message):
            VStack(alignment: .leading, spacing: 5) {
                compactBanner(message, color: .orange, symbol: "clock.arrow.circlepath")
                retryAfterHint
            }
            .padding(.top, 14)
        case let .authenticationRequired(message):
            VStack(alignment: .leading, spacing: 9) {
                compactBanner(message, color: .orange, symbol: "person.crop.circle.badge.exclamationmark")
                loginCommandButtons
            }
            .padding(.top, 14)
        case let .reauthorizationRequired(message):
            VStack(alignment: .leading, spacing: 9) {
                compactBanner(message, color: .orange, symbol: "key.fill")
                reauthorizeButton
                retryAfterHint
            }
            .padding(.top, 14)
        default:
            EmptyView()
        }
    }

    /// macOS discards the Keychain grant on every Claude Code token rotation, so this is not a
    /// failure the app can retry its way out of — it needs one deliberate click.
    private var reauthorizationView: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Keychain permission needed", systemImage: "key.fill")
                .font(.system(size: 14, weight: .semibold))
            Text("Claude Code renewed its login, and macOS dropped this app’s Keychain permission along with it. The numbers stay frozen until you allow one more read — nothing happens in the background.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            reauthorizeButton
            retryAfterHint
        }
    }

    /// The Keychain dialog takes focus, which closes the popover; reopening it while the dialog
    /// is still unanswered must not show a disabled button with no explanation.
    private var reauthorizeButton: some View {
        Button {
            Task {
                await store.retryAuthentication()
            }
        } label: {
            if store.isRefreshing {
                ProgressView()
                    .controlSize(.small)
            } else {
                Text("Allow Keychain access")
            }
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.small)
        .disabled(!store.canRefresh)
    }

    private var authenticationView: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Claude sign-in required", systemImage: "person.crop.circle.badge.exclamationmark")
                .font(.system(size: 14, weight: .semibold))
            Text("Run the following command in Terminal, then check the connection again.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            loginCommandButtons
        }
    }

    private var loginCommandButtons: some View {
        HStack(spacing: 8) {
            Button(didCopyLoginCommand ? "Copied" : "Copy claude auth login") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString("claude auth login", forType: .string)
                didCopyLoginCommand = true
            }
            .buttonStyle(.bordered)

            Button("Check again") {
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
            Text("Loading usage …")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 12)
    }

    private func errorView(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                compactBanner(message, color: .red, symbol: "exclamationmark.triangle.fill")
                retryAfterHint
            }
            Button("Try again") {
                Task {
                    await store.retryAuthentication()
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(store.isRefreshing)
        }
    }

    /// Anthropic's cool-down blocks the refresh button too, so name the time it lifts —
    /// a greyed-out button with no explanation reads as a broken app.
    @ViewBuilder
    private var retryAfterHint: some View {
        if let retryAfterUntil = store.activeRetryAfter {
            Text(UsageFormatting.retryAfterText(until: retryAfterUntil))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .padding(.leading, 22)
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
                    if store.isStale || store.isWaitingForUser {
                        Circle()
                            .fill(.orange)
                            .frame(width: 6, height: 6)
                    }
                    Text(UsageFormatting.updatedText(fetchedAt: fetchedAt))
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            } else {
                Text("Not updated yet")
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
            .help("Refresh usage")

            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Image(systemName: "power")
            }
            .buttonStyle(.plain)
            .help("Quit Claude Status")
        }
        .padding(.vertical, 11)
    }
}
