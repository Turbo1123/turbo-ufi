import SwiftUI

struct AboutScreen: View {
    private let developer = URL(string: "https://github.com/Turbo1123")!
    private let repository = URL(string: "https://github.com/Turbo1123/turbo-ufi")!
    private let upstreamAuthor = URL(string: "https://github.com/kanoqwq")!
    private let upstream = URL(string: "https://github.com/kanoqwq/UFI-TOOLS")!

    var body: some View {
        RouterEditor(title: "关于") {
            RadioCard {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Turbo UFI").font(.title.bold())
                    if let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String {
                        Text("版本 " + version).font(.subheadline.monospaced()).foregroundStyle(Palette.lime)
                    }
                }
            }

            Text("项目").font(.headline).accessibilityAddTraits(.isHeader)
            Card {
                VStack(spacing: 0) {
                    link("开发者 GitHub", detail: "Turbo1123", icon: "person.crop.circle", url: developer)
                    Divider().padding(.leading, 46)
                    link("开源仓库", detail: "turbo-ufi", icon: "chevron.left.forwardslash.chevron.right", url: repository)
                }
            }

            Text("致谢").font(.headline).accessibilityAddTraits(.isHeader)
            Card {
                VStack(alignment: .leading, spacing: 0) {
                    Text("感谢 Minikano（kanoqwq）开源 UFI-TOOLS，为随身 Wi-Fi 提供设备端管理功能和接口。")
                        .font(.subheadline)
                        .padding(15)
                    Divider().padding(.horizontal, 15)
                    link("原作者 GitHub", detail: "kanoqwq", icon: "person.crop.circle", url: upstreamAuthor)
                    Divider().padding(.leading, 46)
                    link("UFI-TOOLS 源码", detail: "kanoqwq/UFI-TOOLS", icon: "chevron.left.forwardslash.chevron.right", url: upstream)
                }
            }
        }
        .accessibilityIdentifier("about-screen")
    }

    private func link(_ title: String, detail: String, icon: String, url: URL) -> some View {
        Link(destination: url) {
            HStack(spacing: 11) {
                Image(systemName: icon).frame(width: 21).foregroundStyle(Palette.green).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(Palette.ink)
                    Text(detail).font(.caption).foregroundStyle(Palette.muted)
                }
                Spacer()
                Image(systemName: "arrow.up.right").font(.caption.weight(.semibold))
                    .foregroundStyle(Palette.muted).accessibilityHidden(true)
            }
            .padding(15)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
    }
}
