import SwiftUI

enum Palette {
    static let paper = Color(red: 0.963, green: 0.963, blue: 0.93)
    static let white = Color(red: 0.997, green: 0.996, blue: 0.98)
    static let ink = Color(red: 0.047, green: 0.14, blue: 0.108)
    static let muted = Color(red: 0.32, green: 0.37, blue: 0.33)
    static let green = Color(red: 0.063, green: 0.37, blue: 0.26)
    static let deep = Color(red: 0.035, green: 0.22, blue: 0.16)
    static let lime = Color(red: 0.89, green: 0.95, blue: 0.72)
    static let border = Color(red: 0.83, green: 0.84, blue: 0.79)
    static let warning = Color(red: 0.57, green: 0.26, blue: 0.16)
    static let corner: CGFloat = 18
}

struct StatusChip: View {
    let text: String
    var filled = true
    var dot = false

    var body: some View {
        HStack(spacing: 5) {
            if dot { Circle().fill(Palette.green).frame(width: 6, height: 6) }
            Text(text).font(.system(.caption, design: .monospaced).weight(.semibold))
        }
        .foregroundStyle(filled ? Palette.green : Palette.muted)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(filled ? Palette.lime : Palette.border.opacity(0.35), in: Capsule())
    }
}

struct Card<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.white, in: RoundedRectangle(cornerRadius: Palette.corner))
            .overlay { RoundedRectangle(cornerRadius: Palette.corner).strokeBorder(Palette.border, lineWidth: 1) }
    }
}

struct RadioBackdrop: View {
    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            ZStack {
                LinearGradient(colors: [Palette.deep, Color(red: 0.07, green: 0.31, blue: 0.22)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                Canvas { context, canvas in
                    for index in 0..<7 {
                        let radius = CGFloat(30 + index * 22)
                        let point = CGPoint(x: canvas.width - 37, y: canvas.height - 23)
                        context.stroke(Path(ellipseIn: CGRect(x: point.x - radius, y: point.y - radius,
                                                           width: radius * 2, height: radius * 2)),
                                       with: .color(Palette.lime.opacity(0.13 + Double(6 - index) * 0.02)), lineWidth: 0.6)
                    }
                }
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.system(size: 29, weight: .light))
                    .foregroundStyle(Palette.lime.opacity(0.62))
                    .position(x: size.width - 37, y: size.height - 24)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

struct RadioCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .foregroundStyle(.white)
            .background { RadioBackdrop() }
            .clipShape(RoundedRectangle(cornerRadius: 22))
    }
}

struct PageHeading: View {
    let title: String
    var detail: String?
    var status: String?
    var live = true

    var body: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.system(.largeTitle, weight: .heavy))
                    .tracking(-1.3)
                    .accessibilityAddTraits(.isHeader)
                if let detail {
                    Text(detail).font(.subheadline).foregroundStyle(Palette.muted)
                }
            }
            Spacer(minLength: 10)
            if let status { StatusChip(text: status, filled: live, dot: live) }
        }
        .padding(.vertical, 4)
    }
}

struct ValueTile: View {
    let label: String
    let value: String
    let icon: String

    var body: some View {
        Card {
            HStack(spacing: 11) {
                Image(systemName: icon)
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: 33, height: 33)
                    .foregroundStyle(Palette.green)
                    .background(Palette.lime.opacity(0.75), in: RoundedRectangle(cornerRadius: 10))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(value)
                        .font(.system(.title3, design: .monospaced).weight(.bold))
                        .lineLimit(1).minimumScaleFactor(0.62)
                    Text(label).font(.caption).foregroundStyle(Palette.muted)
                }
            }
            .padding(12)
            .frame(minHeight: 70)
            .accessibilityElement(children: .combine)
        }
    }
}

struct LineRow: View {
    let title: String
    let value: String
    let icon: String
    var mono = false

    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: icon).frame(width: 21).foregroundStyle(Palette.green)
                .accessibilityHidden(true)
            Text(title).font(.subheadline.weight(.medium))
            Spacer()
            Text(value).font(.system(.subheadline, design: mono ? .monospaced : .default))
                .foregroundStyle(Palette.muted).lineLimit(1).minimumScaleFactor(0.72)
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 12)
        .accessibilityElement(children: .combine)
    }
}

struct InlineNotice: View {
    let text: String
    var icon = "info.circle"

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: icon)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
        .font(.footnote)
        .foregroundStyle(Palette.muted)
        .padding(.vertical, 7)
    }
}

struct ActionTile: View {
    let title: String
    let icon: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: icon).font(.title3.weight(.semibold)).accessibilityHidden(true)
                HStack(spacing: 6) {
                    Text(title).font(.subheadline.weight(.bold))
                    Spacer(minLength: 1)
                    Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                        .accessibilityHidden(true)
                }
            }
            .padding(15)
            .frame(maxWidth: .infinity, alignment: .leading)
            .foregroundStyle(Palette.deep)
            .background(Palette.lime, in: RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
    }
}

func formatBytes(_ bytes: Double?) -> String {
    guard let bytes, bytes >= 0, bytes < Double(Int64.max) else { return "—" }
    let units = ["B", "KB", "MB", "GB", "TB"]
    var scale = bytes
    var index = 0
    while scale >= 1_000 && index < units.count - 1 { scale /= 1_000; index += 1 }
    return scale.formatted(.number.precision(.fractionLength(0...(scale >= 100 || index == 0 ? 0 : 1)))) + " " + units[index]
}

func formatMetric(_ value: Double?, suffix: String = "", digits: Int = 0) -> String {
    guard let value else { return "—" }
    return value.formatted(.number.precision(.fractionLength(digits))) + suffix
}
