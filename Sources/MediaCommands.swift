import AppKit
import ApplicationServices
import MediaPlayer

@MainActor final class MediaCommands {
    private let center = MPRemoteCommandCenter.shared()
    private let context: @MainActor () -> (pid: pid_t, playing: Bool)?
    private var enabled: Bool?
    private var lastKey: (UInt16, Date)?
    private var pending: (Bool, Date)?

    init(context: @escaping @MainActor () -> (pid: pid_t, playing: Bool)?) {
        self.context = context
        register(center.playCommand, .play)
        register(center.pauseCommand, .pause)
        register(center.togglePlayPauseCommand, .toggle)
        register(center.previousTrackCommand, .backward)
        register(center.nextTrackCommand, .forward)
        center.skipBackwardCommand.preferredIntervals = [15]
        center.skipForwardCommand.preferredIntervals = [15]
        register(center.skipBackwardCommand, .backward)
        register(center.skipForwardCommand, .forward)
        setEnabled(false)
    }
    private var allCommands: [MPRemoteCommand] {
        [center.playCommand, center.pauseCommand, center.togglePlayPauseCommand, center.previousTrackCommand, center.nextTrackCommand, center.skipBackwardCommand, center.skipForwardCommand]
    }
    private func register(_ command: MPRemoteCommand, _ action: MediaAction) {
        command.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            return self.receive(action)
        }
    }
    nonisolated private func receive(_ action: MediaAction) -> MPRemoteCommandHandlerStatus {
        if Thread.isMainThread { return MainActor.assumeIsolated { handle(action) } }
        return DispatchQueue.main.sync { handle(action) }
    }
    func setEnabled(_ value: Bool) {
        guard enabled != value else { return }
        enabled = value
        allCommands.forEach { $0.isEnabled = value }
        if !value { pending = nil; lastKey = nil }
    }
    func acknowledge(_ playing: Bool) { if pending?.0 == playing { pending = nil } }
    private func handle(_ action: MediaAction) -> MPRemoteCommandHandlerStatus {
        guard enabled == true, let context = context() else { return .noActionableNowPlayingItem }
        let now = Date()
        let key = action.keyCode
        if let lastKey, lastKey.0 == key, now.timeIntervalSince(lastKey.1) < (key == 49 ? 0.25 : 0.10) { return .success }
        var desired: Bool?
        switch action {
        case .play: desired = true
        case .pause: desired = false
        case .toggle: desired = !context.playing
        case .backward, .forward: break
        }
        if let desired {
            if desired == context.playing { return .success }
            if let pending, pending.0 == desired, now.timeIntervalSince(pending.1) < 1.5 { return .success }
        }
        guard CGPreflightPostEventAccess() else {
            bridgeLog("Control blocked: grant Accessibility permission to the bridge")
            return .commandFailed
        }
        guard let source = CGEventSource(stateID: .hidSystemState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false) else { return .commandFailed }
        lastKey = (key, now)
        if let desired { pending = (desired, now) }
        down.postToPid(context.pid)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) { up.postToPid(context.pid) }
        bridgeLog("Media command \(action) delivered to MDD; key=\(key)")
        return .success
    }
    func stop() { setEnabled(false); allCommands.forEach { $0.removeTarget(nil) } }
}
