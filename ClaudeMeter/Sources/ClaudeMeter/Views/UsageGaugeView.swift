import SwiftUI

struct UsageGaugeView: View {
    let title: String
    let percent: Double
    let resetInfo: String?

    private var color: Color {
        if percent >= 95 { return .red }
        if percent >= 80 { return .orange }
        return .green
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(String(format: "%.1f%%", percent))
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(color)
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color(nsColor: .separatorColor))
                        .frame(height: 8)
                    RoundedRectangle(cornerRadius: 4)
                        .fill(color)
                        .frame(width: geo.size.width * min(percent / 100, 1.0), height: 8)
                        .animation(.easeInOut(duration: 0.4), value: percent)
                }
            }
            .frame(height: 8)

            if let info = resetInfo {
                Text(info)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
        }
    }
}
