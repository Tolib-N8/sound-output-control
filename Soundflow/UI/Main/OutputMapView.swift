import SwiftUI

/// Node-graph view: apps on the left, outputs on the right, wires between them.
struct OutputMapView: View {
    @Environment(AppModel.self) private var model
    @State private var zoom: CGFloat = 1
    @State private var autoLayout = true
    @State private var popoverApp: String?
    @State private var drag: DragState?
    @State private var mapWidth: CGFloat?

    struct DragState: Equatable {
        var bundleID: String
        var location: CGPoint
        var target: OutputRef?
        var additive: Bool
    }

    private static let palette: [Color] = [Theme.accent, Color(hex: 0x60A5FA), Color(hex: 0xA78BFA), Color(hex: 0xF87171),
                                           Color(hex: 0x34D399), Color(hex: 0xF472B6)]
    private let appNode = CGSize(width: 232, height: 60)
    private let deviceNode = CGSize(width: 280, height: 84)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header.padding(.horizontal, 32).padding(.top, 24)
            GeometryReader { proxy in
                let layout = makeLayout(width: proxy.size.width / zoom)
                ScrollView(.vertical, showsIndicators: true) {
                ZStack(alignment: .topLeading) {
                    wires(layout)
                    ForEach(layout.apps, id: \.app.id) { item in
                        appNodeView(item.app, color: layout.color(for: model.currentOutputs(item.app.bundleID).first))
                            .position(x: item.frame.midX, y: item.frame.midY)
                    }
                    ForEach(layout.outputs, id: \.ref) { item in
                        deviceNodeView(item, layout: layout)
                            .position(x: item.frame.midX, y: item.frame.midY)
                    }
                    if !layout.outputs.isEmpty {
                        addMultiButton
                            .position(x: layout.deviceX + deviceNode.width / 2, y: (layout.outputs.last?.frame.maxY ?? 0) + 38)
                    }
                    Text("ПРИЛОЖЕНИЯ").sectionLabelStyle().position(x: 40 + 45, y: 16)
                    Text("УСТРОЙСТВА ВЫВОДА").sectionLabelStyle().position(x: layout.deviceX + 72, y: 16)
                    if let drag { dragGhost(drag) }
                }
                .frame(width: proxy.size.width / zoom, height: max(proxy.size.height / zoom, layout.height), alignment: .topLeading)
                .coordinateSpace(name: "map")
                .scaleEffect(zoom, anchor: .topLeading)
                .frame(width: proxy.size.width, height: max(proxy.size.height, layout.height * zoom), alignment: .topLeading)
                }
                .scrollDisabled(drag != nil)
                .onAppear { mapWidth = proxy.size.width / zoom }
                .onChange(of: proxy.size.width / zoom) { _, width in mapWidth = width }
            }
            .padding(.top, 20)
            legend.padding(.horizontal, 40).padding(.bottom, 24)
        }
        .background(GridBackground())
        .background(Theme.bg)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Карта вывода").font(.ui(24, .semibold)).foregroundStyle(Theme.text)
                Text("Перетащите приложение на устройство, чтобы назначить выход. Нажмите на приложение, чтобы настроить звук.")
                    .font(.ui(13)).foregroundStyle(Theme.text2)
            }
            Spacer()
            HStack(spacing: 8) {
                Button { autoLayout.toggle() } label: {
                    HStack(spacing: 6) {
                        Icon("layout-grid", size: 14, color: autoLayout ? Theme.accent : Theme.text2)
                        Text("Авто-раскладка").font(.ui(12)).foregroundStyle(Theme.text2)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 7).card(radius: 8)
                }
                .buttonStyle(.sfPlain)
                .help("Сгруппировать приложения по устройствам, чтобы провода не пересекались")
                toolbarButton("minus") { zoom = max(0.6, zoom - 0.1) }
                Text("\(Int((zoom * 100).rounded()))%").font(.ui(11)).foregroundStyle(Theme.text2).frame(width: 35)
                toolbarButton("plus") { zoom = min(1.4, zoom + 0.1) }
            }
        }
    }

    private func toolbarButton(_ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Icon(icon, size: 14, color: Theme.text2).padding(.horizontal, 10).padding(.vertical, 7).card(radius: 8)
        }
        .buttonStyle(.sfPlain)
    }

    private var legend: some View {
        HStack(spacing: 20) {
            hint("Перетащить", "назначить выход")
            hint("Клик", "настроить звук")
            hint("⌥ + перетащить", "добавить ещё один выход")
            hint("Двойной клик", "открыть детали")
        }
    }

    private func hint(_ key: String, _ text: String) -> some View {
        HStack(spacing: 6) {
            Text(key).font(.ui(10, .medium)).foregroundStyle(Theme.text2)
                .padding(.horizontal, 6).padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 5).fill(Theme.surface2))
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Theme.border))
            Text(text).font(.ui(11)).foregroundStyle(Theme.text3)
        }
    }

    // MARK: - Layout

    struct OutputItem {
        let ref: OutputRef
        let frame: CGRect
        let color: Color
        let device: AudioDevice?
        let multi: MultiOutput?
    }

    struct Layout {
        var apps: [(app: AudioApp, frame: CGRect)]
        var outputs: [OutputItem]
        var deviceX: CGFloat
        var height: CGFloat

        func color(for uid: String?) -> Color {
            outputs.first { $0.ref == uid }?.color ?? Theme.text3
        }

        func output(at point: CGPoint) -> OutputItem? {
            outputs.first { $0.frame.insetBy(dx: -12, dy: -8).contains(point) }
        }
    }

    private func makeLayout(width: CGFloat) -> Layout {
        let deviceX = max(40 + appNode.width + 220, width - deviceNode.width - 40)
        var outputs: [OutputItem] = []
        var y: CGFloat = 32
        for (index, device) in model.visibleDevices.enumerated() {
            outputs.append(OutputItem(ref: device.uid, frame: CGRect(origin: CGPoint(x: deviceX, y: y), size: deviceNode),
                                      color: Self.palette[index % Self.palette.count], device: device, multi: nil))
            y += deviceNode.height + 16
        }
        for multi in model.config.multiOutputs {
            outputs.append(OutputItem(ref: multi.ref, frame: CGRect(origin: CGPoint(x: deviceX, y: y), size: deviceNode),
                                      color: Theme.warning, device: nil, multi: multi))
            y += deviceNode.height + 16
        }

        var apps = model.visibleApps
        if autoLayout {
            // Order apps by the position of their (first) output so wires don't cross.
            let order = Dictionary(uniqueKeysWithValues: outputs.enumerated().map { ($0.element.ref, $0.offset) })
            apps.sort { a, b in
                let ia = order[primaryRef(a.bundleID)] ?? .max, ib = order[primaryRef(b.bundleID)] ?? .max
                if ia != ib { return ia < ib }
                if a.isPlaying != b.isPlaying { return a.isPlaying }
                return a.name < b.name
            }
        }
        let appFrames = apps.enumerated().map { index, app in
            (app: app, frame: CGRect(origin: CGPoint(x: 40, y: 32 + CGFloat(index) * (appNode.height + 12)), size: appNode))
        }
        let height = max(y + 80, (appFrames.last?.frame.maxY ?? 0) + 40)
        return Layout(apps: appFrames, outputs: outputs, deviceX: deviceX, height: height)
    }

    private func primaryRef(_ bundleID: String) -> OutputRef {
        let rule = model.rule(bundleID)
        if let multi = rule.outputs.first(where: \.isMultiOutput) { return multi }
        return model.currentOutputs(bundleID).first ?? ""
    }

    /// Output refs an app is wired to: its multi-output, or each hardware device it plays on.
    private func targets(_ bundleID: String) -> [OutputRef] {
        let rule = model.rule(bundleID)
        let multis = rule.outputs.filter(\.isMultiOutput)
        let hardware = model.currentOutputs(bundleID).filter { uid in
            !multis.contains { model.config.multiOutput($0)?.deviceUIDs.contains(uid) == true }
        }
        return multis + hardware
    }

    // MARK: - Wires

    private func wires(_ layout: Layout) -> some View {
        Canvas { context, _ in
            for item in layout.apps {
                let rule = model.rule(item.app.bundleID)
                let start = CGPoint(x: item.frame.maxX, y: item.frame.midY)
                let selected = popoverApp == item.app.bundleID
                for ref in targets(item.app.bundleID) {
                    guard let output = layout.outputs.first(where: { $0.ref == ref }) else { continue }
                    let end = CGPoint(x: output.frame.minX, y: output.frame.midY)
                    var color = output.color
                    if drag?.bundleID == item.app.bundleID, drag?.additive == false { color = color.opacity(0.2) }
                    let style = StrokeStyle(lineWidth: selected ? 2.5 : 2, lineCap: .round,
                                            dash: rule.muted ? [4, 5] : rule.outputs.isEmpty ? [8, 4] : [])
                    context.stroke(curve(start, end), with: .color(rule.muted ? color.opacity(0.35) : color.opacity(selected ? 1 : 0.8)), style: style)
                }
            }
            if let drag {
                let from = layout.apps.first { $0.app.bundleID == drag.bundleID }?.frame
                if let from {
                    let start = CGPoint(x: from.maxX, y: from.midY)
                    let target = drag.target.flatMap { ref in layout.outputs.first { $0.ref == ref } }
                    let end = target.map { CGPoint(x: $0.frame.minX, y: $0.frame.midY) } ?? drag.location
                    context.stroke(curve(start, end), with: .color(target?.color ?? Theme.text2),
                                   style: StrokeStyle(lineWidth: 2.5, lineCap: .round, dash: target == nil ? [6, 5] : []))
                }
            }
            // Ports
            for item in layout.apps {
                let color = layout.color(for: targets(item.app.bundleID).first)
                port(&context, CGPoint(x: item.frame.maxX, y: item.frame.midY), color)
            }
            for output in layout.outputs {
                port(&context, CGPoint(x: output.frame.minX, y: output.frame.midY), output.color)
            }
        }
        .allowsHitTesting(false)
    }

    private func curve(_ start: CGPoint, _ end: CGPoint) -> Path {
        var path = Path()
        path.move(to: start)
        let dx = max(60, (end.x - start.x) * 0.45)
        path.addCurve(to: end, control1: CGPoint(x: start.x + dx, y: start.y), control2: CGPoint(x: end.x - dx, y: end.y))
        return path
    }

    private func port(_ context: inout GraphicsContext, _ center: CGPoint, _ color: Color) {
        let rect = CGRect(x: center.x - 5, y: center.y - 5, width: 10, height: 10)
        context.fill(Path(ellipseIn: rect), with: .color(color))
        context.stroke(Path(ellipseIn: rect), with: .color(Theme.bg), lineWidth: 2)
    }

    // MARK: - Nodes

    private func appNodeView(_ app: AudioApp, color: Color) -> some View {
        let rule = model.rule(app.bundleID)
        let selected = popoverApp == app.bundleID
        let dragging = drag?.bundleID == app.bundleID
        return HStack(spacing: 8) {
            Icon("grip-vertical", size: 14, color: Theme.text3)
            AppIconView(bundleID: app.bundleID, size: 32, dimmed: rule.muted)
            VStack(alignment: .leading, spacing: 3) {
                Text(app.name).font(.ui(13, .medium)).foregroundStyle(rule.muted ? Theme.text2 : Theme.text).lineLimit(1)
                Text(rule.muted ? "Без звука" : model.statusText(app).text).font(.ui(11)).foregroundStyle(Theme.text3).lineLimit(1)
            }
            Spacer(minLength: 0)
            Text(rule.muted ? "—" : percent(rule.volume)).font(.mono(12)).foregroundStyle(rule.muted ? Theme.text3 : Theme.text2)
        }
        .padding(.leading, 8).padding(.trailing, 14)
        .frame(width: appNode.width, height: appNode.height)
        .background(RoundedRectangle(cornerRadius: 12).fill(selected ? Theme.accent.opacity(0.06) : Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(selected ? Theme.accent : Theme.border))
        .opacity(dragging ? 0.5 : 1)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            popoverApp = nil
            model.mode = .list
            model.selection = .app(app.bundleID)
        }
        .onTapGesture { popoverApp = app.bundleID }
        .iconTapTrigger()
        .popover(isPresented: Binding(get: { popoverApp == app.bundleID }, set: { if !$0 { popoverApp = nil } }), arrowEdge: .trailing) {
            SoundPopover(app: app, colors: Dictionary(uniqueKeysWithValues: makeLayout(width: mapWidth ?? 1000).outputs.map { ($0.ref, $0.color) })) {
                popoverApp = nil
            }
        }
        .gesture(
            DragGesture(minimumDistance: 4, coordinateSpace: .named("map"))
                .onChanged { value in
                    let additive = NSEvent.modifierFlags.contains(.option)
                    drag = DragState(bundleID: app.bundleID, location: value.location,
                                     target: currentLayout?.output(at: value.location)?.ref, additive: additive)
                }
                .onEnded { value in
                    if let target = currentLayout?.output(at: value.location)?.ref {
                        model.assign(app.bundleID, to: target, additive: NSEvent.modifierFlags.contains(.option))
                    }
                    drag = nil
                }
        )
    }

    /// The layout at the current canvas width (used for hit-testing during drags).
    private var currentLayout: Layout? { mapWidth.map { makeLayout(width: $0) } }

    private func deviceNodeView(_ item: OutputItem, layout: Layout) -> some View {
        let isTarget = drag?.target == item.ref
        let count = item.multi.map { model.apps(onMulti: $0).count } ?? model.apps(on: item.ref).count
        let isDefault = item.ref == model.devices.defaultOutputUID
        let subtitle: String = {
            if let multi = item.multi { return multi.deviceUIDs.map { model.devices.device(uid: $0)?.shortName ?? model.name(of: $0) }.joined(separator: " + ") }
            guard let device = item.device else { return "" }
            return model.deviceSubtitle(device) + (isDefault ? " · осн." : "")
        }()
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 8).fill(item.color.opacity(0.13)).frame(width: 32, height: 32)
                    .overlay(Icon(item.device?.kind.icon ?? "git-merge", size: 16, color: item.color))
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.device?.name ?? item.multi?.name ?? "").font(.ui(13, .medium)).foregroundStyle(Theme.text).lineLimit(1)
                    Text(subtitle).font(.ui(11)).foregroundStyle(Theme.text3).lineLimit(1)
                }
                Spacer(minLength: 0)
                Text(isTarget && drag?.additive == false ? "\(count) + 1" : "\(count)")
                    .font(.mono(10)).foregroundStyle(isTarget ? Theme.accentInk : Theme.text2)
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Capsule().fill(isTarget ? Theme.accent : Theme.surface2))
            }
            if let device = item.device, device.volume != nil {
                let volume = Binding(get: { Double(model.devices.device(uid: device.uid)?.volume ?? 0) },
                                     set: { model.devices.setVolume(device.uid, Float($0)) })
                HStack(spacing: 8) {
                    Icon("volume-2", size: 13, color: Theme.text3)
                    SFSlider(value: volume, fill: Theme.text2)
                    Text(percent(volume.wrappedValue)).font(.mono(11)).foregroundStyle(Theme.text2).frame(width: 27, alignment: .trailing)
                }
            } else {
                Text(item.multi != nil ? "Мульти-выход" : "Громкость регулируется на устройстве")
                    .font(.ui(11)).foregroundStyle(Theme.text3)
            }
        }
        .padding(14)
        .frame(width: deviceNode.width, height: deviceNode.height)
        .background(RoundedRectangle(cornerRadius: 12).fill(isTarget ? item.color.opacity(0.08) : Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(isTarget ? item.color : (isDefault ? Theme.accent.opacity(0.4) : Theme.border),
                                                                 lineWidth: isTarget ? 1.5 : 1))
        .shadow(color: isTarget ? item.color.opacity(0.25) : .clear, radius: 16)
        .contentShape(Rectangle())
        .iconTapTrigger()
        .onTapGesture(count: 2) {
            if let multi = item.multi { model.selection = .multiOutput(multi.id) } else { model.selection = .device(item.ref) }
        }
    }

    private var addMultiButton: some View {
        Button {
            model.multiOutputDraft = MultiOutput(name: "Колонки + наушники", deviceUIDs: [])
        } label: {
            HStack(spacing: 8) {
                Icon("plus", size: 14, color: Theme.text2)
                Text("Создать мульти-выход").font(.ui(12)).foregroundStyle(Theme.text2)
            }
            .frame(width: deviceNode.width, height: 44)
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.white.opacity(0.13), style: StrokeStyle(lineWidth: 1, dash: [5, 4])))
            .contentShape(Rectangle())
        }
        .buttonStyle(.sfPlain)
    }

    private func dragGhost(_ drag: DragState) -> some View {
        let name = AppInfo.name(drag.bundleID)
        let targetName = drag.target.map(model.name(of:))
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                AppIconView(bundleID: drag.bundleID, size: 28)
                Text(name).font(.ui(13, .medium)).foregroundStyle(Theme.text)
                Text(percent(model.rule(drag.bundleID).volume)).font(.mono(12)).foregroundStyle(Theme.text2)
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 12).fill(Theme.surface2))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.accent))
            .shadow(color: .black.opacity(0.5), radius: 16, y: 10)
            if let targetName {
                HStack(spacing: 6) {
                    Icon("corner-down-right", size: 12, color: Theme.accentInk)
                    Text("Отпустите: \(name) → \(targetName)").font(.ui(11, .semibold)).foregroundStyle(Theme.accentInk)
                }
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 6).fill(Theme.accent))
            }
            HStack(spacing: 6) {
                KeyCap(label: "⌥")
                Text("удерживайте, чтобы добавить выход, а не заменить").font(.ui(11)).foregroundStyle(Theme.text3)
            }
        }
        .fixedSize()
        .position(x: drag.location.x + 110, y: drag.location.y + 30)
        .allowsHitTesting(false)
    }
}

