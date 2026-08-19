import SwiftUI

struct MenuBarLabel: View {
    @ObservedObject var store: UsageStore

    var body: some View {
        HStack(spacing: 4) {
            MenuBarProgressRing(utilization: store.currentUtilization)
            Text(store.currentUtilization.map(UsageFormatting.percentage) ?? "—")
                .monospacedDigit()
        }
        .fixedSize()
        // Frozen numbers must not read as live ones. Dimming is the only signal the menu bar
        // has room for; the popover carries the explanation and the button.
        .opacity(store.isWaitingForUser ? 0.55 : 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: String {
        guard let utilization = store.currentUtilization else {
            return String(localized: "Claude usage unavailable")
        }
        let percentage = UsageFormatting.percentage(utilization)
        if store.needsReauthorization {
            return String(localized: "Claude usage, current session: \(percentage) used, Keychain permission needed")
        }
        if store.isWaitingForUser {
            return String(localized: "Claude usage, current session: \(percentage) used, Claude sign-in required")
        }
        return String(localized: "Claude usage, current session: \(percentage) used")
    }
}

private struct MenuBarProgressRing: View {
    let utilization: Double?

    var body: some View {
        ZStack {
            Circle()
                .stroke(.primary.opacity(0.22), lineWidth: 2)

            if let utilization {
                Circle()
                    .trim(from: 0, to: utilization / 100)
                    .stroke(.primary, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            } else {
                Circle()
                    .trim(from: 0, to: 0.18)
                    .stroke(.primary.opacity(0.55), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
        }
        .frame(width: 13, height: 13)
    }
}
