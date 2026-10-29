import AppKit
import ApplicationServices
import Darwin

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    private let targetID = "com.shike.mac.mddclass"
    private let client = MDDPageClient()
    private let publisher = NowPlayingPublisher()
    private var gate = SessionGate()
    private var playing = false
    private var processID: pid_t?
    private var processEpoch = 0
    private var playerPresent: Bool?
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var forceMetadata = true
    private var logMonitoring = false
    private var metadataTask: Task<Void, Never>?
    private var artworkTask: Task<Void, Never>?
    private var artworkToken = UUID()
    private var trackedItem: PlaybackItem?
    private var artwork: NSImage?

    private var itemChangedAt = Date()
    private var lastArtworkAttempt = Date.distantPast
    private lazy var nativePlayer = NativePlayerMonitor { [weak self] present in
        self?.playerPresenceChanged(present)
    }
    private lazy var commands = MediaCommands { [weak self] in
        guard let self, self.gate.item != nil, let pid = self.processID else { return nil }
        return (pid, self.playing)
    }
    private lazy var playbackLog = PlaybackLogMonitor(directory: URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support/MDDClass/Log")) { [weak self] state in
        Task { @MainActor in
            guard let self, self.processID != nil, self.playerPresent == true else { return }
            self.playing = state; self.commands.acknowledge(state); self.render()
            bridgeLog("Player log applied: playing=\(state)")
            self.forceMetadata = true; self.tick()
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        _ = commands
        bridgeLog("Bridge started: \(Bundle.main.bundleIdentifier ?? "unknown"); postEventAccess=\(CGPreflightPostEventAccess()), accessibility=\(AXIsProcessTrusted())")
        let notificationCenter = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification, NSWorkspace.didActivateApplicationNotification] {
            observers.append(notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                MainActor.assumeIsolated {
                    guard let self, let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication, app.bundleIdentifier == self.targetID else { return }
                    if name == NSWorkspace.didTerminateApplicationNotification {
                        if self.processID == app.processIdentifier { self.attach(nil) }
                    } else if name == NSWorkspace.didLaunchApplicationNotification { self.attach(app.processIdentifier) }
                    else { self.nativePlayer.refresh(); self.forceMetadata = true; self.tick() }
                }
            })
        }
        let pid = NSRunningApplication.runningApplications(withBundleIdentifier: targetID).first(where: { !$0.isTerminated })?.processIdentifier
        attach(pid)
        if !CGPreflightPostEventAccess(), ProcessInfo.processInfo.environment["MDD_BRIDGE_BENCHMARK"] == nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { _ = CGRequestPostEventAccess() }
        }
    }
    private func attach(_ pid: pid_t?) {
        guard pid != processID else { return }
        nativePlayer.stop(); playerPresent = nil
        processEpoch += 1; processID = pid; metadataTask?.cancel(); metadataTask = nil
        timer?.invalidate(); timer = nil
        gate.clear(); playing = false; forceMetadata = true; render()
        bridgeLog("MDD process changed: running=\(pid != nil)")
        guard let pid else { return }
        nativePlayer.start(pid: pid)
    }
    private func playerPresenceChanged(_ present: Bool?) {
        guard playerPresent != present else { return }
        playerPresent = present
        processEpoch += 1; metadataTask?.cancel(); metadataTask = nil
        timer?.invalidate(); timer = nil
        gate.clear(); playing = false; render()
        bridgeLog("Native player presence: \(present.map(String.init) ?? "unavailable")")
        guard present == true, processID != nil else { return }
        forceMetadata = true
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer.tolerance = 0.2; self.timer = timer; RunLoop.main.add(timer, forMode: .common)
        tick()
    }
    private func tick() {
        guard let pid = processID, playerPresent == true else { return }
        if kill(pid, 0) != 0 { attach(nil); return }
        gate.expire(at: Date()); render()
        guard metadataTask == nil else { return }
        let epoch = processEpoch
        let force = forceMetadata; forceMetadata = false
        metadataTask = Task { [weak self, client] in
            let observation = await client.observe(pid: pid, forceRefresh: force)
            guard !Task.isCancelled, let self, self.processEpoch == epoch, self.playerPresent == true else { return }
            self.metadataTask = nil
            self.gate.accept(observation, at: Date())
            self.render()
        }
    }

    private func render() {
        guard let item = gate.item else {
            commands.setEnabled(false); publisher.clear()
            if logMonitoring { playbackLog.stop(); logMonitoring = false }
            if trackedItem != nil {
                artworkToken = UUID(); artworkTask?.cancel(); artworkTask = nil
                trackedItem = nil; artwork = nil
            }
            return
        }
        if !logMonitoring { playbackLog.start(); logMonitoring = true }
        if trackedItem?.id != item.id || trackedItem?.coverURL != item.coverURL {
            artworkToken = UUID(); artworkTask?.cancel(); artworkTask = nil
            if trackedItem?.coverURL != item.coverURL { artwork = nil }
            itemChangedAt = Date(); lastArtworkAttempt = .distantPast
        }
        trackedItem = item
        commands.setEnabled(true)
        if let url = item.coverURL, artwork == nil, artworkTask == nil, Date().timeIntervalSince(lastArtworkAttempt) >= 5 {
            lastArtworkAttempt = Date()
            let token = artworkToken
            artworkTask = Task { [weak self] in
                let data = await MDDPageClient.coverData(for: item)
                guard !Task.isCancelled, let self, self.artworkToken == token, self.gate.item?.id == item.id, self.gate.item?.coverURL == url else { return }
                self.artworkTask = nil
                if let data, let image = NSImage(data: data) {
                    self.artwork = image
                    bridgeLog("Current course cover loaded")
                } else { bridgeLog("Current cover unavailable; will retry") }
                self.render()
            }
        }
        if item.coverURL != nil && artwork == nil && Date().timeIntervalSince(itemChangedAt) < 1.5 { return }
        publisher.render(item: item, artwork: artwork, playing: playing)
    }
    func applicationWillTerminate(_ notification: Notification) {
        nativePlayer.stop(); timer?.invalidate(); metadataTask?.cancel(); artworkTask?.cancel(); playbackLog.stop()
        observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }; observers.removeAll()
        commands.stop(); gate.clear(); publisher.clear()
        bridgeLog("Bridge exited normally")
    }
}
