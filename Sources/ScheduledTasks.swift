import SwiftUI

struct ScheduledTasks: View {
    @EnvironmentObject private var model: AppModel
    @State private var tasks: [RouterTask]?
    @State private var draft: Draft?
    @State private var pendingDelete: RouterTask?
    @State private var busy = false
    @State private var notice: String?

    private struct Draft {
        var id = ""
        var time = "03:00"
        var daily = true
        var preset: TaskPreset? = .lightOff
        var original: RouterTask?

        init() {}
        init(_ task: RouterTask) {
            id = task.id
            time = task.time
            daily = task.repeatDaily
            preset = task.preset
            original = task
        }

        func task() throws -> RouterTask {
            let id = id.trimmingCharacters(in: .whitespacesAndNewlines)
            let parts = time.split(separator: ":", omittingEmptySubsequences: false)
            guard !id.isEmpty, id.count <= 100,
                  parts.count == 2, let hour = Int(parts[0]), let minute = Int(parts[1]),
                  (0...23).contains(hour), (0...59).contains(minute),
                  let action = preset?.action.parameters ?? original?.actionMap else {
                throw ConnectionError.validation("请填写任务名称、有效时间和动作。时间格式为 HH:mm。")
            }
            return RouterTask(id: id, time: String(format: "%02d:%02d", hour, minute), repeatDaily: daily,
                              actionMap: action, lastRunTimestamp: nil, hasTriggered: false)
        }
    }

    var body: some View {
        RouterEditor(title: "定时任务") {
            if let draft = Binding($draft) { editor(draft) }
            else {
                RouterSave(title: "添加任务", disabled: busy) { draft = Draft() }
                InlineNotice(text: "任务由设备独立执行，保存时会同步它用于执行任务的某兴后台凭据。")
            }
            if let notice { InlineNotice(text: notice) }
            if let tasks {
                if tasks.isEmpty { InlineNotice(text: "没有定时任务", icon: "clock") }
                ForEach(tasks) { task in taskCard(task) }
            } else if notice == nil {
                ProgressView().accessibilityLabel("正在读取任务")
            }
        }
        .task { await reload() }
        .alert("确认删除任务？", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
               presenting: pendingDelete) { task in
            Button("删除", role: .destructive) { Task { await remove(task) } }
            Button("取消", role: .cancel) {}
        } message: { task in
            Text(task.id)
        }
    }

    private func editor(_ draft: Binding<Draft>) -> some View {
        VStack(spacing: 10) {
            Card {
                VStack(spacing: 0) {
                    RouterField(label: "任务名称") {
                        TextField("名称", text: draft.id).disabled(draft.wrappedValue.original != nil)
                    }
                    Divider()
                    RouterField(label: "触发时间（设备本地时间）") {
                        TextField("HH:mm", text: draft.time).numbersOnlyTime()
                    }
                    Divider()
                    Toggle("每日重复", isOn: draft.daily).padding(14)
                    Divider()
                    Picker("执行动作", selection: draft.preset) {
                        if draft.wrappedValue.original?.preset == nil && draft.wrappedValue.original != nil {
                            Text("保留原动作").tag(Optional<TaskPreset>.none)
                        }
                        ForEach(TaskPreset.allCases) { preset in Text(preset.title).tag(Optional(preset)) }
                    }
                    .padding(14)
                }
            }
            HStack {
                Button("取消") { self.draft = nil }.padding(.horizontal, 12)
                RouterSave(title: "保存任务", disabled: busy) {
                    let value = draft.wrappedValue
                    Task { await save(value) }
                }
            }
        }
        .disabled(busy)
    }

    private func taskCard(_ task: RouterTask) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(task.time).font(.title2.monospaced().bold()).foregroundStyle(Palette.green)
                    Spacer()
                    StatusChip(text: task.repeatDaily ? "每日" : "一次", filled: task.repeatDaily)
                }
                Text(task.id).font(.headline)
                Text(task.title).font(.subheadline).foregroundStyle(Palette.muted)
                if let last = task.lastRunTimestamp, last > 0 {
                    Text("上次执行 " + Date(timeIntervalSince1970: Double(last) / 1000).formatted())
                        .font(.caption).foregroundStyle(Palette.muted)
                }
                HStack {
                    Button("编辑") { draft = Draft(task) }
                    Spacer()
                    Button("删除", role: .destructive) { pendingDelete = task }.tint(Palette.warning)
                }
                .buttonStyle(.borderless)
                .disabled(busy)
            }
            .padding(15)
        }
    }

    private func reload() async {
        do { tasks = model.demo ? RouterTask.demo : try await model.routerSettingsClient().listTasks() }
        catch { notice = error.localizedDescription }
    }

    private func save(_ draft: Draft) async {
        busy = true
        notice = nil
        defer { busy = false }
        do {
            let task = try draft.task()
            if draft.original == nil, tasks?.contains(where: { $0.id == task.id }) == true {
                throw ConnectionError.validation("此任务名称已存在，请编辑现有任务。")
            }
            if model.demo {
                tasks = [task] + (tasks ?? []).filter { $0.id != task.id }
            } else {
                try await model.routerSettingsClient().saveTask(task, credentials: model.credentials)
                await reload()
            }
            self.draft = nil
        } catch { notice = error.localizedDescription }
    }

    private func remove(_ task: RouterTask) async {
        busy = true
        notice = nil
        defer { busy = false }
        do {
            if model.demo { tasks?.removeAll { $0.id == task.id } }
            else {
                try await model.routerSettingsClient().deleteTask(task)
                await reload()
            }
        } catch { notice = error.localizedDescription }
    }
}

private extension View {
    func numbersOnlyTime() -> some View {
        keyboardType(.numbersAndPunctuation)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .monospaced()
    }
}
