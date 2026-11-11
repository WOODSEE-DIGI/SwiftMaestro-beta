import SwiftUI

// MARK: - Story Game Player View
//
// Native DOS/CRT play view for Game Studio projects. Renders the current scene,
// stats, and choices with a retro terminal aesthetic.

struct StoryGamePlayerView: View {
    let project: StoryGameProject
    let projectURL: URL?
    var onClose: (() -> Void)?

    @State private var engine = StoryGameEngine()
    @State private var theme: CRTTheme = .green
    @State private var showScanlines = true
    @State private var typewriterKey = UUID()

    private var foregroundColor: Color { theme.foregroundColor }
    private var backgroundColor: Color { theme.backgroundColor }
    private var dimColor: Color { foregroundColor.opacity(0.6) }

    var body: some View {
        ZStack {
            backgroundColor
                .ignoresSafeArea()

            VStack(spacing: 0) {
                titleBar
                Divider().background(foregroundColor.opacity(0.25))
                statsBar
                Divider().background(foregroundColor.opacity(0.25))

                ScrollViewReader { proxy in
                    ScrollView(.vertical) {
                        VStack(alignment: .leading, spacing: 20) {
                            sceneHeader

                            if let scene = engine.currentScene {
                                TypewriterText(
                                    text: scene.narrative,
                                    color: foregroundColor,
                                    key: typewriterKey
                                )
                                .id("narrative")

                                if !scene.symbols.isEmpty {
                                    HStack(spacing: 8) {
                                        ForEach(scene.symbols, id: \.self) { symbol in
                                            Text(symbol)
                                                .font(.title2)
                                        }
                                    }
                                }
                            }

                            if engine.isGameOver {
                                gameOverView
                            } else if let scene = engine.currentScene {
                                choicesView(for: scene)
                            }

                            Spacer(minLength: 40)
                        }
                        .padding(24)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .onChange(of: engine.currentSceneID) { _ in
                        typewriterKey = UUID()
                        withAnimation {
                            proxy.scrollTo("narrative", anchor: .top)
                        }
                    }
                }
            }

            if showScanlines {
                CRTScanlineOverlay()
                    .allowsHitTesting(false)
                    .ignoresSafeArea()
            }
        }
        .foregroundStyle(foregroundColor)
        .font(.system(.body, design: .monospaced))
        .onAppear {
            engine.start(with: project)
        }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Close") { onClose?() }
            }
            ToolbarItem(placement: .primaryAction) {
                HStack(spacing: 12) {
                    Picker("Theme", selection: $theme) {
                        ForEach(CRTTheme.allCases) { t in
                            Text(t.label).tag(t)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 180)

                    Toggle("Scanlines", isOn: $showScanlines)
                        .toggleStyle(.checkbox)

                    Button("Restart") { engine.restart() }
                }
            }
        }
    }

    // MARK: - Title bar

    private var titleBar: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(project.metadata.title)
                    .font(.system(.headline, design: .monospaced))
                    .lineLimit(1)

