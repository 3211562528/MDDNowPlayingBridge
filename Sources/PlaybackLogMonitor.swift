import Foundation
import Darwin

final class PlaybackLogMonitor: @unchecked Sendable {
    private let queue = DispatchQueue(label: "mdd.playback-log")
    private let directory: URL
    private let onChange: @Sendable (Bool) -> Void
    private var watcher: DispatchSourceFileSystemObject?
    private var timer: DispatchSourceTimer?
    private var directoryWatcher: DispatchSourceFileSystemObject?
    private var running = false
    private var handle: FileHandle?
    private var path: URL?
    private var inode: UInt64?
    private var offset: UInt64 = 0
    private var parser = PlaybackLogParser()
    private var lastState: Bool?

    init(directory: URL, onChange: @escaping @Sendable (Bool) -> Void) {
        self.directory = directory; self.onChange = onChange
    }
    func start() {
        queue.async { [self] in
            guard !running else { return }
            running = true
            let fd = open(directory.path, O_EVTONLY)
            if fd >= 0 {
                let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: queue)
                source.setEventHandler { [weak self] in self?.refreshFile() }
                source.setCancelHandler { close(fd) }
                directoryWatcher = source; source.resume()
            }
            refreshFile()
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + 30, repeating: 30, leeway: .seconds(5))
            timer.setEventHandler { [weak self] in self?.refreshFile(); self?.readChanges() }
            self.timer = timer; timer.resume()
        }
    }
    func stop() {
        queue.async { [self] in
            running = false
            timer?.cancel(); timer = nil
            directoryWatcher?.cancel(); directoryWatcher = nil
            watcher?.cancel(); watcher = nil; handle = nil; path = nil
        }
    }
    private func refreshFile() {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        guard let latest = files.filter({ $0.pathExtension == "txt" }).max(by: {
            ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) <
            ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
        }) else { return }
        let attributes = try? FileManager.default.attributesOfItem(atPath: latest.path)
        let fileInode = (attributes?[.systemFileNumber] as? NSNumber)?.uint64Value
        guard latest != path || fileInode != inode, let opened = try? FileHandle(forReadingFrom: latest) else { return }
        watcher?.cancel()
        path = latest; inode = fileInode; handle = opened; offset = 0; parser = PlaybackLogParser(); lastState = nil
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: opened.fileDescriptor, eventMask: [.write, .extend, .rename, .delete], queue: queue)
        source.setEventHandler { [weak self] in self?.readChanges() }
        source.setCancelHandler { try? opened.close() }
        watcher = source; source.resume(); readChanges()
    }
    private func readChanges() {
        guard let handle, let length = try? handle.seekToEnd() else { return }
        if length < offset { offset = 0; parser = PlaybackLogParser(); lastState = nil }
        guard length > offset else { return }
        try? handle.seek(toOffset: offset)
        var newest: Bool?
        while offset < length {
            guard let bytes = try? handle.read(upToCount: Int(min(65536, length - offset))), !bytes.isEmpty else { break }
            offset += UInt64(bytes.count)
            if let state = parser.append(bytes) { newest = state }
        }
        if let newest, newest != lastState { lastState = newest; onChange(newest) }
    }
}
