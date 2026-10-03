import SwiftUI

/// Header bar used by sheets: centered title on the surface color.
struct SheetHeader: View {
    let title: String

    var body: some View {
        Text(title).font(.ui(13, .semibold)).foregroundStyle(Theme.text)
            .frame(maxWidth: .infinity).frame(height: 44)
            .background(Theme.surface)
            .hairline(.bottom)
    }
}

struct SheetFooter<Leading: View, Trailing: View>: View {
    @ViewBuilder var leading: Leading
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack {
            leading
            Spacer()
            HStack(spacing: 8) { trailing }
        }
        .padding(.vertical, 14).padding(.horizontal, 28)
        .background(Theme.surface)
        .hairline(.top)
    }
}

struct LabeledField<Content: View>: View {
    let label: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label).sectionLabelStyle()
            content
        }
    }
}

struct SFTextField: View {
    @Binding var text: String
    var placeholder = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField("", text: $text, prompt: Text(placeholder).foregroundStyle(Theme.text3))
            .textFieldStyle(.plain)
            .font(.ui(13))
            .foregroundStyle(Theme.text)
            .focused($focused)
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.surface2))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(focused ? Theme.accent.opacity(0.4) : Theme.border))
    }
}

struct MultiOutputEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var draft: MultiOutput
    private let isNew: Bool

    init(draft: MultiOutput) {
        _draft = State(initialValue: draft)
        isNew = draft.deviceUIDs.isEmpty
    }

    var body: some View {
        let devices = model.devices.devices.filter { $0.transport != .aggregate }
        VStack(spacing: 0) {
            SheetHeader(title: isNew ? "Новый мульти-выход" : "Мульти-выход «\(draft.name)»")
            VStack(alignment: .leading, spacing: 22) {
                HStack(spacing: 14) {
                    RoundedRectangle(cornerRadius: 11).fill(Theme.warning.opacity(0.13)).frame(width: 44, height: 44)
                        .overlay(Icon("git-merge", size: 20, color: Theme.warning))
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Звук на несколько устройств сразу").font(.ui(15, .semibold)).foregroundStyle(Theme.text)
                        Text("Объедините устройства в одно — и назначайте его приложениям как обычный выход.")
                            .font(.ui(12)).foregroundStyle(Theme.text2)
                    }
                }
                LabeledField(label: "НАЗВАНИЕ") { SFTextField(text: $draft.name, placeholder: "Колонки + наушники") }

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("УСТРОЙСТВА").sectionLabelStyle()
                        Spacer()
                        Text("ЗАДЕРЖКА").font(.ui(10, .semibold)).tracking(0.8).foregroundStyle(Theme.text3).frame(width: 80, alignment: .trailing)
                        Text("ЧАСЫ").font(.ui(10, .semibold)).tracking(0.8).foregroundStyle(Theme.text3).frame(width: 40)
                    }
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(spacing: 0) {
                            ForEach(Array(devices.enumerated()), id: \.element.uid) { index, device in
                                deviceRow(device, index: index)
                            }
                        }
                    }
                    .frame(maxHeight: 54 * 4)
                    .fixedSize(horizontal: false, vertical: true)
                    .card(radius: 12)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }

                VStack(spacing: 0) {
                    SettingsToggle(title: "Выравнивать задержку", subtitle: alignmentText, first: true, isOn: $draft.alignLatency)
                    SettingsToggle(title: "Коррекция дрейфа", subtitle: "Подстраивать частоту устройств под главные часы", isOn: $draft.driftCorrection)
                }
                .card(radius: 12)
            }
            .padding(28)

            SheetFooter {
                HStack(spacing: 16) {
                    Button { TestTone.play(on: draft.deviceUIDs, delays: totalDelays) } label: {
                        IconLabel(icon: "play", title: "Проверить звук", color: Theme.text2)
                    }
                    .buttonStyle(.plain).font(.ui(12)).foregroundStyle(Theme.text2)
                    .disabled(draft.deviceUIDs.isEmpty)
                    if !isNew {
                        Button { model.deleteMultiOutput(draft.id); dismiss() } label: {
                            IconLabel(icon: "trash-2", title: "Удалить", color: Theme.danger)
                        }
                        .buttonStyle(.plain).font(.ui(12)).foregroundStyle(Theme.danger)
                    }
                }
            } trailing: {
                Button("Отмена") { dismiss() }.buttonStyle(.sfSecondary).keyboardShortcut(.cancelAction)
                Button {
                    if draft.clockUID == nil || !draft.deviceUIDs.contains(draft.clockUID!) { draft.clockUID = draft.deviceUIDs.first }
                    model.saveMultiOutput(draft)
                    dismiss()
                } label: { IconLabel(icon: isNew ? "plus" : "check", title: isNew ? "Создать" : "Сохранить", color: Theme.accentInk) }
                    .buttonStyle(.sfPrimary)
                    .keyboardShortcut(.defaultAction)
                    .disabled(draft.deviceUIDs.count < 2 || draft.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .frame(width: 640)
        .background(Theme.bg)
        .preferredColorScheme(.dark)
    }

    private func deviceRow(_ device: AudioDevice, index: Int) -> some View {
        let selected = draft.deviceUIDs.contains(device.uid)
        let colors: [Color] = [Color(hex: 0x60A5FA), Theme.accent, Color(hex: 0xA78BFA), Color(hex: 0xF87171), Color(hex: 0x34D399)]
        let color = colors[index % colors.count]
        let delay = Binding(get: { Int(draft.delays[device.uid] ?? 0) },
                            set: { draft.delays[device.uid] = Double(max(0, min(1000, $0))) })
        return HStack(spacing: 12) {
            Button {
                if selected { draft.deviceUIDs.removeAll { $0 == device.uid } } else { draft.deviceUIDs.append(device.uid) }
                if draft.clockUID == nil || !draft.deviceUIDs.contains(draft.clockUID ?? "") { draft.clockUID = draft.deviceUIDs.first }
            } label: {
                HStack(spacing: 12) {
                    Checkbox(checked: selected)
                    RoundedRectangle(cornerRadius: 8).fill(color.opacity(0.13)).frame(width: 30, height: 30)
                        .overlay(Icon(device.kind.icon, size: 15, color: color))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(device.name).font(.ui(13, .medium)).foregroundStyle(selected ? Theme.text : Theme.text2)
                        Text("\(device.transport.title) · \(device.formatDescription)" + (device.latencyMs > 1 ? " · ~\(Int(device.latencyMs)) мс" : ""))
                            .font(.ui(11)).foregroundStyle(Theme.text3)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if selected {
                HStack(spacing: 4) {
                    TextField("", value: delay, format: .number)
                        .textFieldStyle(.plain).multilineTextAlignment(.trailing)
                        .font(.mono(12)).foregroundStyle(Theme.text)
                    Text("мс").font(.mono(12)).foregroundStyle(Theme.text3)
                }
                .padding(.horizontal, 8).padding(.vertical, 5)
                .frame(width: 80)
                .card(radius: 6, fill: Theme.surface2)
                .help("Дополнительная задержка для этого устройства")
            } else {
                Text("—").font(.mono(12)).foregroundStyle(Theme.text3).frame(width: 80, alignment: .trailing)
            }
            Button { draft.clockUID = device.uid } label: { RadioDot(selected: draft.clockUID == device.uid && selected) }
                .buttonStyle(.plain)
                .frame(width: 40)
                .disabled(!selected)
                .help("Главные часы — остальные устройства подстраиваются под них")
        }
        .padding(.vertical, 12).padding(.horizontal, 16)
        .overlay(alignment: .top) { if index > 0 { Divider1() } }
    }

    private var latencies: [String: Double] {
        Dictionary(model.devices.devices.map { ($0.uid, $0.latencyMs) }, uniquingKeysWith: { a, _ in a })
    }

    private var totalDelays: [String: Double] {
        RouteResolver.alignment(for: draft, outputs: draft.deviceUIDs, latencies: latencies)
    }

    private var alignmentText: String {
        let selected = draft.deviceUIDs
        guard selected.count >= 2 else { return "Задерживать быстрые устройства, чтобы звук совпадал" }
        let auto = RouteResolver.alignment(for: MultiOutput(name: "", deviceUIDs: selected, alignLatency: true), outputs: selected, latencies: latencies)
        guard let (uid, ms) = auto.max(by: { $0.value < $1.value }) else { return "Задержки устройств уже совпадают" }
        let slowest = selected.max { (latencies[$0] ?? 0) < (latencies[$1] ?? 0) }.map(model.name(of:)) ?? ""
        return "Задержать \(model.name(of: uid)) на \(Int(ms.rounded())) мс, чтобы звук совпадал с \(slowest)"
    }
}