/// Faint grid behind the map.
struct GridBackground: View {
    var body: some View {
        Canvas { context, size in
            var path = Path()
            stride(from: 0, through: size.width, by: 32).forEach { x in
                path.move(to: CGPoint(x: x, y: 0)); path.addLine(to: CGPoint(x: x, y: size.height))
            }
            stride(from: 0, through: size.height, by: 32).forEach { y in
                path.move(to: CGPoint(x: 0, y: y)); path.addLine(to: CGPoint(x: size.width, y: y))
            }
            context.stroke(path, with: .color(.white.opacity(0.04)), lineWidth: 1)
        }
    }
}

/// Click-popover on a map node: volume, balance and outputs for one app.
struct SoundPopover: View {
    @Environment(AppModel.self) private var model
    let app: AudioApp
    let colors: [OutputRef: Color]
    let dismiss: () -> Void

    var body: some View {
        let rule = model.rule(app.bundleID)
        let volume = Binding(get: { model.rule(app.bundleID).volume }, set: { model.setVolume(app.bundleID, $0) })
        let balance = Binding(get: { model.rule(app.bundleID).balance }, set: { model.setBalance(app.bundleID, $0) })
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                AppIconView(bundleID: app.bundleID, size: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(app.name).font(.ui(14, .semibold)).foregroundStyle(Theme.text)
                    Text(model.statusText(app).text).font(.ui(11)).foregroundStyle(Theme.text3)
                }
                Spacer()
                Button(action: dismiss) { Icon("x", size: 14, color: Theme.text3) }.buttonStyle(.sfPlain)
            }
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .bottom) {
                    HStack(alignment: .lastTextBaseline, spacing: 3) {
                        Text(rule.muted ? "—" : percent(rule.volume)).font(.mono(34, .medium)).foregroundStyle(Theme.text)
                        Text("%").font(.mono(14)).foregroundStyle(Theme.text3)
                    }
                    Spacer()
                    HStack(spacing: 6) {
                        quick(rule.muted ? "volume-2" : "volume-x", help: rule.muted ? "Включить звук" : "Выключить звук") { model.toggleMute(app.bundleID) }
                        quick("headphones", help: "Только на основной выход") { model.assign(app.bundleID, to: nil) }
                        quick("rotate-ccw", help: "Сбросить") { model.resetRule(app.bundleID) }
                    }
                }
                SFSlider(value: volume, showsFill: !rule.muted)
                LiveLevel(level: { model.engine.level(app.bundleID) }) { level in
                    SegmentStrip(level: model.status(app.bundleID)?.tapped == true ? meterFraction(level) : 0)
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("БАЛАНС").font(.ui(10, .semibold)).tracking(0.8).foregroundStyle(Theme.text3)
                    Spacer()
                    Text(abs(rule.balance) < 0.01 ? "Центр" : (rule.balance < 0 ? "L " : "R ") + "\(Int(abs(rule.balance) * 100))")
                        .font(.mono(10)).foregroundStyle(Theme.text2)
                }
                BalanceSlider(value: balance)
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("ВЫХОД").font(.ui(10, .semibold)).tracking(0.8).foregroundStyle(Theme.text3)
                    Spacer()
                    Text("⌥ — несколько").font(.ui(10)).foregroundStyle(Theme.text3)
                }
                VStack(spacing: 2) {
                    ForEach(model.outputOptions.filter(\.connected)) { option in
                        let checked = rule.outputs.contains(option.ref) || (rule.outputs.isEmpty && model.currentOutputs(app.bundleID).contains(option.ref) && !option.isMulti)
                        Button {
                            model.assign(app.bundleID, to: option.ref, additive: NSEvent.modifierFlags.contains(.option))
                        } label: {
                            HStack(spacing: 10) {
                                Circle().fill(colors[option.ref] ?? Theme.text3).frame(width: 8, height: 8)
                                Text(option.name).font(.ui(12)).foregroundStyle(checked ? Theme.text : Theme.text2)
                                Spacer()
                                if checked { Icon("check", size: 14, color: Theme.accent) }
                            }
                            .padding(.horizontal, 8).padding(.vertical, 7)
                            .background(RoundedRectangle(cornerRadius: 7).fill(checked ? Theme.accent.opacity(0.08) : .clear))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.sfPlain)
                    }
                }
            }
            HStack {
                Button("Сбросить") { model.resetRule(app.bundleID) }.buttonStyle(.sfPlain).font(.ui(12)).foregroundStyle(Theme.text3)
                Spacer()
                Button {
                    dismiss()
                    model.mode = .list
                    model.selection = .app(app.bundleID)
                } label: {
                    HStack(spacing: 6) {
                        Text("Все настройки").font(.ui(12, .medium))
                        Icon("arrow-right", size: 13, color: Theme.accent)
                    }
                    .foregroundStyle(Theme.accent)
                }
                .buttonStyle(.sfPlain)
            }
            .padding(.top, 12)
            .overlay(alignment: .top) { Divider1() }
        }
        .padding(16)
        .frame(width: 304)
        .background(Color(hex: 0x1D2026))
    }

    private func quick(_ icon: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            RoundedRectangle(cornerRadius: 8).fill(Theme.surface2).frame(width: 30, height: 30)
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.border))
                .overlay(Icon(icon, size: 14, color: Theme.text2))
        }
        .buttonStyle(.sfPlain)
        .help(help)
    }
}

/// Thin 30-segment level strip.
struct SegmentStrip: View {
    let level: Double
    var segments = 30

    var body: some View {
        GeometryReader { proxy in
            let width = (proxy.size.width - CGFloat(segments - 1) * 2) / CGFloat(segments)
            HStack(spacing: 2) {
                ForEach(0..<segments, id: \.self) { index in
                    let position = Double(index) / Double(segments)
                    RoundedRectangle(cornerRadius: 1)
                        .fill(position < level ? (position > 0.62 ? Color(hex: 0xFACC15) : Theme.accent) : Theme.track)
                        .frame(width: width, height: 4)
                }
            }
        }
        .frame(height: 4)
    }
}
