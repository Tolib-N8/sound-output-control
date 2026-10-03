import SwiftUI

struct OnboardingView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var step: Int = {
        #if DEBUG
        if let screen = UserDefaults.standard.string(forKey: "SFScreen"), screen.hasPrefix("onboarding:") { return Int(screen.dropFirst(11)) ?? 0 }
        #endif
        return 0
    }()
    @State private var requesting = false

    var body: some View {
        HStack(spacing: 0) {
            visual
                .frame(width: 280)
                .frame(maxHeight: .infinity)
                .background(
                    RadialGradient(colors: [Theme.accent.opacity(0.12), Theme.surface], center: .center, startRadius: 0, endRadius: 320)
                )
                .hairline(.trailing)
            VStack(alignment: .leading, spacing: 18) {
                steps
                switch step {
                case 0: welcome
                case 1: permission
                default: finish
                }
            }
            .padding(EdgeInsets(top: 40, leading: 36, bottom: 28, trailing: 36))
            .frame(width: 460)
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .frame(width: 740)
        .frame(minHeight: 468, maxHeight: .infinity)
        .background(Theme.bg)
        .ignoresSafeArea()
        .background(WindowChrome(titlebarHeight: 44))
        .preferredColorScheme(.dark)
        .animation(.easeInOut(duration: 0.2), value: step)
    }

    // MARK: - Left visual

    @ViewBuilder private var visual: some View {
        switch step {
        case 0:
            VStack(spacing: 14) {
                pair("music", Color(hex: 0x1DB954), "headphones")
                pair("video", Color(hex: 0x2D8CFF), "monitor")
                pair("piano", Theme.dangerFill, "audio-lines")
            }
        case 1:
            ZStack {
                Circle().strokeBorder(Theme.accent.opacity(0.13)).frame(width: 150, height: 150)
                Circle().strokeBorder(Theme.accent.opacity(0.27)).frame(width: 110, height: 110)
                Circle().fill(Theme.accent).frame(width: 72, height: 72)
                    .overlay(Icon("shield-check", size: 30, color: Theme.accentInk))
            }
        default:
            ZStack {
                Circle().strokeBorder(Theme.accent.opacity(0.13)).frame(width: 150, height: 150)
                Circle().strokeBorder(Theme.accent.opacity(0.27)).frame(width: 110, height: 110)
                Circle().fill(Theme.accent).frame(width: 72, height: 72)
                    .overlay(Icon("check", size: 30, color: Theme.accentInk))
            }
        }
    }

    private func pair(_ app: String, _ color: Color, _ device: String) -> some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 10).fill(color).frame(width: 40, height: 40)
                .overlay(Icon(app, size: 20, color: .white))
            RoundedRectangle(cornerRadius: 1).fill(Theme.accent.opacity(0.53)).frame(width: 56, height: 2)
            RoundedRectangle(cornerRadius: 10).fill(Theme.surface2).frame(width: 40, height: 40)
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.border))
                .overlay(Icon(device, size: 18, color: Theme.accent))
        }
    }

    // MARK: - Steps

    private var steps: some View {
        HStack(spacing: 6) {
            ForEach(0..<3) { index in
                RoundedRectangle(cornerRadius: 3).fill(index <= step ? Theme.accent : Theme.track)
                    .frame(width: index == step ? 22 : 8, height: 6)
            }
            Text("Шаг \(step + 1) из 3").font(.ui(11)).foregroundStyle(Theme.text3).padding(.leading, 6)
        }
    }

    private func header(_ title: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(title).font(.ui(24, .semibold)).foregroundStyle(Theme.text)
            Text(body).font(.ui(13)).foregroundStyle(Theme.text2).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 18) {
            header("Добро пожаловать в Soundflow", "Управляйте громкостью каждого приложения отдельно и отправляйте звук на любое устройство.")
            VStack(alignment: .leading, spacing: 10) {
                feature("sliders-horizontal", "Своя громкость для каждого приложения")
                feature("route", "Свой выход: наушники, колонки, монитор")
                feature("layers", "Профили и автопереключение устройств")
            }
            Spacer()
            HStack {
                Spacer()
                nextButton("Начать") { step = 1 }
            }
        }
    }

    private func feature(_ icon: String, _ text: String) -> some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 8).fill(Theme.surface2).frame(width: 30, height: 30)
                .overlay(Icon(icon, size: 15, color: Theme.accent))
            Text(text).font(.ui(13)).foregroundStyle(Theme.text)
        }
    }

    private var permission: some View {
        let state = model.engine.permission
        return VStack(alignment: .leading, spacing: 18) {
            header("Разрешите доступ к звуку",
                   "macOS попросит разрешение «Запись системного звука». Soundflow не записывает и не передаёт звук — только перенаправляет его на выбранные устройства.")
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    RoundedRectangle(cornerRadius: 9).fill((state == .authorized ? Theme.success : Theme.warning).opacity(0.13)).frame(width: 34, height: 34)
                        .overlay(Icon("audio-lines", size: 16, color: state == .authorized ? Theme.success : Theme.warning))
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Запись системного звука").font(.ui(12, .medium)).foregroundStyle(Theme.text)
                        Text(state == .authorized ? "Разрешено" : state == .denied ? "Запрещено — включите в Настройках" : "Ожидает разрешения")
                            .font(.ui(11)).foregroundStyle(state == .authorized ? Theme.success : Theme.warning)
                    }
                    Spacer()
                    Button(action: PermissionService.openPrivacySettings) {
                        HStack(spacing: 4) {
                            Text("Настройки").font(.ui(12)).foregroundStyle(Theme.text2)
                            Icon("external-link", size: 12, color: Theme.text2)
                        }
                    }
                    .buttonStyle(.plain)
                }
                .padding(14)
                .card(radius: 12)
                HStack(spacing: 6) {
                    Icon("lock", size: 12, color: Theme.text3)
                    Text("Всё работает локально, без интернета").font(.ui(11)).foregroundStyle(Theme.text3)
                }
            }
            Spacer()
            HStack {
                backButton
                Spacer()
                if state == .authorized {
                    nextButton("Далее") { step = 2 }
                } else {
                    nextButton(requesting ? "Ожидание…" : "Разрешить доступ") {
                        requesting = true
                        PermissionService.requestAudioCapture { _ in
                            Task { @MainActor in
                                requesting = false
                                model.engine.refreshPermission(force: true)
                                if model.engine.permission == .authorized { step = 2 }
                            }
                        }
                    }
                    .disabled(requesting)
                }
            }
        }
        .onAppear { model.engine.refreshPermission(force: true) }
    }

    private var finish: some View {
        let devices = model.devices.devices
        return VStack(alignment: .leading, spacing: 18) {
            header("Всё готово",
                   "Мы нашли \(countText(devices.count, "устройство", "устройства", "устройств")) вывода. Выберите основное — на него пойдёт звук новых приложений.")
            VStack(alignment: .leading, spacing: 10) {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 0) {
                        ForEach(Array(devices.enumerated()), id: \.element.uid) { index, device in
                            let selected = device.uid == model.devices.defaultOutputUID
                            Button { model.makeDefault(device.uid) } label: {
                                HStack(spacing: 10) {
                                    RadioDot(selected: selected)
                                    Icon(device.kind.icon, size: 14, color: selected ? Theme.accent : Theme.text2)
                                    Text(device.name).font(.ui(12)).foregroundStyle(selected ? Theme.text : Theme.text2)
                                    Spacer()
                                }
                                .padding(.vertical, 9).padding(.horizontal, 12)
                                .background(selected ? Theme.accent.opacity(0.06) : .clear)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .overlay(alignment: .top) { if index > 0 { Divider1() } }
                        }
                    }
                }
                .frame(maxHeight: 34 * 5)
                .fixedSize(horizontal: false, vertical: true)
                .card(radius: 12)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                HStack(spacing: 10) {
                    Text("Запускать при входе в систему").font(.ui(12)).foregroundStyle(Theme.text2)
                    Spacer()
                    SFSwitch(isOn: model.pref(\.launchAtLogin) { LoginItem.set($0) })
                }
            }
            Spacer()
            HStack {
                backButton
                Spacer()
                nextButton("Открыть Soundflow") {
                    model.config.prefs.onboardingDone = true
                    model.openMainWindow?()
                    dismissWindow(id: WindowID.onboarding)
                }
            }
        }
    }

    private var backButton: some View {
        Button { step -= 1 } label: {
            Text("Назад").font(.ui(13, .semibold)).foregroundStyle(Theme.text)
                .padding(.horizontal, 16).padding(.vertical, 9)
                .card(radius: 8, fill: Theme.surface2)
        }
        .buttonStyle(.plain)
    }

    private func nextButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(title).font(.ui(13, .semibold))
                Icon("arrow-right", size: 14, color: Theme.accentInk)
            }
            .foregroundStyle(Theme.accentInk)
            .padding(.horizontal, 16).padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.accent))
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.defaultAction)
    }
}
