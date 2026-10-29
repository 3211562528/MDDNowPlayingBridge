import Foundation

struct PlaybackItem: Equatable, Sendable {
    let id: String
    let title: String
    let coverURL: URL?
    let pageSocketURL: URL
}

enum PageObservation: Sendable {
    case item(PlaybackItem)
    case none
    case unavailable
}

struct SessionGate {
    private(set) var item: PlaybackItem?
    private(set) var confirmedAt: Date?
    let failureGrace: TimeInterval = 3

    mutating func accept(_ observation: PageObservation, at time: Date) {
        switch observation {
        case .item(let item): self.item = item; confirmedAt = time
        case .none: clear()
        case .unavailable: expire(at: time)
        }
    }
    mutating func expire(at time: Date) {
        if let confirmedAt, time.timeIntervalSince(confirmedAt) >= failureGrace { clear() }
    }
    mutating func clear() { item = nil; confirmedAt = nil }
}

enum MediaAction: Sendable {
    case play, pause, toggle, backward, forward
    var keyCode: UInt16 {
        switch self {
        case .play, .pause, .toggle: return 49
        case .backward: return 123
        case .forward: return 124
        }
    }
}

struct PlaybackLogParser {
    private var pending = Data()
    mutating func append(_ data: Data) -> Bool? {
        pending.append(data)
        var newest: Bool?
        while let newline = pending.firstIndex(of: 10) {
            let line = String(decoding: pending[..<newline], as: UTF8.self)
            pending.removeSubrange(...newline)
            guard let range = line.range(of: "IjkMediaPlayer::changeState, state: ") else { continue }
            switch line[range.upperBound...].first {
            case "0": newest = true
            case "1": newest = false
            default: break
            }
        }
        if pending.count > 8192 { pending = pending.suffix(8192) }
        return newest
    }
}

func bridgeLog(_ message: String) {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    FileHandle.standardOutput.write(Data((formatter.string(from: Date()) + " " + message + "\n").utf8))
}
