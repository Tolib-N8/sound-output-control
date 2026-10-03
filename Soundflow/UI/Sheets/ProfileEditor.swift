import AppKit
import CoreWLAN
import SwiftUI
import UniformTypeIdentifiers

struct ProfileEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var draft: Profile
    @State private var editingSchedule: Int?
    @State private var addingWifi = false
    @State private var wifiName = ""
    private let isNew: Bool

    static let icons = ["briefcase", "gamepad-2", "radio", "moon", "music", "headphones", "coffee", "code", "film", "mic", "sliders-horizontal", "zap", "star", "tv"]

    init(draft: Profile) {
        _draft = State(initialValue: draft)
        isNew = draft.rules.isEmpty && draft.triggers.isEmpty && draft.name == "Новый профиль"
    }

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: "Профиль «\(draft.name)»")
            VStack(alignment: .leading, spacing: 24) {
                identity
                triggers
                rules
            }
            .padding(28)
            SheetFooter {
                if model.config.profiles.contains(where: { $0.id == draft.id }) {
                    Button {
                        if model.config.activeProfileID == draft.id { model.profiles.deactivate() }
                        model.config.profiles.removeAll { $0.id == draft.id }
                        model.hotkeys.registerAll()
                        dismiss()
                    } label: { IconLabel(icon: "trash-2", title: "Удалить профиль", color: Theme.danger) }
                        .buttonStyle(.plain).font(.ui(12, .medium)).foregroundStyle(Theme.danger)
                }
            } trailing: {
                Button("Отмена") { dismiss() }.buttonStyle(.sfSecondary).keyboardShortcut(.cancelAction)
                Button { save() } label: { IconLabel(icon: "check", title: "Сохранить профиль", color: Theme.accentInk) }
                    .buttonStyle(.sfPrimary)
                    .keyboardShortcut(.defaultAction)
                    .disabled(draft.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .frame(width: 800)
        .background(Theme.bg)
        .preferredColorScheme(.dark)
    }

    // MARK: - Sections

    private var identity: some View {
        HStack(alignment: .bottom, spacing: 16) {
            LabeledField(label: "ИКОНКА") {
                Menu {
                    ForEach(Self.icons, id: \.self) { icon in
                        Button { draft.icon = icon } label: { Label(icon, image: "lucide.\(icon)") }
                    }
                } label: {
                    RoundedRectangle(cornerRadius: 10).fill(Theme.accent).frame(width: 42, height: 42)
                        .overlay(Icon(draft.icon, size: 20, color: Theme.accentInk))
                }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            }
            LabeledField(label: "НАЗВАНИЕ") { SFTextField(text: $draft.name) }.frame(width: 283)
            LabeledField(label: "ГОРЯЧАЯ КЛАВИША") {
                HotkeyRecorder(hotkey: draft.hotkey) { draft.hotkey = $0 }
                    .padding(.horizontal, 12)
                    .frame(width: 140, height: 34, alignment: .leading)
                    .card(radius: 8, fill: Theme.surface2)
            }
            LabeledField(label: "ОСНОВНОЙ ВЫХОД") {
                OutputSelect(ref: $draft.mainOutput, emptyTitle: "Не менять", width: 220)
            }
        }
    }

    private var triggers: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("ВКЛЮЧАТЬ АВТОМАТИЧЕСКИ").sectionLabelStyle()
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Array(draft.triggers.enumerated()), id: \.offset) { index, trigger in
                        triggerChip(trigger, index: index)
                    }
                    addTriggerMenu
                }
            }
            if !draft.triggers.isEmpty {
                Text("Профиль включится, когда выполнены все отмеченные условия. Нажмите на условие, чтобы включить или выключить его.")
                    .font(.ui(11)).foregroundStyle(Theme.text3)
            }
        }
        .popover(isPresented: Binding(get: { editingSchedule != nil }, set: { if !$0 { editingSchedule = nil } })) {
            if let index = editingSchedule, case let .schedule(days, start, end) = draft.triggers[index] {
                ScheduleEditor(weekdays: days, start: start, end: end) { days, start, end in
                    draft.triggers[index] = .schedule(weekdays: days, start: start, end: end)
                }
            }
        }
        .popover(isPresented: $addingWifi) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Название сети Wi‑Fi").font(.ui(12, .medium)).foregroundStyle(Theme.text)
                SFTextField(text: $wifiName, placeholder: "Office")
                Button("Добавить") {
                    let name = wifiName.trimmingCharacters(in: .whitespaces)
                    if !name.isEmpty { addTrigger(.wifi(ssid: name)) }
                    addingWifi = false
                }
                .buttonStyle(.sfPrimary)
            }
            .padding(14).frame(width: 260).background(Theme.surface)
        }
    }

    private func triggerChip(_ trigger: ProfileTrigger, index: Int) -> some View {
        let enabled = draft.enabledTriggers.contains(index)
        return HStack(spacing: 8) {
            Icon(triggerIcon(trigger), size: 13, color: enabled ? Theme.accent : Theme.text3)
            Text(triggerTitle(trigger)).font(.ui(12)).foregroundStyle(enabled ? Theme.text : Theme.text2)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Capsule().fill(enabled ? Theme.accent.opacity(0.094) : Theme.surface))
        .overlay(Capsule().strokeBorder(enabled ? Theme.accent.opacity(0.33) : Theme.border))
        .contentShape(Capsule())
        .onTapGesture {
            if enabled { draft.enabledTriggers.remove(index) } else { draft.enabledTriggers.insert(index) }
        }
        .contextMenu {
            if case .schedule = trigger { Button("Изменить время…") { editingSchedule = index } }
            Button("Удалить", role: .destructive) { removeTrigger(at: index) }
        }
    }

    private var addTriggerMenu: some View {
        Menu {
            Menu("Подключено устройство") {
                ForEach(model.devices.devices) { device in
                    Button(device.name) { addTrigger(.deviceConnected(uid: device.uid)) }
                }
            }
            Button("Расписание…") {
                addTrigger(.schedule(weekdays: Set(1...5), start: 9 * 60, end: 18 * 60))
                editingSchedule = draft.triggers.count - 1
            }
            Menu("Запущено приложение") {
                ForEach(NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular && $0.bundleIdentifier != nil }, id: \.processIdentifier) { app in
                    Button(app.localizedName ?? app.bundleIdentifier!) { addTrigger(.appRunning(bundleID: app.bundleIdentifier!)) }
                }
            }
            Button("Сеть Wi‑Fi…") {
                wifiName = CWWiFiClient.shared().interface()?.ssid() ?? ""
                addingWifi = true
            }
        } label: {
            Circle().strokeBorder(Color.white.opacity(0.13)).frame(width: 34, height: 34)
                .overlay(Icon("plus", size: 14, color: Theme.text2))
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
    }

    private var rules: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("ПРАВИЛА ДЛЯ ПРИЛОЖЕНИЙ").sectionLabelStyle()
                Spacer()
                addAppMenu
            }
            VStack(spacing: 0) {
                HStack(spacing: 16) {
                    Text("ПРИЛОЖЕНИЕ").frame(maxWidth: .infinity, alignment: .leading)
                    Text("ГРОМКОСТЬ").frame(width: 220, alignment: .leading)
                    Text("ВЫХОД").frame(width: 190, alignment: .leading)
                    Color.clear.frame(width: 16, height: 1)
                }
                .font(.ui(10, .semibold)).tracking(0.8).foregroundStyle(Theme.text3)
                .padding(.vertical, 10).padding(.horizontal, 16)

                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 0) {
                        ForEach($draft.rules) { $rule in
                            ruleRow(bundleID: rule.bundleID, volume: $rule.volume, muted: $rule.muted, output: $rule.output) {
                                draft.rules.removeAll { $0.bundleID == rule.bundleID }
                            }
                        }
                        othersRow
                    }
                }
                .frame(maxHeight: 49 * 5)
                .fixedSize(horizontal: false, vertical: true)
            }
            .card(radius: 12)
            .clipShape(RoundedRectangle(cornerRadius: 12))

            HStack(spacing: 12) {
                SFSwitch(isOn: Binding(get: { draft.maxVolume != nil }, set: { draft.maxVolume = $0 ? 0.3 : nil }))
                Text("Ограничить громкость всех приложений").font(.ui(12, .medium)).foregroundStyle(Theme.text)
                if let cap = draft.maxVolume {
                    SFSlider(value: Binding(get: { cap }, set: { draft.maxVolume = max(0.05, $0) })).frame(width: 160)
                    Text("≤ \(percent(cap))%").font(.mono(12)).foregroundStyle(Theme.text2)
                }
                Spacer()
            }
            .padding(.top, 6)
        }
    }

    private func ruleRow(bundleID: String, volume: Binding<Double>, muted: Binding<Bool>, output: Binding<OutputRef?>, remove: @escaping () -> Void) -> some View {
        HStack(spacing: 16) {
            HStack(spacing: 10) {
                AppIconView(bundleID: bundleID, size: 28)
                Text(AppInfo.name(bundleID)).font(.ui(12, .medium)).foregroundStyle(Theme.text).lineLimit(1)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity)
            HStack(spacing: 10) {
                if muted.wrappedValue {
                    Button { muted.wrappedValue = false } label: {
                        HStack(spacing: 6) {
                            Icon("volume-x", size: 12, color: Theme.danger)
                            Text("Без звука").font(.ui(11, .medium)).foregroundStyle(Theme.danger)
                        }
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Theme.dangerFill.opacity(0.13)))
                    }
                    .buttonStyle(.plain)
                    Spacer(minLength: 0)
                } else {
                    Button { muted.wrappedValue = true } label: { Icon("volume-2", size: 13, color: Theme.text3) }
                        .buttonStyle(.plain).help("Без звука")
                    SFSlider(value: volume).frame(width: 140)
                    Text(percent(volume.wrappedValue)).font(.mono(12)).foregroundStyle(Theme.text2).frame(width: 28, alignment: .leading)
                }
            }
            .frame(width: 220, alignment: .leading)
            OutputSelect(ref: output, emptyTitle: "Основной выход", width: 190)
            Button(action: remove) { Icon("trash-2", size: 14, color: Theme.text3) }.buttonStyle(.plain).frame(width: 16)
        }
        .padding(.vertical, 10).padding(.horizontal, 16)
        .overlay(alignment: .top) { Divider1() }
    }

    private var othersRow: some View {
        HStack(spacing: 16) {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 7).fill(Color(hex: 0x3A3F48)).frame(width: 28, height: 28)
                    .overlay(Icon("layout-grid", size: 14, color: Theme.text2))
                Text("Остальные приложения").font(.ui(12, .medium)).foregroundStyle(Theme.text2)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity)
            HStack(spacing: 10) {
                Icon("volume-2", size: 13, color: Theme.text3)
                SFSlider(value: $draft.othersVolume).frame(width: 140)
                Text(percent(draft.othersVolume)).font(.mono(12)).foregroundStyle(Theme.text2).frame(width: 28, alignment: .leading)
            }
            .frame(width: 220, alignment: .leading)
            OutputSelect(ref: $draft.othersOutput, emptyTitle: "Основной выход", width: 190)
            Color.clear.frame(width: 16, height: 1)
        }
        .padding(.vertical, 10).padding(.horizontal, 16)
        .overlay(alignment: .top) { Divider1() }
    }

    private var addAppMenu: some View {
        let existing = Set(draft.rules.map(\.bundleID))
        let candidates = (model.apps.map(\.bundleID) + model.config.appRules.keys).reduce(into: [String]()) { list, id in
            if !existing.contains(id) && !list.contains(id) { list.append(id) }
        }
        return Menu {
            ForEach(candidates, id: \.self) { bundleID in
                Button(AppInfo.name(bundleID)) { draft.rules.append(ProfileAppRule(bundleID: bundleID)) }
            }
            Divider()
            Button("Выбрать приложение…") { chooseApp() }
        } label: {
            HStack(spacing: 6) {
                Icon("plus", size: 13, color: Theme.accent)
                Text("Добавить приложение").font(.ui(12, .medium)).foregroundStyle(Theme.accent)
            }
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
    }

    // MARK: - Actions

    private func chooseApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            guard let id = Bundle(url: url)?.bundleIdentifier, !draft.rules.contains(where: { $0.bundleID == id }) else { continue }
            draft.rules.append(ProfileAppRule(bundleID: id))
        }
    }

    private func addTrigger(_ trigger: ProfileTrigger) {
        guard !draft.triggers.contains(trigger) else { return }
        draft.triggers.append(trigger)
        draft.enabledTriggers.insert(draft.triggers.count - 1)
    }

    private func removeTrigger(at index: Int) {
        draft.triggers.remove(at: index)
        draft.enabledTriggers = Set(draft.enabledTriggers.compactMap { $0 == index ? nil : ($0 > index ? $0 - 1 : $0) })
    }

    private func save() {
        if let index = model.config.profiles.firstIndex(where: { $0.id == draft.id }) {
            model.config.profiles[index] = draft
        } else {
            model.config.profiles.append(draft)
        }
        if model.config.activeProfileID == draft.id { model.profiles.activate(draft.id) }
        model.hotkeys.registerAll()
        model.profiles.evaluate()
        dismiss()
    }

    private func triggerIcon(_ trigger: ProfileTrigger) -> String {
        switch trigger {
        case .deviceConnected(let uid): model.icon(of: uid)
        case .appRunning: "app-window"
        case .wifi: "wifi"
        case .schedule: "clock-3"
        }
    }

    private func triggerTitle(_ trigger: ProfileTrigger) -> String {
        switch trigger {
        case .deviceConnected(let uid): "Подключены \(model.name(of: uid))"
        case .appRunning(let bundleID): "Запущен \(AppInfo.name(bundleID))"
        case .wifi(let ssid): "Сеть «\(ssid)»"
        case let .schedule(days, start, end): ProfileTrigger.scheduleText(weekdays: days, start: start, end: end)
        }
    }
}

