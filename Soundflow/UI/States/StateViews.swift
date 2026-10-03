import SwiftUI

private struct StateCard<Actions: View>: View {
    let icon: String
    var tint: Color?
    let title: String
    let message: String
    @ViewBuilder var actions: Actions

    var body: some View {
        VStack(spacing: 12) {
            Circle()
                .fill(tint?.opacity(0.094) ?? Theme.surface2)
                .overlay(Circle().strokeBorder(tint?.opacity(0.27) ?? Theme.border))
                .frame(width: 64, height: 64)
                .overlay(Icon(icon, size: 26, color: tint ?? Theme.text3))
            Text(title).font(.ui(15, .semibold)).foregroundStyle(Theme.text)
            Text(message).font(.ui(12)).foregroundStyle(Theme.text2).multilineTextAlignment(.center)
                .frame(maxWidth: 320)
                .fixedSize(horizontal: false, vertical: true)
            actions
        }
        .padding(24)
        .frame(maxWidth: .infinity, minHeight: 300)
        .card(radius: 12)
    }
}

struct EmptyAppsState: View {
    let filtered: Bool
    let showAll: () -> Void

    var body: some View {
        StateCard(icon: "volume-off", title: filtered ? "Ничего не найдено" : "Сейчас ничего не играет",
                  message: "Приложения появятся здесь, как только начнут воспроизводить звук.") {
            if filtered {
                Button(action: showAll) { IconLabel(icon: "list", title: "Показать все приложения", color: Theme.text2) }
                    .buttonStyle(.sfSecondary)
            }
        }
    }
}

struct NoPermissionState: View {
    var body: some View {
        StateCard(icon: "shield-alert", tint: Theme.warning, title: "Нет доступа к звуку приложений",
                  message: "Разрешите «Запись системного звука» в Настройках → Конфиденциальность и безопасность.") {
            Button(action: PermissionService.openPrivacySettings) {
                HStack(spacing: 6) {
                    Icon("external-link", size: 13, color: Color(hex: 0x1F1803))
                    Text("Открыть Системные настройки").font(.ui(12, .semibold)).foregroundStyle(Color(hex: 0x1F1803))
                }
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.warning))
            }
            .buttonStyle(.sfPlain)
        }
        .frame(minHeight: 0)
    }
}

struct DriverErrorBanner: View {
    @Environment(AppModel.self) private var model
    @State private var showLog = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            RoundedRectangle(cornerRadius: 8).fill(Theme.dangerFill.opacity(0.15)).frame(width: 30, height: 30)
                .overlay(Icon("triangle-alert", size: 15, color: Theme.danger))
            VStack(alignment: .leading, spacing: 4) {
                Text("Аудиодрайвер не отвечает").font(.ui(12, .semibold)).foregroundStyle(Theme.text)
                Text("Звук идёт напрямую через macOS — громкость и выходы приложений временно не применяются.")
                    .font(.ui(11)).foregroundStyle(Theme.text2).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button { model.engine.restart() } label: {
                        HStack(spacing: 6) {
                            Icon("rotate-ccw", size: 13, color: .white)
                            Text("Перезапустить драйвер").font(.ui(12, .semibold)).foregroundStyle(.white)
                        }
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.dangerFill))
                    }
                    .buttonStyle(.sfPlain)
                    Button { showLog = true } label: { IconLabel(icon: "file-text", title: "Журнал", color: Theme.text2) }
                        .buttonStyle(.sfSecondary)
                }
                .padding(.top, 6)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.dangerFill.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.dangerFill.opacity(0.33)))
        .popover(isPresented: $showLog) { EngineLogView() }
    }
}

/// Recent errors per app from the engine.
struct EngineLogView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let errors = model.engine.statuses.compactMap { key, value in value.error.map { (key, $0) } }
        VStack(alignment: .leading, spacing: 10) {
            Text("Журнал аудиодрайвера").font(.ui(13, .semibold)).foregroundStyle(Theme.text)
            if errors.isEmpty {
                Text("Ошибок нет. Сбоев за сеанс: \(model.engine.stats.failures)").font(.ui(12)).foregroundStyle(Theme.text2)
            }
            ForEach(errors, id: \.0) { bundleID, error in
                VStack(alignment: .leading, spacing: 2) {
                    Text(AppInfo.name(bundleID)).font(.ui(12, .medium)).foregroundStyle(Theme.text)
                    Text(error).font(.mono(11)).foregroundStyle(Theme.text2).textSelection(.enabled)
                }
            }
        }
        .padding(16)
        .frame(width: 360, alignment: .leading)
        .background(Theme.surface)
    }
}
