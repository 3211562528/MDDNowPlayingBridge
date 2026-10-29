import AppKit
import MediaPlayer

@MainActor final class NowPlayingPublisher {
    private let center = MPNowPlayingInfoCenter.default()
    private var fingerprint: Fingerprint?
    private struct Fingerprint: Equatable {
        let id: String; let title: String; let coverURL: URL?; let artworkReady: Bool; let playing: Bool
    }
    func render(item: PlaybackItem, artwork: NSImage?, playing: Bool) {
        let next = Fingerprint(id: item.id, title: item.title, coverURL: item.coverURL, artworkReady: artwork != nil, playing: playing)
        guard fingerprint != next else { return }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: item.title,
            MPMediaItemPropertyArtist: "墨督督",
            MPMediaItemPropertyAlbumTitle: "课程播放",
            MPNowPlayingInfoPropertyExternalContentIdentifier: item.id,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
            MPNowPlayingInfoPropertyPlaybackRate: playing ? 1.0 : 0.0
        ]
        if let artwork { info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: artwork.size) { _ in artwork } }
        center.nowPlayingInfo = info
        center.playbackState = playing ? .playing : .paused
        fingerprint = next
        bridgeLog("Now Playing updated: item=\(item.id), playing=\(playing), cover=\(artwork != nil)")
    }
    func clear() {
        guard fingerprint != nil || center.nowPlayingInfo != nil else { return }
        center.playbackState = .stopped
        center.nowPlayingInfo = nil
        fingerprint = nil
        bridgeLog("Now Playing cleared: no current course")
    }
}