/// Output select menu bound to an optional output ref.
struct OutputSelect: View {
    @Environment(AppModel.self) private var model
    @Binding var ref: OutputRef?
    let emptyTitle: String
    var width: CGFloat = 190

    var body: some View {
        SettingsSelect(icon: ref.map(model.icon(of:)) ?? "star", text: ref.map(model.name(of:)) ?? emptyTitle, width: width) {
            Button(emptyTitle) { ref = nil }
            Divider()
            ForEach(model.outputOptions) { option in
                Button(option.name) { ref = option.ref }
            }
        }
    }
}

struct ScheduleEditor: View {
    @State var weekdays: Set<Int>
    @State var start: Int
    @State var end: Int
    let onChange: (Set<Int>, Int, Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Расписание").font(.ui(13, .semibold)).foregroundStyle(Theme.text)
            HStack(spacing: 4) {
                ForEach(1...7, id: \.self) { day in
                    let on = weekdays.contains(day)
                    Button {
                        if on { weekdays.remove(day) } else { weekdays.insert(day) }
                        onChange(weekdays, start, end)
                    } label: {
                        Text(["Пн", "Вт", "Ср", "Чт", "Пт", "Сб", "Вс"][day - 1]).font(.ui(11, .medium))
                            .foregroundStyle(on ? Theme.accentInk : Theme.text2)
                            .frame(width: 30, height: 26)
                            .background(RoundedRectangle(cornerRadius: 6).fill(on ? Theme.accent : Theme.surface2))
                    }
                    .buttonStyle(.plain)
                }
            }
            HStack(spacing: 10) {
                timePicker("С", $start)
                timePicker("до", $end)
            }
        }
        .padding(14)
        .background(Theme.surface)
    }

    private func timePicker(_ label: String, _ minutes: Binding<Int>) -> some View {
        let date = Binding<Date>(
            get: { Calendar.current.date(bySettingHour: minutes.wrappedValue / 60, minute: minutes.wrappedValue % 60, second: 0, of: Date()) ?? Date() },
            set: { value in
                let parts = Calendar.current.dateComponents([.hour, .minute], from: value)
                minutes.wrappedValue = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
                onChange(weekdays, start, end)
            })
        return HStack(spacing: 6) {
            Text(label).font(.ui(12)).foregroundStyle(Theme.text2)
            DatePicker("", selection: date, displayedComponents: .hourAndMinute).labelsHidden().datePickerStyle(.field)
        }
    }
}
