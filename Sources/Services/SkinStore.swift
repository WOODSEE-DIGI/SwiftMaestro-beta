import SwiftUI
import Foundation

/// Loads and applies color skins. Built-in skins ship in code; users can also save,
/// import, and export custom skins as JSON files in the app-support skins directory.
@Observable
@MainActor
final class SkinStore {

    /// Currently selected skin identifier. `nil` or "default" means the user is on
    /// the system default / manually tweaked colors.
    var currentSkinID: String? {
        didSet { UserDefaults.standard.set(currentSkinID, forKey: Self.currentSkinIDKey) }
    }

    /// The master theme mode — ONE choice, so the appearance picker and the
    /// skin picker can never fight:
    ///
    /// - **OFF (System mode):** the System/Light/Dark segmented control is
    ///   active and the theme is System Default (plus any per-group overrides).
    /// - **ON (Skin mode):** the segmented control is disabled and the user
    ///   picks one skin from the combined list; each skin carries its own
    ///   appearance with it, applied atomically.
    var skinModeEnabled: Bool {
        didSet {
            guard oldValue != skinModeEnabled else { return }
            UserDefaults.standard.set(skinModeEnabled, forKey: Self.skinModeEnabledKey)
            if skinModeEnabled {
                // Entering Skin mode: re-assert the selected skin's colors and
                // appearance atomically (no-op if it's System Default).
                if let current = currentSkin, !current.isSystemDefault {
                    applySkin(current)
                }
            } else {
                // Back to System mode: clean System Default slate, keeping the
                // user's explicit Light/Dark choice. (No snapshot/restore —
                // skins write into the same override storage, so "System-mode
                // colors" can't be told apart from skin colors; restoring a
                // contaminated snapshot re-applied skin hexes as user
                // overrides and leaked skins into System mode.)
                let mode = theme.appearance
                applyDefault()
                theme.appearance = mode
            }
        }
    }

    /// All available skins: built-ins first, then user skins sorted by name.
    private(set) var skins: [Skin] = []

    /// The theme store that receives the color overrides.
    private let theme: ThemeStore

    private static let currentSkinIDKey = "theme.skinStore.currentSkinID"
    private static let skinModeEnabledKey = "theme.skinStore.skinModeEnabled"
    private static let skinsDirName = "skins"

    init(theme: ThemeStore) {
        self.theme = theme
        let persistedID = UserDefaults.standard.string(forKey: Self.currentSkinIDKey)
        self.currentSkinID = persistedID
        // If the key was never written, infer from the persisted selection:
        // anyone on a real skin is in Skin mode; System Default means System mode.
        self.skinModeEnabled = (UserDefaults.standard.object(forKey: Self.skinModeEnabledKey) as? Bool)
            ?? (persistedID != nil && persistedID != Skin.default.id)
        reload()
    }

    /// The currently active skin, if any.
    var currentSkin: Skin? {
        skins.first { $0.id == currentSkinID }
    }

    /// Is the current selection a built-in skin?
    var isCurrentSkinBuiltIn: Bool {
        currentSkin?.isBuiltIn == true
    }

    /// Apply a skin to the app. Pass `nil` or the default skin to reset to system
    /// colors (clearing all overrides).
    func applySkin(_ skin: Skin?) {
        currentSkinID = skin?.id

        // Clear any existing overrides first so a skin only applies the colors it
        // explicitly defines.
        theme.resetColors()

        guard let skin else { return }

        // A skin with an explicit appearance takes the mode with it (picking
        // Matrix Dark means dark mode); System Default leaves the user's
        // Light/Dark choice untouched.
        if skin.appearance != .system {
            theme.appearance = skin.appearance
        }

        applySkinColors(skin)
    }

