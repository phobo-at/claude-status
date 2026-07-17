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
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: String {
        if let utilization = store.currentUtilization {
            return String(localized: "Claude usage, current session: \(UsageFormatting.percentage(utilization)) used")
        }
        return String(localized: "Claude usage unavailable")
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
