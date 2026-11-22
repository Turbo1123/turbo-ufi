import ActivityKit
import SwiftUI
import WidgetKit

@main
struct TurboWiFiWidget: Widget {
    private let background = Color(red: 0.035, green: 0.22, blue: 0.16)
    private let highlight = Color(red: 0.89, green: 0.95, blue: 0.72)

    var body: some WidgetConfiguration {
        ActivityConfiguration(for: TurboWiFiActivity.self) { context in
            HStack(spacing: 12) {
                signal(stale: context.isStale)
                    .font(.title2.weight(.semibold))
                    .frame(width: 40, height: 40)
                VStack(alignment: .leading, spacing: 4) {
                    Text(context.isStale ? "Turbo Wi-Fi 待复核" : "已连接 Turbo Wi-Fi")
                        .font(.headline)
                    if context.isStale {
                        Text("上次确认 \(context.state.confirmedAt, style: .time) · 轻点复核")
                            .font(.caption).foregroundStyle(.white.opacity(0.78))
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(14)
            .foregroundStyle(.white)
            .activityBackgroundTint(background)
            .activitySystemActionForegroundColor(.white)
            .accessibilityElement(children: .combine)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    signal(stale: context.isStale).font(.title2)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text("Turbo Wi-Fi").font(.headline)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text(context.isStale ? "上次连接已过时 · 轻点复核" : "已连接随身热点")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            } compactLeading: {
                signal(stale: context.isStale)
            } compactTrailing: {
                Text(context.isStale ? "待复核" : "Turbo")
                    .font(.caption.weight(.semibold))
                    .padding(.trailing, 2)
                    .accessibilityLabel(context.isStale ? "Turbo Wi-Fi 待复核" : "已连接 Turbo Wi-Fi")
            } minimal: {
                signal(stale: context.isStale)
                    .accessibilityLabel(context.isStale ? "Turbo Wi-Fi 待复核" : "已连接 Turbo Wi-Fi")
            }
        }
    }

    private func signal(stale: Bool) -> some View {
        Image(systemName: stale ? "wifi.exclamationmark" : "wifi")
            .foregroundStyle(stale ? Color.yellow : highlight)
            .accessibilityHidden(true)
    }
}