    /// Apply just a skin's color values — no override reset, no selection
    /// change, no appearance change. Used to restore the System-mode snapshot
    /// when leaving Skin mode.
    private func applySkinColors(_ skin: Skin) {
        if let hex = skin.accent, let color = Color(hex: hex) {
            theme.setAccent(color)
        }
        if let hex = skin.userBubble, let color = Color(hex: hex) {
            theme.setUserBubble(color)
        }
        if let hex = skin.userBubbleText, let color = Color(hex: hex) {
            theme.setUserBubbleText(color)
        }
        if let hex = skin.chatBackground, let color = Color(hex: hex) {
            theme.setChatBackground(color)
        }
        if let hex = skin.chatText, let color = Color(hex: hex) {
            theme.setChatText(color)
        }
        if let hex = skin.chatSecondaryText, let color = Color(hex: hex) {
            theme.setChatSecondaryText(color)
        }
        if let hex = skin.sidebarBackground, let color = Color(hex: hex) {
            theme.setSidebar(color)
        }
        if let hex = skin.sidebarText, let color = Color(hex: hex) {
            theme.setSidebarText(color)
        }
        if let hex = skin.plansPanel, let color = Color(hex: hex) {
            theme.setPlansPanel(color)
        }
        if let hex = skin.plansCard, let color = Color(hex: hex) {
            theme.setPlansCard(color)
        }
        if let hex = skin.plansText, let color = Color(hex: hex) {
            theme.setPlansText(color)
        }
        if let hex = skin.tasksPanel, let color = Color(hex: hex) {
            theme.setTasksPanel(color)
        }
        if let hex = skin.tasksText, let color = Color(hex: hex) {
            theme.setTasksText(color)
        }
        if let hex = skin.background, let color = Color(hex: hex) {
            theme.setBackground(color)
        }
        if let hex = skin.secondaryBackground, let color = Color(hex: hex) {
            theme.setSecondaryBackground(color)
        }
        if let panelAccents = skin.panelAccents {
            for (key, hex) in panelAccents {
                guard let kind = WorkspacePanelKind.themeStorageKeyMap[key],
                      let color = Color(hex: hex) else { continue }
                theme.setPanelAccent(color, for: kind)
            }
        }
    }

    /// Apply a skin by its ID, or reset to default if the ID is not found.
    func applySkin(id: String) {
        applySkin(skins.first { $0.id == id })
    }

    /// Reset to the system default look.
    func applyDefault() {
        applySkin(.default)
    }

    /// Save a skin as a JSON file in the user skins directory. Built-in skins are
    /// not written to disk.
    @discardableResult
    func saveSkin(_ skin: Skin) throws -> Skin {
        var skin = skin
        skin.isBuiltIn = false
        let url = skinFileURL(for: skin.id)
        try skin.jsonData().write(to: url, options: .atomic)
        reload()
        return skin
    }

    /// Export a skin to a chosen path (e.g. user Desktop). Useful for sharing.
    func exportSkin(_ skin: Skin, to url: URL) throws {
        try skin.jsonData().write(to: url, options: .atomic)
    }

    /// Import a skin from a JSON file, copying it into the user skins directory.
    @discardableResult
    func importSkin(from url: URL) throws -> Skin {
        let data = try Data(contentsOf: url)
        var skin = try Skin.from(jsonData: data)
        skin.isBuiltIn = false
        // Avoid clobbering an existing skin by deriving a unique id.
        let baseID = skin.id
        var candidateID = baseID
        var counter = 1
        while skinFileExists(id: candidateID) {
            counter += 1
            candidateID = "\(baseID)-\(counter)"
        }
        skin = Skin(
            id: candidateID,
            name: skin.name,
            description: skin.description,
            isBuiltIn: false,
            accent: skin.accent,
            userBubble: skin.userBubble,
            userBubbleText: skin.userBubbleText,
            chatBackground: skin.chatBackground,
            chatSecondaryText: skin.chatSecondaryText,
            sidebarBackground: skin.sidebarBackground,
            sidebarText: skin.sidebarText,
            plansPanel: skin.plansPanel,
            plansCard: skin.plansCard,
            plansText: skin.plansText,
            tasksPanel: skin.tasksPanel,
            tasksText: skin.tasksText,
            background: skin.background,
            secondaryBackground: skin.secondaryBackground,
            panelAccents: skin.panelAccents
        )
        try saveSkin(skin)
        return skin
    }

    /// Delete a user skin. Built-in skins cannot be deleted.
    func deleteSkin(_ skin: Skin) throws {
        guard !skin.isBuiltIn else { return }
        try FileManager.default.removeItem(at: skinFileURL(for: skin.id))
        if currentSkinID == skin.id {
            currentSkinID = nil
            theme.resetColors()
        }
        reload()
    }

