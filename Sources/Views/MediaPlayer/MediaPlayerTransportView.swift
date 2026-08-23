import SwiftUI

// MARK: - Media Player Transport Controls
//
// Play/Pause, Skip Back/Forward, and seek ±15s buttons in the BTOP+
// retro aesthetic: rounded glyph buttons with glow on press.

struct MediaPlayerTransportView: View {
    let isPlaying: Bool
    let hasItem: Bool
    let onPlayPause: () -> Void
    let onSkipBack: () -> Void
    let onSkipForward: () -> Void
    let onSeekBackward15: () -> Void
    let onSeekForward15: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            TransportButton(
                icon: "gobackward.15",
                size: 18,
                enabled: hasItem
            ) {
                onSeekBackward15()
            }

            TransportButton(
                icon: "backward.fill",
                size: 20,
                enabled: hasItem
            ) {
                onSkipBack()
            }

            // Play/Pause — larger, central
            TransportButton(
                icon: isPlaying ? "pause.fill" : "play.fill",
                size: 28,
                enabled: true,
                isPrimary: true
            ) {
                onPlayPause()
            }

            TransportButton(
                icon: "forward.fill",
                size: 20,
                enabled: hasItem
            ) {
                onSkipForward()
            }

            TransportButton(
                icon: "goforward.15",
                size: 18,
                enabled: hasItem
            ) {
                onSeekForward15()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(RetroPalette.background)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(RetroPalette.green.opacity(0.35), lineWidth: 1)
        )
    }
}

// MARK: - Transport Button

private struct TransportButton: View {
    let icon: String
    let size: CGFloat
    let enabled: Bool
    var isPrimary: Bool = false
    let action: () -> Void

    @State private var isPressed = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: size, weight: .medium))
                .foregroundStyle(enabled ? buttonColor : RetroPalette.dim)
                .frame(width: size + 20, height: size + 20)
                .background(
                    isPressed
                        ? RetroPalette.green.opacity(0.15)
                        : Color.clear
                )
                .clipShape(Circle())
                .overlay(
                    Circle()
                        .strokeBorder(
                            isPressed ? RetroPalette.green.opacity(0.6) : Color.clear,
                            lineWidth: 1
                        )
                )
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1.0 : 0.35)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) {
                isPressed = hovering
            }
        }
    }

    private var buttonColor: Color {
        isPrimary ? RetroPalette.green : RetroPalette.green.opacity(0.8)
    }
}
