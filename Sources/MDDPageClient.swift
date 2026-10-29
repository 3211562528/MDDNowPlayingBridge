import Foundation

private struct PageTarget: Decodable, Sendable {
    let id: String
    let type: String
    let url: String
    let title: String?
    let webSocketDebuggerUrl: String?
}
private struct PageFields: Decodable {
    let active: Bool
    let id: String?
    let title: String?
    let cover: String?
    let focused: Bool?
    let visible: Bool?
}
private struct Candidate: Sendable { let item: PlaybackItem; let focused: Bool; let visible: Bool }
private enum PageError: Error { case invalidResponse, remoteError }

private final class CDPConnection {
    private let socket: URLSessionWebSocketTask
    private let deadline: DispatchWorkItem
    private var sequence = 0
    init(url: URL) {
        let socket = URLSession.shared.webSocketTask(with: url)
        self.socket = socket
        let deadline = DispatchWorkItem { socket.cancel(with: .goingAway, reason: nil) }
        self.deadline = deadline
        socket.resume()
        DispatchQueue.global().asyncAfter(deadline: .now() + 2, execute: deadline)
    }
    func close() { deadline.cancel(); socket.cancel(with: .normalClosure, reason: nil) }
    func request(_ method: String, _ params: [String: Any] = [:]) async throws -> [String: Any] {
        sequence += 1
        let id = sequence
        let data = try JSONSerialization.data(withJSONObject: ["id": id, "method": method, "params": params])
        try await socket.send(.string(String(decoding: data, as: UTF8.self)))
        for _ in 0..<64 {
            try Task.checkCancellation()
            guard case .string(let text) = try await socket.receive(),
                  let root = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else { continue }
            if root["id"] as? Int == id {
                guard let result = root["result"] as? [String: Any] else { throw PageError.remoteError }
                return result
            }
        }
        throw PageError.invalidResponse
    }
}