    /// Create a skin from the currently active overrides.
    func skinFromCurrentColors(name: String, description: String? = nil) -> Skin {
        Skin(
            id: nil,
            name: name,
            description: description,
            isBuiltIn: false,
            appearance: theme.appearance,
            accent: theme.accent.hexRGBA,
            userBubble: theme.userBubble.hexRGBA,
            userBubbleText: theme.userBubbleText.hexRGBA,
            chatBackground: theme.chatBackground.hexRGBA,
            chatText: theme.chatText.hexRGBA,
            chatSecondaryText: theme.chatSecondaryText.hexRGBA,
            sidebarBackground: theme.sidebarBackground.hexRGBA,
            sidebarText: theme.sidebarText.hexRGBA,
            plansPanel: theme.plansPanel.hexRGBA,
            plansCard: theme.plansCard.hexRGBA,
            plansText: theme.plansCardText.hexRGBA,
            tasksPanel: theme.tasksPanel.hexRGBA,
            tasksText: theme.tasksText.hexRGBA,
            background: theme.background.hexRGBA,
            secondaryBackground: theme.secondaryBackground.hexRGBA,
            panelAccents: theme.panelAccentOverrides.compactMapValues(\.hexRGBA)
        )
    }

    /// Reload the catalog from built-in skins + disk.
    func reload() {
        let builtIns = Self.builtInSkins
        var userSkins: [Skin] = []
        let fm = FileManager.default
        let dir = skinsDirectory
        if let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil, options: .skipsHiddenFiles) {
            for url in files where url.pathExtension.lowercased() == "json" {
                if let data = try? Data(contentsOf: url),
                   var skin = try? Skin.from(jsonData: data) {
                    skin.isBuiltIn = false
                    userSkins.append(skin)
                }
            }
        }
        skins = builtIns + userSkins.sorted { $0.name.localizedCompare($1.name) == .orderedAscending }

