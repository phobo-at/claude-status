import SwiftUI

struct UsageRowView: View {
    let title: LocalizedStringKey
    let window: LimitWindow
    let resetStyle: ResetStyle

    enum ResetStyle {
        case relative
        case weekly
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 14, weight: .medium))
                Text(resetText)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 10) {
                ProgressView(value: window.utilization, total: 100)
                    .progressViewStyle(.linear)
                    .tint(progressColor)
                    .accessibilityLabel(title)
                    .accessibilityValue("\(UsageFormatting.percentage(window.utilization)) used")

                Text("\(UsageFormatting.percentage(window.utilization)) used")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .frame(width: 92, alignment: .trailing)
            }
        }
    }

    private var resetText: String {
        switch resetStyle {
        case .relative:
            UsageFormatting.sessionResetText(resetsAt: window.resetsAt)
        case .weekly:
            UsageFormatting.weeklyResetText(resetsAt: window.resetsAt)
        }
    }

    private var progressColor: Color {
        switch UsageWarningLevel(utilization: window.utilization) {
        case .normal:
            .blue
        case .elevated:
            .orange
        case .critical:
            .red
        }
    }
}

