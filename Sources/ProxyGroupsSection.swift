import SwiftUI

struct ProxyGroupsSection: View {
    @EnvironmentObject private var model: AppModel
    @State private var expanded: String?
    @State private var search = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("策略组").font(.headline).accessibilityAddTraits(.isHeader)
                Spacer()
                if model.policyLoading {
                    ProgressView().controlSize(.small).accessibilityLabel("正在同步策略组")
                } else {
                    Button {
                        Task { await model.refreshPolicyGroups() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .frame(width: 40, height: 36)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Palette.green)
                    .accessibilityLabel("刷新策略组")
                    .disabled(model.demo || model.proxyBusy)
                }
            }

            if let issue = model.policyIssue { InlineNotice(text: issue, icon: "exclamationmark.circle") }
            if model.policyGroups.isEmpty && !model.policyLoading && model.policyIssue == nil {
                InlineNotice(text: "暂无可切换的策略组")
            }

            ForEach(model.policyGroups) { group in
                Card {
                    VStack(spacing: 0) {
                        Button {
                            expanded = expanded == group.id ? nil : group.id
                            search = ""
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "point.3.connected.trianglepath.dotted")
                                    .foregroundStyle(Palette.green).accessibilityHidden(true)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(group.name).font(.subheadline.bold())
                                    if let label = group.kind.automaticLabel {
                                        Text(group.fixed == nil ? label : "已固定节点")
                                            .font(.caption2).foregroundStyle(Palette.muted)
                                    }
                                }
                                Spacer(minLength: 8)
                                if let current = group.current {
                                    Text(current).font(.caption.weight(.semibold)).foregroundStyle(Palette.green)
                                        .lineLimit(1)
                                }
                                Image(systemName: expanded == group.id ? "chevron.down" : "chevron.right")
                                    .font(.caption.weight(.semibold)).foregroundStyle(Palette.muted)
                                    .accessibilityHidden(true)
                            }
                            .padding(.horizontal, 13)
                            .frame(minHeight: 49)
                            .contentShape(Rectangle())
                        }
                        .accessibilityValue(expanded == group.id ? "已展开" : "已收起")

                        if expanded == group.id { nodes(group) }
                    }
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("proxy-policy-groups")
    }

    private func nodes(_ group: ProxyGroup) -> some View {
        let matches = search.isEmpty ? group.nodes : group.nodes.filter { $0.localizedCaseInsensitiveContains(search) }
        return LazyVStack(spacing: 1) {
            if group.kind != .selector {
                Button {
                    Task { await model.changePolicySelection(.automatic, in: group) }
                } label: {
                    HStack {
                        Label("恢复自动选择", systemImage: "arrow.clockwise")
                        Spacer()
                        if group.fixed == nil { Image(systemName: "checkmark").accessibilityHidden(true) }
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Palette.green)
                    .padding(.horizontal, 10)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .disabled(!group.canRestoreAutomatic || model.policyLoading || model.proxyBusy)
                .accessibilityAddTraits(group.fixed == nil ? .isSelected : [])
                if let fixed = group.fixed, fixed != group.current {
                    InlineNotice(text: "已固定 " + fixed + " · 当前使用 " + (group.current ?? "—"))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                }
                Divider()
            }
            if group.nodes.count > 8 {
                TextField("查找节点", text: $search)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .padding(9)
                    .font(.subheadline)
                    .background(Palette.paper, in: RoundedRectangle(cornerRadius: 8))
                    .padding(.bottom, 4)
            }
            if matches.isEmpty { InlineNotice(text: "没有匹配的节点", icon: "magnifyingglass") }
            ForEach(matches, id: \.self) { node in
                let selected = node == group.selected
                Button {
                    Task { await model.changePolicySelection(.node(node), in: group) }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(selected ? Palette.green : Palette.muted)
                            .accessibilityHidden(true)
                        Text(node).font(.subheadline)
                        Spacer()
                        if group.kind != .selector, node == group.current {
                            Text("当前使用").font(.caption2).foregroundStyle(Palette.green)
                        }
                    }
                    .padding(.horizontal, 10)
                    .frame(minHeight: 44)
                    .background(selected ? Palette.lime : .clear, in: RoundedRectangle(cornerRadius: 8))
                    .contentShape(Rectangle())
                }
                .accessibilityAddTraits(selected ? .isSelected : [])
                .disabled(selected || model.policyLoading || model.proxyBusy)
            }
        }
        .padding(.horizontal, 9)
        .padding(.bottom, 8)
    }
}