        // If the persisted current skin is gone, fall back to default but keep
        // the user-defined overrides in place.
        if let currentSkinID, !skins.contains(where: { $0.id == currentSkinID }) {
            self.currentSkinID = nil
        }
    }

    // MARK: - Paths

    private var skinsDirectory: URL {
        let dir = SwiftMaestroPaths.appSupportDir.appendingPathComponent(Self.skinsDirName, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func skinFileURL(for id: String) -> URL {
        skinsDirectory.appendingPathComponent("\(id).skin.json")
    }

    private func skinFileExists(id: String) -> Bool {
        FileManager.default.fileExists(atPath: skinFileURL(for: id).path)
    }

    // MARK: - Built-in skins
    // Each theme ships as a light and dark variant so the system text colors
    // (.primary/.secondary) adapt correctly and every background has contrast.

    static var builtInSkins: [Skin] {
        [
            .default,
            matrixDark,
            matrixLight,
            cyberpunkNeonDark,
            cyberpunkNeonLight,
            helloKittyPinksLight,
            helloKittyPinksDark,
            rainbowsAndUnicornsLight,
            rainbowsAndUnicornsDark,
            cleanAndMinimalLight,
            cleanAndMinimalDark,
            professionalLight,
            professionalDark,
        ]
    }

    // MARK: - Matrix

    static var matrixDark: Skin {
        Skin(
            id: "matrix-dark",
            name: "Matrix Dark",
            description: "Terminal green on black.",
            isBuiltIn: true,
            appearance: .dark,
            accent: "00FF41FF",
            userBubble: "00FF41FF",
            userBubbleText: "000000FF",
            chatBackground: "050A05FF",
            chatText: "00FF41FF",
            sidebarBackground: "081008FF",
            sidebarText: "00FF41FF",
            plansPanel: "0D1A0DFF",
            plansText: "000000FF",
            tasksPanel: "0D1A0DFF",
            tasksText: "00FF41FF",
            background: "050A05FF",
            secondaryBackground: "0F1F0FFF"
        )
    }

    static var matrixLight: Skin {
        Skin(
            id: "matrix-light",
            name: "Matrix Light",
            description: "Terminal green on a clean white-green field.",
            isBuiltIn: true,
            appearance: .light,
            accent: "00B22DFF",
            userBubble: "00B22DFF",
            userBubbleText: "FFFFFFFF",
            chatBackground: "F0FFF4FF",
            chatText: "004D00FF",
            sidebarBackground: "E0F8E0FF",
            sidebarText: "004D00FF",
            plansPanel: "D8F5D8FF",
            plansText: "004D00FF",
            tasksPanel: "E8FBE8FF",
            tasksText: "004D00FF",
            background: "F0FFF4FF",
            secondaryBackground: "FFFFFFCC"
        )
    }

    // MARK: - Cyberpunk Neon

    static var cyberpunkNeonDark: Skin {
        Skin(
            id: "cyberpunk-neon-dark",
            name: "Cyberpunk Neon Dark",
            description: "Hot pink and electric blue on a dark cityscape.",
            isBuiltIn: true,
            appearance: .dark,
            accent: "FF00D2FF",
            userBubble: "FF00D2FF",
            userBubbleText: "FFFFFFFF",
            chatBackground: "120A1FFF",
            chatText: "FFFFFFFF",
            sidebarBackground: "1A0F2EFF",
            sidebarText: "FFFFFFFF",
            plansPanel: "241740FF",
            plansText: "FFFFFFFF",
            tasksPanel: "002F4FFF",
            tasksText: "FFFFFFFF",
            background: "120A1FFF",
            secondaryBackground: "1F1135FF",
            panelAccents: [
                "terminal": "00F0FFFF",
                "notesMD": "FF00D2FF",
                "busMonitor": "F5A623FF",
                "canvas": "B85CFFCC",
                "kanban": "00F0FFFF",
                "whatsapp": "25D366FF",
            ]
        )
    }

    static var cyberpunkNeonLight: Skin {
        Skin(
            id: "cyberpunk-neon-light",
            name: "Cyberpunk Neon Light",
            description: "Hot pink and electric blue on a pale cityscape.",
            isBuiltIn: true,
            appearance: .light,
            accent: "FF00D2FF",
            userBubble: "FF00D2FF",
            userBubbleText: "FFFFFFFF",
            chatBackground: "FFF5FCFF",
            chatText: "1A0A2EFF",
            sidebarBackground: "F0E6FFFF",
            sidebarText: "1A0A2EFF",
            plansPanel: "F5E0FFFF",
            plansText: "1A0A2EFF",
            tasksPanel: "E0F0FFFF",
            tasksText: "1A0A2EFF",
            background: "FFF5FCFF",
            secondaryBackground: "FFFFFFCC",
            panelAccents: [
                "terminal": "00B0CCFF",
                "notesMD": "FF00D2FF",
                "busMonitor": "E09000FF",
                "canvas": "B85CFFCC",
                "kanban": "00B0CCFF",
                "whatsapp": "1E9E4FFF",
            ]
        )
    }

    // MARK: - Hello Kitty Pinks

    static var helloKittyPinksLight: Skin {
        Skin(
            id: "hello-kitty-pinks-light",
            name: "Hello Kitty Pinks Light",
            description: "Soft pastels and candy pinks.",
            isBuiltIn: true,
            appearance: .light,
            accent: "FF1493FF",
            userBubble: "FF1493FF",
            userBubbleText: "FFFFFFFF",
            chatBackground: "FFF5F9FF",
            chatText: "880E4FFF",
            sidebarBackground: "FFD1E0FF",
            sidebarText: "C2185BFF",
            plansPanel: "FFCCE0FF",
            plansText: "C2185BFF",
            tasksPanel: "FFF0F5FF",
            tasksText: "C2185BFF",
            background: "FFF5F9FF",
            secondaryBackground: "FFFFFFCC",
            panelAccents: [
                "notesMD": "FF69B4FF",
                "busMonitor": "FF85C0FF",
                "canvas": "FF69B4FF",
                "kanban": "DDA0DDFF",
                "whatsapp": "25D366FF",
                "terminal": "F48FB1FF",
                "numbers": "F06292FF",
                "calendar": "F48FB1FF",
                "appleNotes": "F8BBD0FF",
            ]
        )
    }

    static var helloKittyPinksDark: Skin {
        Skin(
            id: "hello-kitty-pinks-dark",
            name: "Hello Kitty Pinks Dark",
            description: "Candy pinks on a deep magenta night.",
            isBuiltIn: true,
            appearance: .dark,
            accent: "FF69B4FF",
            userBubble: "FF69B4FF",
            userBubbleText: "FFFFFFFF",
            chatBackground: "2A0A1AFF",
            chatText: "FFFFFFCC",
            sidebarBackground: "3D0F26FF",
            sidebarText: "FFFFFFCC",
            plansPanel: "4A0F2EFF",
            plansText: "FFFFFFCC",
            tasksPanel: "2D0F1FFF",
            tasksText: "FFFFFFCC",
            background: "2A0A1AFF",
            secondaryBackground: "3D0F26FF",
            panelAccents: [
                "notesMD": "FF69B4FF",
                "busMonitor": "FF85C0FF",
                "canvas": "FF69B4FF",
                "kanban": "DDA0DDFF",
                "whatsapp": "25D366FF",
                "terminal": "F48FB1FF",
                "numbers": "F06292FF",
                "calendar": "F48FB1FF",
                "appleNotes": "F8BBD0FF",
            ]
        )
    }

    // MARK: - Rainbows and Unicorns

    static var rainbowsAndUnicornsLight: Skin {
        Skin(
            id: "rainbows-and-unicorns-light",
            name: "Rainbows and Unicorns Light",
            description: "Vibrant rainbow panels on a light cloud background.",
            isBuiltIn: true,
            appearance: .light,
            accent: "FF0080FF",
            userBubble: "FF0080FF",
            userBubbleText: "FFFFFFFF",
            chatBackground: "F8F4FFFF",
            chatText: "1565C0FF",
            sidebarBackground: "E6F7FFFF",
            sidebarText: "1976D2FF",
            plansPanel: "FFE4F1FF",
            plansText: "1565C0FF",
            tasksPanel: "E6F7E6FF",
            tasksText: "1565C0FF",
            background: "F8F4FFFF",
            secondaryBackground: "FFFFFFCC",
            panelAccents: [
                "busMonitor": "FF0000FF",
                "notesMD": "FF7F00FF",
                "calendar": "FFFF00FF",
                "reminders": "00FF00FF",
                "contacts": "0000FFFF",
                "canvas": "4B0082FF",
                "kanban": "9400D3FF",
                "whatsapp": "25D366FF",
                "terminal": "FF00FFFF",
                "numbers": "00FFFFFF",
                "appleNotes": "FFD700FF",
            ]
        )
    }

    static var rainbowsAndUnicornsDark: Skin {
        Skin(
            id: "rainbows-and-unicorns-dark",
            name: "Rainbows and Unicorns Dark",
            description: "Vibrant rainbow panels on a dark night background.",
            isBuiltIn: true,
            appearance: .dark,
            accent: "FF00A0FF",
            userBubble: "FF00A0FF",
            userBubbleText: "FFFFFFFF",
            chatBackground: "1A0A2AFF",
            chatText: "FFFFFFCC",
            sidebarBackground: "0F1A2AFF",
            sidebarText: "FFFFFFCC",
            plansPanel: "2A0A1AFF",
            plansText: "FFFFFFCC",
            tasksPanel: "0A2A0AFF",
            tasksText: "FFFFFFCC",
            background: "1A0A2AFF",
            secondaryBackground: "251035FF",
            panelAccents: [
                "busMonitor": "FF3333FF",
                "notesMD": "FF9933FF",
                "calendar": "FFFF33FF",
                "reminders": "33FF33FF",
                "contacts": "3333FFFF",
                "canvas": "7B33CCFF",
                "kanban": "CC33FFFF",
                "whatsapp": "25D366FF",
                "terminal": "FF33FFFF",
                "numbers": "33FFFFFF",
                "appleNotes": "FFD700FF",
            ]
        )
    }

    // MARK: - Clean and Minimal

    static var cleanAndMinimalLight: Skin {
        Skin(
            id: "clean-and-minimal-light",
            name: "Clean and Minimal Light",
            description: "Soft grays with a restrained accent. Easy on the eyes.",
            isBuiltIn: true,
            appearance: .light,
            accent: "5A7D9AFF",
            userBubble: "5A7D9AFF",
            userBubbleText: "FFFFFFFF",
            chatBackground: "F5F5F7FF",
            chatText: "1D1D1FFF",
            sidebarBackground: "FFFFFFCC",
            sidebarText: "1D1D1FFF",
            plansPanel: "EBEBF0FF",
            plansText: "1D1D1FFF",
            tasksPanel: "EBEBF0FF",
            tasksText: "1D1D1FFF",
            background: "F5F5F7FF",
            secondaryBackground: "FFFFFFCC"
        )
    }

    static var cleanAndMinimalDark: Skin {
        Skin(
            id: "clean-and-minimal-dark",
            name: "Clean and Minimal Dark",
            description: "Soft grays with a restrained accent, dark mode.",
            isBuiltIn: true,
            appearance: .dark,
            accent: "8BA4B8FF",
            userBubble: "8BA4B8FF",
            userBubbleText: "1D1D1FFF",
            chatBackground: "1D1D1FFF",
            chatText: "FFFFFFCC",
            sidebarBackground: "25252AFF",
            sidebarText: "FFFFFFCC",
            plansPanel: "2C2C32FF",
            plansText: "1D1D1FFF",
            tasksPanel: "2C2C32FF",
            tasksText: "FFFFFFCC",
            background: "1D1D1FFF",
            secondaryBackground: "2C2C32FF"
        )
    }

    // MARK: - Professional

    static var professionalLight: Skin {
        Skin(
            id: "professional-light",
            name: "Professional Light",
            description: "Navy, slate, and crisp white. Boardroom-ready.",
            isBuiltIn: true,
            appearance: .light,
            accent: "1A3C6EFF",
            userBubble: "1A3C6EFF",
            userBubbleText: "FFFFFFFF",
            chatBackground: "F7F9FCFF",
            chatText: "1F2D3DFF",
            sidebarBackground: "EDF1F5FF",
            sidebarText: "1F2D3DFF",
            plansPanel: "E1E8F0FF",
            plansText: "FFFFFFFF",
            tasksPanel: "E1E8F0FF",
            tasksText: "1F2D3DFF",
            background: "F7F9FCFF",
            secondaryBackground: "FFFFFFFF"
        )
    }

    static var professionalDark: Skin {
        Skin(
            id: "professional-dark",
            name: "Professional Dark",
            description: "Navy, slate, and crisp white. Boardroom-ready.",
            isBuiltIn: true,
            appearance: .dark,
            accent: "5A8CCBFF",
            userBubble: "5A8CCBFF",
            userBubbleText: "FFFFFFFF",
            chatBackground: "0F1720FF",
            chatText: "FFFFFFCC",
            sidebarBackground: "16202BFF",
            sidebarText: "FFFFFFCC",
            plansPanel: "1E2D3DFF",
            plansText: "0F1720FF",
            tasksPanel: "1E2D3DFF",
            tasksText: "FFFFFFCC",
            background: "0F1720FF",
            secondaryBackground: "1E2D3DFF"
        )
    }
}

// MARK: - WorkspacePanelKind reverse lookup

extension WorkspacePanelKind {
    /// Reverse of `themeStorageKey` so a skin's `panelAccents` dictionary can map
    /// back to a concrete panel kind.
    static var themeStorageKeyMap: [String: WorkspacePanelKind] {
        [
            "busMonitor": .busMonitor,
            "notesMD": .notesMD,
            "appleNotes": .appleNotes,
            "calendar": .calendar,
            "reminders": .reminders,
            "contacts": .contacts,
            "canvas": .canvas,
            "kanban": .kanban,
            "numbers": .numbers,
            "whatsapp": .whatsapp,
            "terminal": .terminal,
            "tethering": .tethering,
            "streamIngest": .streamIngest,
            "broadcast": .broadcast,
            "streamMixer": .streamMixer,
            "ndiBrowser": .ndiBrowser,
            "colorAdjustments": .colorAdjustments,
            "scenes": .scenes,
        ]
    }
}
