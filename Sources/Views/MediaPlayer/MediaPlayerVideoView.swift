import AVKit
import SwiftUI

// MARK: - Media Player Video View
//
// AppKit AVPlayerView wrapped for SwiftUI, bound to the shared engine player.
// Shown by MediaPlayerView whenever the loaded item has a video track; the
// retro visualization stays for audio-only files.

struct MediaPlayerVideoView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .inline
        view.showsFullScreenToggleButton = true
        view.allowsPictureInPicturePlayback = true
        view.updatesNowPlayingInfoCenter = false
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        if nsView.player !== player {
            nsView.player = player
        }
    }
}
