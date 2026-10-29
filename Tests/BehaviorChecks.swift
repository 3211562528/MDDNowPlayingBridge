import Foundation

final class States: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Bool] = []
    func add(_ value: Bool) { lock.lock(); values.append(value); lock.unlock() }
    func snapshot() -> [Bool] { lock.lock(); defer { lock.unlock() }; return values }
}
@main struct BehaviorChecks {
    static func require(_ value: @autoclosure () -> Bool, _ name: String) {
        guard value() else { fatalError("FAIL: " + name) }
        print("PASS:", name)
    }
    static func wait(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<100 { if condition() { return true }; try? await Task.sleep(for: .milliseconds(20)) }
        return false
    }
    static func main() async throws {
        let a = PlaybackItem(id: "A", title: "Course A", coverURL: nil, pageSocketURL: URL(string: "ws://127.0.0.1:1/a")!)
        let b = PlaybackItem(id: "B", title: "Course B", coverURL: nil, pageSocketURL: URL(string: "ws://127.0.0.1:1/b")!)
        var gate = SessionGate()
        let time = Date(timeIntervalSince1970: 100)
        require(gate.item == nil, "No course creates no session")
        gate.accept(.item(a), at: time)
        require(gate.item == a, "Loaded course creates session")
        gate.accept(.unavailable, at: time.addingTimeInterval(1))
        require(gate.item == a, "Brief connection failure preserves course")
        gate.accept(.unavailable, at: time.addingTimeInterval(3))
        require(gate.item == nil, "Connection loss expires stale course")
        gate.accept(.item(a), at: time); gate.accept(.item(b), at: time)
        require(gate.item == b, "Switching course replaces identity and title")
        gate.accept(.none, at: time)
        require(gate.item == nil, "Closing player clears session immediately")
        gate.expire(at: time.addingTimeInterval(20))
        require(gate.item == nil, "Old state cannot recreate a closed course")
        require(MediaAction.backward.keyCode == 123 && MediaAction.forward.keyCode == 124, "System previous/next map to left/right")
        var parser = PlaybackLogParser()
        require(parser.append(Data([255,0]) + Data("IjkMediaPlayer::changeState, state: ".utf8)) == nil, "Partial log line waits for completion")
        require(parser.append(Data("0\n".utf8)) == true, "Invalid UTF-8 does not lose playback state")
        require(parser.append(Data("IjkMediaPlayer::changeState, state: 0\nIjkMediaPlayer::changeState, state: 1\n".utf8)) == false, "Last complete state wins")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("one.txt")
        try Data("IjkMediaPlayer::changeState, state: 1\n".utf8).write(to: file)
        let states = States()
        let monitor = PlaybackLogMonitor(directory: dir) { states.add($0) }
        monitor.start()
        let seeded = await wait { states.snapshot() == [false] }
        require(seeded, "Watcher initializes from existing paused state")
        let handle = try FileHandle(forWritingTo: file); try handle.seekToEnd()
        try handle.write(contentsOf: Data("IjkMediaPlayer::changeState, state: 0\n".utf8)); try handle.close()
        let appended = await wait { states.snapshot().last == true }
        require(appended, "Append notification updates state")
        let truncate = try FileHandle(forWritingTo: file); try truncate.truncate(atOffset: 0); try truncate.close()
        try? await Task.sleep(for: .milliseconds(50))
        let rewrite = try FileHandle(forWritingTo: file)
        try rewrite.write(contentsOf: Data("IjkMediaPlayer::changeState, state: 1\n".utf8)); try rewrite.close()
        let truncated = await wait { states.snapshot().last == false }
        require(truncated, "Truncated log resumes correctly")
        try Data("IjkMediaPlayer::changeState, state: 0\n".utf8).write(to: dir.appendingPathComponent("two.txt"))
        let rotated = await wait { states.snapshot().last == true }
        require(rotated, "Log rotation follows new file")
        monitor.stop()
    }
}
