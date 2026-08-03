import SwiftUI

/// Lightweight contextual hints that appear once over specific features.
/// Each tip is identified by a string key and shown the first time the user
/// encounters the feature. Tips can be disabled globally in Settings → About.
enum FeatureTip {

    /// Master toggle — when false, no tips are shown anywhere.
    static var tipsEnabled: Bool {
        get { !UserDefaults.standard.bool(forKey: "featureTips.disabled") }
        set { UserDefaults.standard.set(!newValue, forKey: "featureTips.disabled") }
    }

    /// Whether a specific tip has been dismissed (or never shown if tips are off).
    static func isDismissed(_ key: String) -> Bool {
        guard tipsEnabled else { return true }
        return UserDefaults.standard.bool(forKey: "featureTip.dismissed.\(key)")
    }

    /// Mark a tip as dismissed so it never appears again.
    static func dismiss(_ key: String) {
        UserDefaults.standard.set(true, forKey: "featureTip.dismissed.\(key)")
    }

    /// Reset all dismissed tips (for "Show tips again" in Settings).
    static func resetAll() {
        let defaults = UserDefaults.standard
        let keys = defaults.dictionaryRepresentation().keys.filter { $0.hasPrefix("featureTip.dismissed.") }
        for key in keys { defaults.removeObject(forKey: key) }
    }

    // MARK: - Tip Keys

    static let toolPicker = "toolPicker"
    static let memory = "memory"
    static let panels = "panels"
    static let plans = "plans"
    static let delegation = "delegation"
    static let settings = "settings"
}

/// A small, auto-dismissing hint popup that anchors to a view.
/// Shows once per feature, then never again.
struct FeatureTipPopup<Anchor: View>: View {
    let key: String
    let message: String
    let icon: String
    @ViewBuilder let anchor: Anchor

    @State private var visible = false

    var body: some View {
        anchor
            .overlay(alignment: .topTrailing) {
                if visible {
                    tipBubble
                        .transition(.asymmetric(
                            insertion: .scale.combined(with: .opacity),
                            removal: .opacity
                        ))
                        .offset(x: 8, y: -4)
                }
            }
            .onAppear {
                guard !FeatureTip.isDismissed(key) else { return }
                withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                    visible = true
                }
                // Auto-dismiss after 8 seconds.
                DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
                    withAnimation { visible = false }
                    FeatureTip.dismiss(key)
                }
            }
    }

    private var tipBubble: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(.white)
            Text(message)
                .font(.caption)
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                withAnimation { visible = false }
                FeatureTip.dismiss(key)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.7))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(.ultraThinMaterial)
                .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
        )
        .frame(maxWidth: 280)
    }
}