                if let subtitle = project.metadata.subtitle {
                    Text(subtitle)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(dimColor)
                        .lineLimit(1)
                }
            }

            Spacer()

            if let index = engine.currentSceneIndex, let count = engine.project?.scenes.count {
                Text("SCENE \(String(index + 1).padding(toLength: 2, withPad: "0", startingAt: 0)) / \(String(count).padding(toLength: 2, withPad: "0", startingAt: 0))")
                    .font(.system(.caption, design: .monospaced))
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(foregroundColor.opacity(0.06))
    }

    // MARK: - Stats bar

    private var statsBar: some View {
        HStack(spacing: 16) {
            ForEach(sortedStatIDs, id: \.self) { id in
                if let definition = project.statDefinitions[id] {
                    statCell(definition: definition)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }

    private var sortedStatIDs: [String] {
        project.statDefinitions.keys.sorted()
    }

    private func statCell(definition: StatDefinition) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(definition.name.uppercased())
                    .font(.system(.caption2, design: .monospaced))
                Spacer()
                Text("\(engine.value(for: definition.id))")
                    .font(.system(.caption2, design: .monospaced).bold())
            }
            .foregroundStyle(dimColor)

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Rectangle()
                        .fill(foregroundColor.opacity(0.12))
                    Rectangle()
                        .fill(definition.isDanger ? Color.red.opacity(0.85) : foregroundColor)
                        .frame(width: geo.size.width * engine.normalizedValue(for: definition.id))
                }
            }
            .frame(height: 6)
            .clipShape(RoundedRectangle(cornerRadius: 3))
        }
        .frame(minWidth: 90)
    }

    // MARK: - Scene header

    private var sceneHeader: some View {
        Group {
            if let scene = engine.currentScene {
                HStack(alignment: .top, spacing: 16) {
                    if let characterID = scene.primaryCharacterID ?? scene.characterIDs.first,
                       let character = project.characters[characterID],
                       let portraitImage = portraitImage(for: character) {
                        portraitImage
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 96, height: 96)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(foregroundColor.opacity(0.35), lineWidth: 1)
                            )
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text(scene.title.uppercased())
                            .font(.system(.title3, design: .monospaced).bold())

                        HStack(spacing: 12) {
                            if let date = scene.displayDate ?? scene.date, !date.isEmpty {
                                Label(date, systemImage: "calendar")
                            }

                            if let locationID = scene.locationID,
                               let location = project.locations[locationID] {
                                Label(location.name, systemImage: "mappin")
                            }

                            if let characterID = scene.primaryCharacterID ?? scene.characterIDs.first,
                               let character = project.characters[characterID] {
                                Label(character.name, systemImage: "person")
                            }
                        }
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(dimColor)
                    }
                }
            }
        }
    }

    private func portraitImage(for character: StoryCharacter) -> Image? {
        guard let filename = character.portraitFilename,
              let baseURL = projectURL else { return nil }
        let url = baseURL
            .appendingPathComponent("portraits", isDirectory: true)
            .appendingPathComponent(filename)
        guard FileManager.default.fileExists(atPath: url.path),
              let nsImage = NSImage(contentsOf: url) else { return nil }
        return Image(nsImage: nsImage)
    }

    // MARK: - Choices

    private func choicesView(for scene: StoryScene) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("> SELECT AN OPTION:")
                .font(.system(.caption, design: .monospaced).bold())
                .foregroundStyle(dimColor)
                .padding(.bottom, 4)

            ForEach(Array(scene.choices.enumerated()), id: \.offset) { index, choice in
                Button {
                    engine.choose(choice.id)
                } label: {
                    HStack(alignment: .top, spacing: 12) {
                        Text("\(index + 1)")
                            .font(.system(.caption, design: .monospaced).bold())
                            .frame(width: 24, alignment: .center)
                            .padding(.vertical, 2)
                            .background(foregroundColor.opacity(0.15))
                            .clipShape(RoundedRectangle(cornerRadius: 4))

                        Text(choice.text.isEmpty ? "(continue)" : choice.text)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        if choice.isHistorical {
                            Text("HISTORICAL")
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(dimColor)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 4)
                                        .stroke(foregroundColor.opacity(0.35), lineWidth: 1)
                                )
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .background(foregroundColor.opacity(0.06))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(foregroundColor.opacity(0.35), lineWidth: 1)
                )
                .cornerRadius(6)
            }
        }
    }

    // MARK: - Game over

    private var gameOverView: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("[ END OF TRANSMISSION ]")
                .font(.system(.headline, design: .monospaced).bold())

            if let reason = engine.endReason, !reason.isEmpty {
                Text(reason)
                    .foregroundStyle(dimColor)
            }

            Button("Restart") { engine.restart() }
                .buttonStyle(.borderedProminent)
                .tint(foregroundColor.opacity(0.8))
        }
        .padding(.top, 20)
    }
}

// MARK: - CRT Theme

private enum CRTTheme: String, CaseIterable, Identifiable {
    case green, amber, cyan

    var id: String { rawValue }

    var label: String {
        switch self {
        case .green: return "Green"
        case .amber: return "Amber"
        case .cyan: return "Cyan"
        }
    }

    var foregroundColor: Color {
        switch self {
        case .green:
            return Color(red: 0.45, green: 1.0, blue: 0.45)
        case .amber:
            return Color(red: 1.0, green: 0.72, blue: 0.2)
        case .cyan:
            return Color(red: 0.35, green: 0.9, blue: 1.0)
        }
    }

    var backgroundColor: Color {
        switch self {
        case .green:
            return Color(red: 0.04, green: 0.06, blue: 0.04)
        case .amber:
            return Color(red: 0.08, green: 0.05, blue: 0.02)
        case .cyan:
            return Color(red: 0.02, green: 0.05, blue: 0.07)
        }
    }
}

// MARK: - Typewriter text

private struct TypewriterText: View {
    let text: String
    let color: Color
    let key: UUID

    @State private var displayed: String = ""
    @State private var timer: Timer?

    var body: some View {
        Text(displayed)
            .foregroundStyle(color)
            .onAppear(perform: start)
            .onChange(of: key) { _ in start() }
            .onDisappear {
                timer?.invalidate()
                timer = nil
            }
    }

    private func start() {
        timer?.invalidate()
        displayed = ""
        guard !text.isEmpty else { return }

        var index = text.startIndex
        timer = Timer.scheduledTimer(withTimeInterval: 0.018, repeats: true) { t in
            if index < text.endIndex {
                displayed.append(text[index])
                text.formIndex(after: &index)
            } else {
                t.invalidate()
                timer = nil
            }
        }
    }
}

// MARK: - Scanlines

private struct CRTScanlineOverlay: View {
    var body: some View {
        Canvas { context, size in
            var y: CGFloat = 1
            while y < size.height {
                let line = Path { path in
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: size.width, y: y))
                }
                context.stroke(line, with: .color(Color.black.opacity(0.25)), lineWidth: 1)
                y += 3
            }
        }
        .blendMode(.multiply)
    }
}
