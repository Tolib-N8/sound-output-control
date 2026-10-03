import SwiftUI

struct AppInspector: View {
    @Environment(AppModel.self) private var model
    let app: AudioApp

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 26) {
                header
                AppVolumeSection(app: app)
                balance
                outputs
                rules
            }
            .padding(24)
        }
        .frame(maxHeight: .infinity)
        .background(Theme.surface)
        .hairline(.leading)
    }

    private var header: some View {
        HStack(spacing: 14) {
            AppIconView(bundleID: app.bundleID, size: 48)
            VStack(alignment: .leading, spacing: 4) {
                Text(app.name).font(.ui(17, .semibold)).foregroundStyle(Theme.text).lineLimit(1)
                Text(model.statusText(app).text).font(.ui(12)).foregroundStyle(Theme.text2).lineLimit(1)
            }
            Spacer(minLength: 0)
            Button { withAnimation(.easeOut(duration: 0.2)) { model.selection = nil } } label: {
                Icon("x", size: 16, color: Theme.text3)
            }
            .buttonStyle(.sfPlain)
            .keyboardShortcut(.cancelAction)
        }
    }

    private var balance: some View {
        let value = Binding(get: { model.rule(app.bundleID).balance }, set: { model.setBalance(app.bundleID, $0) })
        return VStack(alignment: .leading, spacing: 12) {
            SectionLabel("БАЛАНС", aside: balanceText(value.wrappedValue))
            HStack(spacing: 10) {
                Text("L").font(.mono(11)).foregroundStyle(Theme.text3)
                BalanceSlider(value: value)
                Text("R").font(.mono(11)).foregroundStyle(Theme.text3)
            }
        }
    }

    private func balanceText(_ value: Double) -> String {
        if abs(value) < 0.01 { return "Центр" }
        return (value < 0 ? "L " : "R ") + "\(Int((abs(value) * 100).rounded()))"
    }

    private var outputs: some View {
        let rule = model.rule(app.bundleID)
        let current = model.currentOutputs(app.bundleID)
        return VStack(alignment: .leading, spacing: 10) {
            SectionLabel("ТОЧКИ ВЫХОДА", aside: "Можно несколько")
            VStack(spacing: 0) {
                ForEach(Array(model.outputOptions.enumerated()), id: \.element.id) { index, option in
                    let checked = rule.outputs.contains(option.ref) || (rule.outputs.isEmpty && current.contains(option.ref) && !option.isMulti)
                    Button {
                        model.assign(app.bundleID, to: option.ref, additive: true)
                    } label: {
                        HStack(spacing: 10) {
                            Checkbox(checked: checked)
                            Icon(option.icon, size: 14, color: checked ? Theme.text : Theme.text2)
                            Text(option.name).font(.ui(12)).foregroundStyle(checked ? Theme.text : Theme.text2).lineLimit(1)
                            Spacer(minLength: 0)
                            if rule.outputs.isEmpty && checked {
                                Text("по умолч.").font(.mono(10)).foregroundStyle(Theme.text2)
                                    .padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(RoundedRectangle(cornerRadius: 4).fill(Theme.surface2))
                            } else if !option.connected {
                                Text("нет связи").font(.ui(11)).foregroundStyle(Theme.danger)
                            }
                        }
                        .padding(.vertical, 11).padding(.horizontal, 12)
                        .background(checked ? Theme.accent.opacity(0.05) : .clear)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.sfPlain)
                    .overlay(alignment: .top) { if index > 0 { Divider1() } }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .card(radius: 10, fill: .clear)
            .background(RoundedRectangle(cornerRadius: 10).fill(Theme.bg))
        }
    }

    private var rules: some View {
        let rule = model.rule(app.bundleID)
        let primary = rule.outputs.first.map(model.name(of:)) ?? model.devices.defaultDevice?.name ?? "устройство"
        let current = rule.outputs.isEmpty ? model.currentOutputs(app.bundleID) : RouteResolver.expand(rule.outputs, config: model.config).uids
        let fallback = RouteResolver.fallbackDevice(rule: rule, excluding: Set(current), config: model.config,
                                                    connected: Set(model.devices.devices.map(\.uid)), defaultUID: model.devices.defaultOutputUID)
        let fallbackName = fallback.flatMap { model.devices.device(uid: $0)?.name } ?? "Основное устройство"
        let caller = model.appsInCall.first?.name ?? "звонок"
        return VStack(alignment: .leading, spacing: 14) {
            SectionLabel("ПРАВИЛА")
            ToggleRow(title: "Запомнить настройки", subtitle: "Применять при каждом запуске",
                      isOn: binding(\.remember))
            ToggleRow(title: "Резервный выход",
                      subtitle: rule.useFallback ? "\(fallbackName), если \(primary) отключены" : "Пауза, пока \(primary) не вернутся",
                      isOn: binding(\.useFallback))
            ToggleRow(title: "Приглушать во время звонков",
                      subtitle: "−\(Int(model.config.prefs.duckAmount * 100))% когда активен \(caller)",
                      isOn: binding(\.duckDuringCalls))
            HStack {
                Button("Сбросить") { model.resetRule(app.bundleID) }.buttonStyle(.sfGhost)
                Spacer()
            }
        }
    }

    private func binding(_ keyPath: WritableKeyPath<AppRule, Bool>) -> Binding<Bool> {
        Binding(get: { model.rule(app.bundleID)[keyPath: keyPath] },
                set: { value in model.updateRule(app.bundleID) { $0[keyPath: keyPath] = value } })
    }
}

/// Big volume number, slider and a live stereo meter.
struct AppVolumeSection: View {
    @Environment(AppModel.self) private var model
    let app: AudioApp
    var label = "ГРОМКОСТЬ ПРИЛОЖЕНИЯ"

    var body: some View {
        let rule = model.rule(app.bundleID)
        let volume = Binding(get: { model.rule(app.bundleID).volume }, set: { model.setVolume(app.bundleID, $0) })
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(label).sectionLabelStyle()
                Spacer()
                MuteButton(muted: rule.muted, size: 24) { model.toggleMute(app.bundleID) }
            }
            HStack(alignment: .lastTextBaseline, spacing: 4) {
                Text(rule.muted ? "—" : percent(rule.volume)).font(.mono(44, .medium)).tracking(-1.5)
                    .foregroundStyle(rule.muted ? Theme.text3 : Theme.text)
                    .contentTransition(.numericText())
                Text("%").font(.mono(18)).foregroundStyle(Theme.text3)
            }
            SFSlider(value: volume, showsFill: !rule.muted)
            LiveLevel(level: { model.engine.level(app.bundleID) }) { _ in
                let live = model.status(app.bundleID)?.hasLevel == true
                let stereo = model.engine.stereoLevel(app.bundleID)
                VStack(spacing: 5) {
                    SegmentMeter(label: "L", level: live ? meterFraction(stereo.left) : 0)
                    SegmentMeter(label: "R", level: live ? meterFraction(stereo.right) : 0)
                }
            }
            if model.engine.permission == .denied, app.isPlaying {
                Text("Разрешите «Запись системного звука» в настройках Soundflow, чтобы видеть уровень.")
                    .font(.ui(10)).foregroundStyle(Theme.text3).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
