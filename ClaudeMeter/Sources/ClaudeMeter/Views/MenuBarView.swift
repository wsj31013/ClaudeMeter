import SwiftUI

struct MenuBarView: View {
    @ObservedObject var service = UsageService.shared

    private var updatedText: String {
        guard let d = service.lastUpdated else { return "아직 로드 안됨" }
        let diff = Int(-d.timeIntervalSinceNow)
        if diff < 60 { return "방금 업데이트" }
        return "\(diff / 60)분 전 업데이트"
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: "bolt.fill")
                    .foregroundStyle(.yellow)
                Text("Claude Meter")
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                Button {
                    Task { await UsageService.shared.fetchUsage() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12))
                        .rotationEffect(.degrees(service.isLoading ? 360 : 0))
                        .animation(
                            service.isLoading
                                ? .linear(duration: 0.8).repeatForever(autoreverses: false)
                                : .default,
                            value: service.isLoading
                        )
                }
                .buttonStyle(.plain)
                .disabled(service.isLoading)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            if let data = service.usageData {
                VStack(spacing: 14) {
                    UsageGaugeView(
                        title: "5시간 사용량",
                        percent: data.fiveHour.percent,
                        resetInfo: data.fiveHour.timeUntilReset
                    )
                    UsageGaugeView(
                        title: "7일 사용량",
                        percent: data.sevenDay.percent,
                        resetInfo: data.sevenDay.timeUntilReset
                    )
                }
                .padding(16)
            } else if let err = service.error {
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.title2)
                        .foregroundStyle(.orange)
                    Text(err.localizedDescription)
                        .font(.system(size: 12))
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                }
                .padding(16)
            } else {
                ProgressView()
                    .padding(16)
            }

            Divider()

            // Footer
            HStack {
                Text(updatedText)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                Spacer()
                Button("종료") {
                    NSApplication.shared.terminate(nil)
                }
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .frame(width: 280)
    }
}
