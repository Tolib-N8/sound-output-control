import SwiftUI

enum SettingsTab: String, CaseIterable, Identifiable {
    case general, devices, hotkeys, profiles, driver, about
    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "Основные"
        case .devices: "Устройства"
        case .hotkeys: "Горячие клавиши"
        case .profiles: "Профили"
        case .driver: "Аудиодрайвер"
        case .about: "О программе"
        }
    }

    var icon: String {
        switch self {
        case .general: "settings-2"
        case .devices: "speaker"
        case .hotkeys: "keyboard"
        case .profiles: "layers"
        case .driver: "cpu"
        case .about: "info"
        }
    }
}

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        @Bindable var model = model
        let tab = model.settingsTab
        VStack(spacing: 0) {
            Text("Настройки").font(.ui(13, .semibold)).foregroundStyle(Theme.text)
                .frame(maxWidth: .infinity).frame(height: 44)
                .background(Theme.surface)
                .hairline(.bottom)
            HStack(spacing: 0) {
                VStack(spacing: 2) {
                    ForEach(SettingsTab.allCases) { item in
                        let selected = item == tab
                        Button { model.settingsTab = item } label: {
                            HStack(spacing: 10) {
                                Icon(item.icon, size: 15, color: selected ? Theme.accent : Theme.text2)
                                Text(item.title).font(.ui(13, selected ? .medium : .regular)).foregroundStyle(selected ? Theme.text : Theme.text2)
                                Spacer(minLength: 0)
                            }
                            .padding(.vertical, 8).padding(.horizontal, 10)
                            .background(RoundedRectangle(cornerRadius: 8).fill(selected ? Theme.surface2 : .clear))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    Spacer()
                }
                .padding(.vertical, 16).padding(.horizontal, 12)
                .frame(width: 210)
                .frame(maxHeight: .infinity)
                .background(Theme.surface)
                .hairline(.trailing)

                ScrollView(.vertical, showsIndicators: false) {
                    Group {
                        switch tab {
                        case .general: GeneralSettings()
                        case .devices: DeviceSettingsPage()
                        case .hotkeys: HotkeySettings()
                        case .profiles: ProfileSettings()
                        case .driver: DriverSettings()
                        case .about: AboutSettings()
                        }
                    }
                    .padding(28)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: 960)
        .frame(minHeight: 628, maxHeight: .infinity)
        .background(Theme.bg)
        .ignoresSafeArea()
        .background(WindowChrome(titlebarHeight: 44))
        .preferredColorScheme(.dark)
    }
}

// MARK: - Building blocks

/// Two equal columns as in the design.
struct SettingsColumns<Left: View, Right: View>: View {
    @ViewBuilder var left: Left
    @ViewBuilder var right: Right

    var body: some View {
        HStack(alignment: .top, spacing: 24) {
            VStack(alignment: .leading, spacing: 22) { left }.frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .leading, spacing: 22) { right }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct SettingsGroup<Content: View>: View {
    let title: String
    var note: String?
    var trailing: AnyView?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title).sectionLabelStyle()
                Spacer()
                if let trailing { trailing }
            }
            VStack(spacing: 0) {
                Group { content }
            }
            .card(radius: 12)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            if let note {
                Text(note).font(.ui(11)).foregroundStyle(Theme.text3).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// A settings row: title (+ subtitle) and a trailing control, separated from the previous row by a hairline.
struct SettingsRow<Trailing: View>: View {
    let title: String
    var subtitle: String?
    var first = false
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.ui(12, .medium)).foregroundStyle(Theme.text)
                if let subtitle { Text(subtitle).font(.ui(11)).foregroundStyle(Theme.text3).fixedSize(horizontal: false, vertical: true) }
            }
            Spacer(minLength: 0)
            trailing
        }
        .padding(.vertical, 12).padding(.horizontal, 16)
        .overlay(alignment: .top) { if !first { Divider1() } }
    }
}

struct SettingsToggle: View {
    let title: String
    var subtitle: String?
    var first = false
    @Binding var isOn: Bool

    var body: some View {
        SettingsRow(title: title, subtitle: subtitle, first: first) { SFSwitch(isOn: $isOn) }
    }
}

/// Select-styled menu used in settings rows.
struct SettingsSelect<Content: View>: View {
    var icon: String?
    let text: String
    var width: CGFloat = 140
    @ViewBuilder var content: Content

    var body: some View {
        Menu { content } label: {
            HStack(spacing: 8) {
                if let icon { Icon(icon, size: 14, color: Theme.text2) }
                Text(text).font(.ui(12)).foregroundStyle(Theme.text).lineLimit(1)
                Spacer(minLength: 0)
                Icon("chevrons-up-down", size: 12, color: Theme.text3)
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .frame(width: width)
            .card(radius: 8, fill: Theme.surface2)
            .contentShape(Rectangle())
        }
        .menuStyle(.button).buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}

extension AppModel {
    /// Binding into preferences that saves and re-reconciles.
    func pref<T>(_ keyPath: WritableKeyPath<Preferences, T>, onChange: ((T) -> Void)? = nil) -> Binding<T> {
        Binding(get: { self.config.prefs[keyPath: keyPath] },
                set: { value in
                    self.config.prefs[keyPath: keyPath] = value
                    onChange?(value)
                    self.reconcile()
                })
    }
}