actor MDDPageClient {
    private var process: Int32?
    private var ports: [Int] = []
    private var nextDiscovery = Date.distantPast
    private struct Inspection { let target: PageTarget; let candidate: Candidate?; let time: Date }
    private var inspections: [String: Inspection] = [:]
    private(set) var listRequests = 0
    private(set) var detailRequests = 0
    private(set) var portScans = 0
    private var preferredItemID: String?

    func observe(pid: Int32, forceRefresh: Bool = false) async -> PageObservation {
        if process != pid { process = pid; ports = []; nextDiscovery = .distantPast; preferredItemID = nil; inspections.removeAll() }
        if ports.isEmpty {
            guard Date() >= nextDiscovery else { return .unavailable }
            portScans += 1
            ports = Self.discoverPorts(pid: pid); nextDiscovery = Date().addingTimeInterval(2)
        }
        var targets: [PageTarget]?
        for port in ports {
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/json/list")!)
            request.timeoutInterval = 0.7
            listRequests += 1
            if let (data, response) = try? await URLSession.shared.data(for: request),
               let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
               let decoded = try? JSONDecoder().decode([PageTarget].self, from: data) {
                targets = decoded; ports = [port]; break
            }
        }
        guard let targets else { ports = []; return .unavailable }
        let videoPages = targets.filter {
            guard $0.type == "page", let url = URL(string: $0.url) else { return false }
            return url.host?.hasSuffix(".mddclass.com") == true && url.path.hasPrefix("/v/")
        }
        let liveIDs = Set(videoPages.map(\.id))
        inspections = inspections.filter { liveIDs.contains($0.key) }
        if videoPages.isEmpty { preferredItemID = nil; return .none }
        var candidates: [Candidate] = []
        var failures = 0
        for target in videoPages {
            do {
                let cached = inspections[target.id]
                let signatureMatches = cached?.target.url == target.url && cached?.target.title == target.title
                let ttl: TimeInterval = cached?.candidate == nil ? 1 : 10
                if !forceRefresh, signatureMatches, let cached, Date().timeIntervalSince(cached.time) < ttl {
                    if let candidate = cached.candidate { candidates.append(candidate) }
                } else {
                    detailRequests += 1
                    let candidate = try await Self.inspect(target, pid: pid)
                    inspections[target.id] = Inspection(target: target, candidate: candidate, time: Date())
                    if let candidate { candidates.append(candidate) }
                }
            } catch { failures += 1 }
        }
        let chosen = candidates.first(where: { $0.focused }) ?? candidates.first(where: { $0.item.id == preferredItemID && $0.visible }) ?? candidates.first(where: { $0.visible }) ?? candidates.first(where: { $0.item.id == preferredItemID }) ?? candidates.first
        if let chosen { preferredItemID = chosen.item.id; return .item(chosen.item) }
        return failures > 0 ? .unavailable : .none
    }

    private static func inspect(_ target: PageTarget, pid: Int32) async throws -> Candidate? {
        guard let text = target.webSocketDebuggerUrl, let socketURL = URL(string: text) else { throw PageError.invalidResponse }
        let connection = CDPConnection(url: socketURL); defer { connection.close() }
        let expression = #"JSON.stringify((()=>{const root=document.querySelector('[class*=video-page-container]');const key=root&&Object.keys(root).find(k=>k.startsWith('__reactInternalInstance')||k.startsWith('__reactFiber'));let f=key?root[key]:null;for(let i=0;f&&i<40;i++,f=f.return){const v=f.memoizedProps?.videoInfo;if(v&&v.videoId&&v.videoName)return {active:true,id:String(v.videoId),title:v.videoName,cover:v.coverUrl||null,focused:document.hasFocus(),visible:!document.hidden}}return {active:false}})())"#
        let result = try await connection.request("Runtime.evaluate", ["expression": expression, "returnByValue": true])
        guard let remote = result["result"] as? [String: Any], let value = remote["value"] as? String,
              let fields = try? JSONDecoder().decode(PageFields.self, from: Data(value.utf8)) else { throw PageError.invalidResponse }
        guard fields.active, let id = fields.id, let title = fields.title, !title.isEmpty else { return nil }
        return Candidate(item: PlaybackItem(id: "\(pid):\(id)", title: title, coverURL: fields.cover.flatMap(URL.init(string:)), pageSocketURL: socketURL), focused: fields.focused ?? false, visible: fields.visible ?? false)
    }

    nonisolated static func coverData(for item: PlaybackItem) async -> Data? {
        guard let cover = item.coverURL, cover.scheme == "https", cover.host?.hasSuffix(".sksight.com") == true else { return nil }
        let connection = CDPConnection(url: item.pageSocketURL)
        do {
            defer { connection.close() }
            _ = try await connection.request("Page.enable")
            let response = try await connection.request("Page.getResourceTree")
            if let tree = response["frameTree"] as? [String: Any], let location = resourceLocation(tree, matching: cover) {
                let body = try await connection.request("Page.getResourceContent", ["frameId": location.0, "url": location.1])
                if body["base64Encoded"] as? Bool == true, let text = body["content"] as? String, let data = Data(base64Encoded: text), data.count < 5_000_000 { return data }
            }
        } catch { connection.close() }
        guard !Task.isCancelled else { return nil }
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil; config.urlCache = nil; config.timeoutIntervalForRequest = 3; config.timeoutIntervalForResource = 4
        let session = URLSession(configuration: config); defer { session.finishTasksAndInvalidate() }
        guard let (data, response) = try? await session.data(from: cover), let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode), data.count < 5_000_000 else { return nil }
        return data
    }
    private nonisolated static func resourceLocation(_ tree: [String: Any], matching cover: URL) -> (String, String)? {
        if let frame = tree["frame"] as? [String: Any], let frameID = frame["id"] as? String,
           let resources = tree["resources"] as? [[String: Any]], let resource = resources.first(where: {
               guard let text = $0["url"] as? String, let url = URL(string: text) else { return false }
               return url.host == cover.host && url.path == cover.path
           }), let url = resource["url"] as? String { return (frameID, url) }
        for child in tree["childFrames"] as? [[String: Any]] ?? [] {
            if let location = resourceLocation(child, matching: cover) { return location }
        }
        return nil
    }
    private static func discoverPorts(pid: Int32) -> [Int] {
        let task = Process(); let pipe = Pipe()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        task.arguments = ["-nP", "-a", "-p", String(pid), "-iTCP", "-sTCP:LISTEN"]
        task.standardOutput = pipe; task.standardError = FileHandle.nullDevice
        do {
            try task.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile(); task.waitUntilExit()
            let text = String(decoding: data, as: UTF8.self)
            let regex = try NSRegularExpression(pattern: #"127\.0\.0\.1:(\d+)\s+\(LISTEN\)"#)
            return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
                guard let range = Range($0.range(at: 1), in: text) else { return nil }; return Int(text[range])
            }
        } catch { return [] }
    }
}
