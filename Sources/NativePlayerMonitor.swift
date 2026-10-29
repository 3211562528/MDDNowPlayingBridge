import AppKit
import ApplicationServices

@MainActor final class NativePlayerMonitor {
    private let onChange: @MainActor (Bool?) -> Void
    private var application: AXUIElement?
    private var observer: AXObserver?
    private var playerWindow: AXUIElement?
    private var lastPresence: Bool?
    private var hasReported = false
    private var generation = 0
    private var refreshQueued = false

    init(onChange: @escaping @MainActor (Bool?) -> Void) {
        self.onChange = onChange
    }

    func start(pid: pid_t) {
        stop()
        guard AXIsProcessTrusted() else { report(nil); return }
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, 0.2)
        var createdObserver: AXObserver?
        let result = AXObserverCreate(pid, { _, _, _, context in
            guard let context else { return }
            MainActor.assumeIsolated {
                Unmanaged<NativePlayerMonitor>.fromOpaque(context).takeUnretainedValue().queueRefresh()
            }
        }, &createdObserver)
        guard result == .success, let createdObserver else { report(nil); return }
        self.application = application
        observer = createdObserver
        let context = Unmanaged.passUnretained(self).toOpaque()
        for notification in [kAXWindowCreatedNotification, kAXFocusedWindowChangedNotification] {
            guard AXObserverAddNotification(createdObserver, application, notification as CFString, context) == .success else {
                stop(); report(nil); return
            }
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(createdObserver), .commonModes)
        refresh()
    }

    func refresh() {
        guard let application, let observer else { report(nil); return }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { report(nil); return }
        var found: AXUIElement?
        var unreadable = false
        for window in windows {
            AXUIElementSetMessagingTimeout(window, 0.2)
            var title: CFTypeRef?
            let result = AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &title)
            if result != .success { unreadable = true; continue }
            if title as? String == "OcsPlayer" { found = window; break }
        }
        if let old = playerWindow, found.map({ CFEqual(old, $0) }) != true {
            AXObserverRemoveNotification(observer, old, kAXUIElementDestroyedNotification as CFString)
            playerWindow = nil
        }
        if let found, playerWindow == nil {
            let result = AXObserverAddNotification(observer, found, kAXUIElementDestroyedNotification as CFString, Unmanaged.passUnretained(self).toOpaque())
            guard result == .success else { report(nil); return }
            playerWindow = found
        }
        report(found != nil ? true : unreadable ? nil : false)
    }

    func stop() {
        generation += 1
        refreshQueued = false
        if let observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
            if let playerWindow { AXObserverRemoveNotification(observer, playerWindow, kAXUIElementDestroyedNotification as CFString) }
            if let application {
                for notification in [kAXWindowCreatedNotification, kAXFocusedWindowChangedNotification] {
                    AXObserverRemoveNotification(observer, application, notification as CFString)
                }
            }
        }
        observer = nil; application = nil; playerWindow = nil
        hasReported = false; lastPresence = nil
    }

    private func queueRefresh() {
        guard !refreshQueued else { return }
        refreshQueued = true
        let generation = generation
        DispatchQueue.main.async { [weak self] in
            guard let self, self.generation == generation else { return }
            self.refreshQueued = false
            self.refresh()
        }
    }

    private func report(_ presence: Bool?) {
        guard !hasReported || presence != lastPresence else { return }
        hasReported = true; lastPresence = presence
        onChange(presence)
    }

    deinit {
        if let observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        }
    }
}
