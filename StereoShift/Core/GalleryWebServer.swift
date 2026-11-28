import Combine
import Foundation
import Network
import os
import Security

#if canImport(Darwin)
import Darwin
#endif

#if canImport(UIKit)
import UIKit
#endif

final class GalleryWebServer: ObservableObject {
    @Published private(set) var isSharingLiveVideo = false
    @Published private(set) var isRunning = false
    @Published private(set) var hostAddress: String?
    @Published private(set) var publicLink: WebShareLinkState = .connecting
    @Published private(set) var accessPIN: String = GalleryWebServer.loadOrCreateAccessPIN()
    @Published var errorMessage: String?

    private var httpListener: NWListener?
    private var httpsListener: NWListener?
    private var shareSessionID: UUID?
    private let runTunnel: GalleryQuickTunnel.Runner
    private var tunnelOrigin: NWListener?
    private let localAddress: () -> String?
    private var tunnelTask: Task<Void, Never>?
    private var tunnelAttempt: UUID?
    private var listenerAddress: String?
    private var localRecoveryTask: Task<Void, Never>?
    // These fields and the PIN attempt/token collections are confined to queue.
    private var servingID: UUID?
    private var localGeneration: UUID?
    private var tunnelGeneration: UUID?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var tunnelConnections: Set<ObjectIdentifier> = []
    // Live selection, scope and encoder ownership are confined to the same queue as PIN authentication.
    private var liveVideo: LiveWebVideo?
    private var liveOnly = false
    private var liveViewerCookie: String?
    private var liveConnection: NWConnection?
    private var liveTask: Task<Void, Never>?
    private var servingPIN = ""
    private let queue = DispatchQueue(label: "com.stereoshift.gallery-web-server", qos: .utility)
    private let pathMonitor = NWPathMonitor()
    private var holdsScreenAwakeLock = false
    private var memoryWarningObserver: NSObjectProtocol?
    private var failedAuthAttempts = 0
    private var authorizedSessionTokens: Set<String> = []

    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.huanglisen.StereoShift", category: "GalleryWebServer")
    private static let identityFilename = "WebShareIdentity"
    private static let identityExtension = "p12"
    private static let identityPassword = "StereoShiftLocalWebShare"
    private static let accessPINDefaultsKey = "galleryWebShareAccessPIN"
    private static let authCookieName = "stereoshift_session"
    private static let authPath = "/session-auth"
    private static let legacyAuthPath = "/auth"
    private static let maxFailedAuthAttempts = 10

    init(runTunnel: @escaping GalleryQuickTunnel.Runner = GalleryQuickTunnel.run, localAddress: @escaping () -> String? = GalleryWebServer.localShareIPv4Address) {
        self.runTunnel = runTunnel
        self.localAddress = localAddress
#if canImport(UIKit)
        memoryWarningObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.logMemoryFootprint("System memory warning received")
        }
#endif
        configureNetworkMonitor()
        refreshShareNetworkStatus()
    }

    deinit {
        if let memoryWarningObserver {
            NotificationCenter.default.removeObserver(memoryWarningObserver)
        }
        liveTask?.cancel()
        localRecoveryTask?.cancel()
        pathMonitor.cancel()
        tunnelOrigin?.cancel()
        tunnelTask?.cancel()
        httpListener?.cancel()
        httpsListener?.cancel()
        for connection in connections.values { connection.cancel() }
        releaseScreenAwakeLockIfNeeded()
    }

    func toggle() {
        if isRunning {
            stop()
        } else {
            start()
        }
    }

    func refreshNetworkStatus() {
        refreshShareNetworkStatus()
    }

    func restoreLocalSharingAfterBackground() {
        guard isRunning else { return }
        localRecoveryTask?.cancel()
        // Wi-Fi and the hotspot bridge can take a moment to return after unlock.
        // A hotspot-only change need not trigger the phone's default path monitor.
        localRecoveryTask = Task { @MainActor [weak self] in
            let delays = [1, 2, 4, 8, 16]
            for delay in delays {
                do { try await Task.sleep(for: .seconds(delay)) } catch { return }
                guard let self, self.isRunning, !Task.isCancelled else { return }
                if self.hostAddress != nil { break }
                if delay == delays.last { self.localRecoveryTask = nil }
                self.refreshShareNetworkStatus(rebind: true)
            }
            self?.localRecoveryTask = nil
        }
        // Suspension can invalidate a listener even when its advertised IP stays the same.
        refreshShareNetworkStatus(rebind: true)
    }

    func resetAccessPIN() {
        let newPIN = Self.generateAccessPIN()
        Self.saveAccessPIN(newPIN)
        accessPIN = newPIN
        queue.sync {
            self.cancelLivePlayback()
            self.servingPIN = newPIN
            self.failedAuthAttempts = 0
            self.authorizedSessionTokens.removeAll()
        }
    }

    @MainActor
    func shareLiveVideo(_ source: LiveWebVideo, access: SubscriptionManager) {
        guard access.canAccessVideo else { return }
        let startingNewShare = !isRunning
        queue.sync {
            cancelLivePlayback()
            if startingNewShare { liveOnly = true }
            liveVideo = source
        }
        isSharingLiveVideo = true
        if startingNewShare { start() }
    }

    func removeLiveVideo() {
        guard isSharingLiveVideo else { return }
        let shouldStop = queue.sync {
            cancelLivePlayback()
            liveVideo = nil
            return liveOnly
        }
        isSharingLiveVideo = false
        if shouldStop { stop() }
    }

    private func cancelLivePlayback() {
        liveTask?.cancel()
        liveTask = nil
        liveViewerCookie = nil
        liveConnection?.cancel()
        liveConnection = nil
    }

    func start() {
        guard !isRunning else { return }
        let id = UUID()
        let pin = Self.loadOrCreateAccessPIN()
        accessPIN = pin
        errorMessage = nil
        shareSessionID = id
        queue.async {
            self.servingID = id
            self.servingPIN = pin
            self.failedAuthAttempts = 0
            self.authorizedSessionTokens.removeAll()
        }
        isRunning = true
        acquireScreenAwakeLockIfNeeded()
        refreshShareNetworkStatus()
        retryPublicLink()
    }

    func retryPublicLink() {
        guard let id = shareSessionID else { return }
        stopTunnel()
        let attempt = UUID()
        tunnelAttempt = attempt
        publicLink = .connecting
        let key = UUID().uuidString
        do {
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
            let listener = try NWListener(using: parameters)
            queue.sync { tunnelGeneration = attempt }
            tunnelOrigin = listener
            listener.newConnectionHandler = { [weak self] connection in
                guard let self, self.servingID == id, self.tunnelGeneration == attempt else { connection.cancel(); return }
                self.handle(connection: connection, publicShare: true) { request in
                    guard self.servingID == id, self.tunnelGeneration == attempt, request.headers["x-stereoshift-origin"] == key else {
                        return GalleryHTTPResponse(403)
                    }
                    return self.route(request, publicShare: true)
                }
            }
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                DispatchQueue.main.async {
                    guard let self, self.tunnelAttempt == attempt else { return }
                    switch state {
                    case .ready:
                        guard let port = listener?.port else { self.publicLinkFailed(); return }
                        let run = self.runTunnel
                        self.tunnelTask = Task { @MainActor [weak self] in
                            do {
                                try await run(port.rawValue, key) { [weak self] url in
                                    guard self?.tunnelAttempt == attempt else { return }
                                    self?.publicLink = .ready(url)
                                }
                            } catch {}
                            if self?.tunnelAttempt == attempt { self?.publicLinkFailed() }
                        }
                    case .failed: self.publicLinkFailed()
                    default: break
                    }
                }
            }
            listener.start(queue: queue)
        } catch {
            publicLinkFailed()
        }
    }

    private func publicLinkFailed() {
        stopTunnel()
        publicLink = .unavailable
    }

    private func stopTunnel() {
        tunnelAttempt = nil
        tunnelTask?.cancel()
        tunnelTask = nil
        tunnelOrigin?.cancel()
        tunnelOrigin = nil
        queue.sync {
            tunnelGeneration = nil
            for key in tunnelConnections { connections.removeValue(forKey: key)?.cancel() }
            tunnelConnections.removeAll()
        }
    }

    func stop() {
        localRecoveryTask?.cancel()
        localRecoveryTask = nil
        stopTunnel()
        shareSessionID = nil
        stopLocalListeners()
        // Take this barrier before returning so late requests cannot use the old session.
        queue.sync {
            servingID = nil
            cancelLivePlayback()
            liveVideo = nil
            liveOnly = false
            authorizedSessionTokens.removeAll()
        }
        isRunning = false
        isSharingLiveVideo = false
        publicLink = .connecting
        releaseScreenAwakeLockIfNeeded()
    }

    private func stopLocalListeners() {
        httpListener?.cancel()
        httpsListener?.cancel()
        httpListener = nil
        httpsListener = nil
        listenerAddress = nil
        hostAddress = nil
        queue.sync {
            localGeneration = nil
            for key in Array(connections.keys) where !tunnelConnections.contains(key) {
                connections.removeValue(forKey: key)?.cancel()
            }
        }
    }

    private func configureNetworkMonitor() {
        pathMonitor.pathUpdateHandler = { [weak self] _ in
            guard let self else { return }
            DispatchQueue.main.async {
                self.refreshShareNetworkStatus()
            }
        }
        pathMonitor.start(queue: queue)
    }

    private func refreshShareNetworkStatus(rebind: Bool = false) {
        guard isRunning else { return }
        let address = localAddress()
        guard rebind || address != listenerAddress else { return }
        stopLocalListeners()
        guard let address else { return }
        do {
            let generation = UUID()
            let https = try Self.makeHTTPSParameters()
            let http = NWParameters.tcp
            http.allowLocalEndpointReuse = true
            // iOS permits these well-known ports on wildcard listeners. Only advertise
            // while a LAN address exists, and exclude cellular from inbound connections.
            http.prohibitedInterfaceTypes = [.cellular]
            https.prohibitedInterfaceTypes = [.cellular]
            httpsListener = try NWListener(using: https, on: 443)
            httpListener = try NWListener(using: http, on: 80)
            listenerAddress = address
            queue.sync { localGeneration = generation }
            for (listener, isTLS) in [(httpsListener, true), (httpListener, false)] {
                guard let listener else { continue }
                listener.stateUpdateHandler = { [weak self, weak listener] state in
                    DispatchQueue.main.async { [weak self, weak listener] in
                        guard let self, let listener,
                              listener === (isTLS ? self.httpsListener : self.httpListener) else { return }
                        switch state {
                        case .ready:
                            if self.httpsListener?.state == .ready && self.httpListener?.state == .ready {
                                self.hostAddress = address
                            }
                        case .waiting:
                            self.hostAddress = nil
                        case .failed(let error):
                            self.localListenersFailed(error)
                        default: break
                        }
                    }
                }
                listener.newConnectionHandler = { [weak self] connection in
                    guard let self, self.localGeneration == generation else { connection.cancel(); return }
                    self.handle(connection: connection, publicShare: false) { request in
                        guard self.localGeneration == generation else { return GalleryHTTPResponse(410) }
                        if isTLS { return self.route(request) }
                        let url = "https://\(address)\(request.pathAndQuery)"
                        return GalleryHTTPResponse(200, Self.httpUpgradeHTML(httpsURL: url),
                                                   headers: ["Content-Type": "text/html; charset=utf-8"])
                    }
                }
                listener.start(queue: queue)
            }
        } catch {
            localListenersFailed(error)
        }
    }

    private func localListenersFailed(_ error: Error) {
        stopLocalListeners()
        if localRecoveryTask == nil {
            errorMessage = Self.describe(error: error)
        }
    }

    private func handle(connection: NWConnection, publicShare: Bool, respond: @escaping (GalleryHTTPRequest) -> GalleryHTTPResponse) {
        let key = ObjectIdentifier(connection)
        connections[key] = connection
        if publicShare { tunnelConnections.insert(key) }
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                if let active = self?.liveConnection, ObjectIdentifier(active) == key { self?.cancelLivePlayback() }
                self?.connections.removeValue(forKey: key)
                self?.tunnelConnections.remove(key)
            default: break
            }
        }
        connection.start(queue: queue)
        var received = Data()
        let delimiter = Data("\r\n\r\n".utf8)

        func receiveNextChunk() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
                guard let self else {
                    connection.cancel()
                    return
                }

                if let _ = error {
                    connection.cancel()
                    return
                }

                if let data, !data.isEmpty {
                    received.append(data)
                }

                if received.range(of: delimiter) != nil {
                    guard self.connections[key] != nil else { connection.cancel(); return }
                    let request = GalleryHTTPRequest.parse(data: received)
                    let response: GalleryHTTPResponse
                    if let request {
                        if request.method != "GET" && request.method != "HEAD" {
                            response = GalleryHTTPResponse(405)
                        } else {
                            response = respond(request)
                        }
                    } else {
                        response = GalleryHTTPResponse(400)
                    }
                    self.send(response, headOnly: request?.method == "HEAD", on: connection, viewerCookie: request?.headers["cookie"])
                    return
                }

                if isComplete || received.count > 128 * 1024 {
                    self.send(GalleryHTTPResponse(400), headOnly: false, on: connection)
                    return
                }

                receiveNextChunk()
            }
        }

        receiveNextChunk()
    }

    private func route(_ request: GalleryHTTPRequest, publicShare: Bool = false) -> GalleryHTTPResponse {
        guard servingID != nil else { return GalleryHTTPResponse(410) }
        if request.path == Self.authPath || request.path == Self.legacyAuthPath {
            return handlePINAttempt(request.queryItems["pin"] ?? "", publicShare: publicShare)
        }
        if let code = request.queryItems["code"], !code.isEmpty, !isAuthorized(request: request) {
            return handlePINAttempt(code, publicShare: publicShare)
        }
        guard isAuthorized(request: request) else {
            if request.path == "/" { return pinPage(publicShare: publicShare) }
            return GalleryHTTPResponse(302, headers: ["Location": "/", "Set-Cookie": Self.clearAuthenticationCookieHeader(secure: true)])
        }
        switch request.path {
        case "/":
            return GalleryHTTPResponse(200, Self.galleryHTML, headers: ["Content-Type": "text/html; charset=utf-8"])
        case "/api/items":
            return itemsJSON(request)
        default:
            if request.path.hasPrefix("/live/") {
                guard let liveVideo, request.path == liveVideo.path else { return GalleryHTTPResponse(404) }
                return GalleryHTTPResponse(liveVideo: liveVideo)
            }
            guard !liveOnly else { return GalleryHTTPResponse(404) }
            let isThumb = request.path.hasPrefix("/thumb/")
            guard isThumb || request.path.hasPrefix("/media/"),
                  let item = item(forPath: request.path, prefix: isThumb ? "/thumb/" : "/media/") else { return GalleryHTTPResponse(404) }
            if isThumb {
                guard let cover = AppGalleryLibrary.leftEyeThumbnail(for: item, rebuild: request.queryItems["rebuild"] == "1"),
                      let jpeg = try? AppGalleryLibrary.jpegData(for: cover) else { return GalleryHTTPResponse(404) }
                return byteResponse(request, size: Int64(jpeg.count), contentType: "image/jpeg") { offset, length in
                    let bytes = offset == 0 && length == jpeg.count ? jpeg : jpeg.subdata(in: Int(offset)..<Int(offset + length))
                    return GalleryResponseBody(bytes)
                }
            }
            return fileResponse(item.url, request: request)
        }
    }

    private func pinPage(_ message: String? = nil, publicShare: Bool) -> GalleryHTTPResponse {
        let html = Self.accessPINHTML(message: message, remainingAttempts: Self.maxFailedAuthAttempts - failedAuthAttempts, publicShare: publicShare)
        return GalleryHTTPResponse(200, html, headers: ["Content-Type": "text/html; charset=utf-8",
                                                        "Set-Cookie": Self.clearAuthenticationCookieHeader(secure: true)])
    }

    private func handlePINAttempt(_ raw: String, publicShare: Bool) -> GalleryHTTPResponse {
        let pin = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard pin.count == 4, pin.allSatisfy(\.isNumber) else { return pinPage("Enter a valid 4-digit PIN.", publicShare: publicShare) }
        guard pin == servingPIN else {
            failedAuthAttempts += 1
            let remaining = Self.maxFailedAuthAttempts - failedAuthAttempts
            guard remaining > 0 else {
                let id = servingID
                servingID = nil
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.shareSessionID == id else { return }
                    self.stop()
                    self.errorMessage = NSLocalizedString("Web Share stopped after 10 incorrect PIN attempts.", comment: "")
                }
                return GalleryHTTPResponse(403, "Too many incorrect PIN attempts. Web Share has stopped.")
            }
            return pinPage("Incorrect PIN. \(remaining) attempts remaining.", publicShare: publicShare)
        }
        failedAuthAttempts = 0
        let token = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        authorizedSessionTokens.insert(token)
        return GalleryHTTPResponse(303, headers: ["Location": "/", "Set-Cookie": Self.authenticationCookieHeader(for: token, secure: true)])
    }

    private func isAuthorized(request: GalleryHTTPRequest) -> Bool {
        guard let cookieHeader = request.headers["cookie"] else {
            return false
        }

        var hasSessionCookie = false
        for cookie in cookieHeader.split(separator: ";") {
            let trimmedCookie = cookie.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let separator = trimmedCookie.firstIndex(of: "=") else { continue }

            let name = trimmedCookie[..<separator]
            let value = trimmedCookie[trimmedCookie.index(after: separator)...]
            if name == Self.authCookieName {
                hasSessionCookie = true
                if authorizedSessionTokens.contains(String(value)) {
                    return true
                }
            }
        }

        if hasSessionCookie {
            Self.logger.debug("Session cookie present but no active token matched; treating request as unauthorized")
        }
        return false
    }

    private func itemsJSON(_ request: GalleryHTTPRequest) -> GalleryHTTPResponse {
        let offset = max(Int(request.queryItems["offset"] ?? "") ?? 0, 0)
        let limit = min(max(Int(request.queryItems["limit"] ?? "") ?? 200, 1), 500)

        do {
            let allItems = liveOnly ? [] : try AppGalleryLibrary.loadItemsForWeb()
            let slice = allItems.dropFirst(offset).prefix(limit)
            var payloadItems: [GalleryPayloadItem] = []
            payloadItems.reserveCapacity(slice.count)

            let formatter = ISO8601DateFormatter()

            for item in slice {
                let encodedID = Self.encodedPathComponent(item.id)

                payloadItems.append(
                    GalleryPayloadItem(
                        id: item.id,
                        type: item.type.rawValue,
                        createdAt: formatter.string(from: item.createdAt),
                        mediaPath: "/media/\(encodedID)",
                        thumbnailPath: "/thumb/\(encodedID)"
                    )
                )
            }

            let payload = GalleryPayload(liveVideoPath: liveVideo?.path, liveOnly: liveOnly, items: payloadItems,
                                         hasMore: offset + payloadItems.count < allItems.count)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.withoutEscapingSlashes]
            let body = try encoder.encode(payload)

            return GalleryHTTPResponse(200, ["Content-Type": "application/json; charset=utf-8"], body: GalleryResponseBody(body))
        } catch {
            return GalleryHTTPResponse(500, "Failed to load gallery.")
        }
    }

    private func item(forPath path: String, prefix: String) -> GalleryItem? {
        let encodedID = String(path.dropFirst(prefix.count))
        let decodedID = encodedID.removingPercentEncoding ?? encodedID

        return AppGalleryLibrary.itemForWeb(named: decodedID)
    }

    private func fileResponse(_ url: URL, request: GalleryHTTPRequest) -> GalleryHTTPResponse {
        do {
            // Measure and stream the same open file.
            let file = try FileHandle(forReadingFrom: url)
            let size = Int64(try file.seekToEnd())
            return try byteResponse(request, size: size, contentType: Self.contentType(for: url) ?? "application/octet-stream") {
                try GalleryResponseBody(file: file, offset: $0, length: $1)
            }
        } catch {
            return GalleryHTTPResponse(500, "Failed to read file.")
        }
    }

    private func byteResponse(_ request: GalleryHTTPRequest, size: Int64, contentType: String,
                              makeBody: (Int64, Int64) throws -> GalleryResponseBody) rethrows -> GalleryHTTPResponse {
        var headers = ["Content-Type": contentType, "Accept-Ranges": "bytes"]
        var offset: Int64 = 0
        var length = size
        var status = 200
        if let header = request.headers["range"] {
            guard let range = Self.byteRange(from: header, fileSize: size) else {
                return GalleryHTTPResponse(416, headers: ["Content-Range": "bytes */\(size)", "Accept-Ranges": "bytes"])
            }
            offset = range.lowerBound
            length = range.upperBound - offset + 1
            status = 206
            headers["Content-Range"] = "bytes \(offset)-\(range.upperBound)/\(size)"
        }
        let body = request.method == "HEAD" ? GalleryResponseBody(Data()) : try makeBody(offset, length)
        return GalleryHTTPResponse(status, headers, body: body, length: length)
    }

    private func send(_ response: GalleryHTTPResponse, headOnly: Bool, on connection: NWConnection, viewerCookie: String? = nil) {
        if let video = response.liveVideo {
            sendLiveVideo(video, headOnly: headOnly, on: connection, viewerCookie: viewerCookie)
            return
        }
        var headers = response.headers
        headers["Content-Length"] = String(response.length)
        headers["Connection"] = "close"
        let lines = headers.map { "\($0.key): \($0.value)" }.joined(separator: "\r\n")
        let head = "HTTP/1.1 \(response.status) \(HTTPURLResponse.localizedString(forStatusCode: response.status))\r\n\(lines)\r\n\r\n"
        func sendNext(_ error: NWError?) {
            guard error == nil, !headOnly, response.body.remaining > 0,
                  connections[ObjectIdentifier(connection)] != nil,
                  let data = try? response.body.read() else { connection.cancel(); return }
            connection.send(content: data, completion: .contentProcessed(sendNext))
        }
        connection.send(content: Data(head.utf8), completion: .contentProcessed(sendNext))
    }

    private func sendLiveVideo(_ video: LiveWebVideo, headOnly: Bool, on connection: NWConnection, viewerCookie: String?) {
        if !headOnly, liveConnection != nil {
            // A replay/reload can arrive before the previous socket reports that the viewer closed it.
            guard let viewerCookie, viewerCookie == liveViewerCookie else {
                send(GalleryHTTPResponse(409, "A viewer is already watching this video."), headOnly: false, on: connection)
                return
            }
            cancelLivePlayback()
        }
        let headers = "HTTP/1.1 200 OK\r\nContent-Type: video/mp4\r\nCache-Control: private, no-store\r\nAccept-Ranges: none\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n"
        if headOnly {
            connection.send(content: Data(headers.utf8), completion: .contentProcessed { _ in connection.cancel() })
            return
        }
        liveViewerCookie = viewerCookie
        liveConnection = connection
        liveTask = Task.detached(priority: .userInitiated) {
            defer { connection.cancel() }
            do {
                try await Self.write(Data(headers.utf8), on: connection)
                try Task.checkCancellation()
                let encoder = LiveWebEncoder()
                let producer = encoder.start(video)
                defer { producer.cancel() }
                for try await fragment in encoder.fragments {
                    try Task.checkCancellation()
                    var chunk = Data((String(fragment.count, radix: 16) + "\r\n").utf8)
                    chunk.append(fragment)
                    chunk.append(contentsOf: "\r\n".utf8)
                    try await Self.write(chunk, on: connection)
                    encoder.didSend(fragment.count)
                }
                try Task.checkCancellation()
                try await Self.write(Data("0\r\n\r\n".utf8), on: connection)
            } catch {
                // Closing without the final chunk signals an interrupted conversion to the player.
                if !Task.isCancelled { Self.logger.debug("Live Web Share ended: \(error.localizedDescription, privacy: .public)") }
            }
        }
    }

    private static func write(_ data: Data, on connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            })
        }
    }

    private func logMemoryFootprint(_ label: String) {
        guard let bytes = Self.currentMemoryFootprintBytes() else {
            Self.logger.debug("\(label, privacy: .public) | memory footprint unavailable")
            return
        }

        let mbString = String(format: "%.1f", Double(bytes) / 1_048_576)
        Self.logger.notice("\(label, privacy: .public) | app footprintMB=\(mbString, privacy: .public)")
    }

    private static func currentMemoryFootprintBytes() -> UInt64? {
#if canImport(Darwin)
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.stride / MemoryLayout<integer_t>.stride)
        let kerr: kern_return_t = withUnsafeMutablePointer(to: &info) { infoPointer in
            infoPointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPointer in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), intPointer, &count)
            }
        }

        guard kerr == KERN_SUCCESS else {
            return nil
        }
        return info.phys_footprint
#else
        return nil
#endif
    }

    private func acquireScreenAwakeLockIfNeeded() {
        guard !holdsScreenAwakeLock else { return }
        holdsScreenAwakeLock = true
        ScreenAwakeManager.shared.acquire()
    }

    private func releaseScreenAwakeLockIfNeeded() {
        guard holdsScreenAwakeLock else { return }
        holdsScreenAwakeLock = false
        ScreenAwakeManager.shared.release()
    }

    private static func loadOrCreateAccessPIN() -> String {
        let defaults = UserDefaults.standard
        if let existingPIN = defaults.string(forKey: accessPINDefaultsKey),
           existingPIN.count == 4,
           existingPIN.allSatisfy(\.isNumber) {
            return existingPIN
        }

        let generatedPIN = generateAccessPIN()
        defaults.set(generatedPIN, forKey: accessPINDefaultsKey)
        return generatedPIN
    }

    private static func saveAccessPIN(_ pin: String) {
        UserDefaults.standard.set(pin, forKey: accessPINDefaultsKey)
    }

    private static func generateAccessPIN() -> String {
        String(format: "%04d", Int.random(in: 0...9999))
    }

    private static func authenticationCookieHeader(for token: String, secure: Bool) -> String {
        var attributes = "\(authCookieName)=\(token); Path=/; HttpOnly; SameSite=Lax"
        if secure {
            attributes += "; Secure"
        }
        return attributes
    }

    private static func clearAuthenticationCookieHeader(secure: Bool) -> String {
        var attributes = "\(authCookieName)=; Path=/; HttpOnly; SameSite=Lax; Max-Age=0"
        if secure {
            attributes += "; Secure"
        }
        return attributes
    }

    private static func makeHTTPSParameters() throws -> NWParameters {
        let identity = try loadTLSIdentity()
        let tlsOptions = NWProtocolTLS.Options()

        sec_protocol_options_set_min_tls_protocol_version(tlsOptions.securityProtocolOptions, .TLSv12)
        sec_protocol_options_set_local_identity(tlsOptions.securityProtocolOptions, identity)

        let parameters = NWParameters(tls: tlsOptions, tcp: NWProtocolTCP.Options())
        parameters.allowLocalEndpointReuse = true
        parameters.includePeerToPeer = true
        return parameters
    }

    private static func loadTLSIdentity() throws -> sec_identity_t {
        guard let p12URL = Bundle.main.url(forResource: identityFilename, withExtension: identityExtension) else {
            throw NSError(
                domain: "GalleryWebServer",
                code: 1001,
                userInfo: [NSLocalizedDescriptionKey: "Missing bundled TLS identity."]
            )
        }

        let p12Data = try Data(contentsOf: p12URL)
        let options: [String: Any] = [
            kSecImportExportPassphrase as String: identityPassword
        ]

        var importedItems: CFArray?
        let status = SecPKCS12Import(p12Data as CFData, options as CFDictionary, &importedItems)

        guard status == errSecSuccess,
              let importedItems,
              let item = (importedItems as? [[String: Any]])?.first,
              let identityValue = item[kSecImportItemIdentity as String] else {
            throw NSError(
                domain: "GalleryWebServer",
                code: 1002,
                userInfo: [NSLocalizedDescriptionKey: "Could not load TLS identity from bundle."]
            )
        }

        let identity = identityValue as! SecIdentity
        return sec_identity_create(identity)! // swiftlint:disable:this force_unwrapping
    }

    private static func describe(error: Error) -> String {
        let nsError = error as NSError
        if nsError.domain == NSPOSIXErrorDomain {
            switch nsError.code {
            case 13:
                return "Permission denied while binding server ports 80/443."
            case 48:
                return "Ports 80/443 are already in use by another app."
            default:
                break
            }
        }

        return error.localizedDescription
    }

    private static func byteRange(from header: String, fileSize: Int64) -> ClosedRange<Int64>? {
        guard fileSize > 0 else {
            return nil
        }

        let trimmed = header.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("bytes=") else {
            return nil
        }

        let value = String(trimmed.dropFirst("bytes=".count))
        guard let firstRange = value.split(separator: ",").first else {
            return nil
        }

        let parts = firstRange.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2 else {
            return nil
        }

        if parts[0].isEmpty {
            guard let suffixLength = Int64(parts[1]), suffixLength > 0 else {
                return nil
            }

            let length = min(suffixLength, fileSize)
            let start = fileSize - length
            return start...(fileSize - 1)
        }

        guard let start = Int64(parts[0]), start >= 0, start < fileSize else {
            return nil
        }

        let end: Int64
        if parts[1].isEmpty {
            end = fileSize - 1
        } else {
            guard let parsedEnd = Int64(parts[1]), parsedEnd >= start else {
                return nil
            }
            end = min(parsedEnd, fileSize - 1)
        }

        return start...end
    }

    private static func contentType(for fileURL: URL) -> String? {
        let fileExtension = fileURL.pathExtension.lowercased()

        switch fileExtension {
        case "jpg", "jpeg": return "image/jpeg"
        case "png": return "image/png"
        case "heic", "heif": return "image/heic"
        case "webp": return "image/webp"
        case "mp4": return "video/mp4"
        case "mov": return "video/quicktime"
        case "m4v": return "video/x-m4v"
        default: return nil
        }
    }

    private static func encodedPathComponent(_ raw: String) -> String {
        raw.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? raw
    }

    /// Interfaces Web Share can bind to. `en0`-`en2` cover a normal Wi-Fi LAN; `bridge*`
    /// (usually `bridge100`) covers Personal Hotspot, where the phone is the router at
    /// 172.20.10.1 and `en0` carries no IPv4 address because it is enslaved to the bridge.
    /// Cellular (`pdp_ip*`) is excluded — it is not a local network.
    private static func isShareableInterfaceName(_ name: String) -> Bool {
        name == "en0" || name == "en1" || name == "en2" || name.hasPrefix("bridge")
    }

    static func localShareIPv4Address() -> String? {
#if canImport(Darwin)
        var ifaddrPointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrPointer) == 0, let firstAddress = ifaddrPointer else {
            return nil
        }
        defer {
            freeifaddrs(ifaddrPointer)
        }

        let preferredInterfaces = ["en0", "en1", "en2"]
        var candidates: [(name: String, ip: String)] = []

        var pointer = firstAddress
        while true {
            let interface = pointer.pointee
            guard let addressPointer = interface.ifa_addr else {
                if let next = interface.ifa_next {
                    pointer = next
                    continue
                }
                break
            }

            let family = addressPointer.pointee.sa_family
            let flags = Int32(interface.ifa_flags)
            let isUp = (flags & IFF_UP) != 0
            let isRunning = (flags & IFF_RUNNING) != 0
            let isLoopback = (flags & IFF_LOOPBACK) != 0

            if family == UInt8(AF_INET), isUp, isRunning, !isLoopback, let nameCString = interface.ifa_name {
                let name = String(cString: nameCString)
                if isShareableInterfaceName(name) {
                    var address = addressPointer.pointee
                    var hostBuffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))

                    let result = getnameinfo(
                        &address,
                        socklen_t(addressPointer.pointee.sa_len),
                        &hostBuffer,
                        socklen_t(hostBuffer.count),
                        nil,
                        0,
                        NI_NUMERICHOST
                    )

                    if result == 0 {
                        let ipAddress = String(cString: hostBuffer)
                        if ipAddress != "127.0.0.1", !ipAddress.hasPrefix("169.254.") {
                            candidates.append((name: name, ip: ipAddress))
                        }
                    }
                }
            }

            guard let next = interface.ifa_next else {
                break
            }
            pointer = next
        }

        if candidates.isEmpty {
            return nil
        }

        // Prefer a Wi-Fi LAN: a router-assigned private address is what other devices on the
        // same network expect to reach.
        for interfaceName in preferredInterfaces {
            if let match = candidates.first(where: { $0.name == interfaceName && isPrivateIPv4($0.ip) }) {
                return match.ip
            }
        }

        // Still prefer Wi-Fi when its address is outside RFC1918 (CGNAT 100.64/10 on some
        // carrier and venue networks), so an active LAN wins over the hotspot either way.
        for interfaceName in preferredInterfaces {
            if let match = candidates.first(where: { $0.name == interfaceName }) {
                return match.ip
            }
        }

        // Then Personal Hotspot, where clients joined to the phone reach the listener on the
        // bridge address. Tethering over USB/Bluetooth can leave Wi-Fi associated at the same
        // time, which is why this is ranked last rather than merged into the tiers above.
        return candidates.first(where: { isPrivateIPv4($0.ip) })?.ip ?? candidates.first?.ip
#else
        return nil
#endif
    }

    private static func isPrivateIPv4(_ address: String) -> Bool {
        let parts = address.split(separator: ".")
        guard parts.count == 4 else {
            return false
        }

        guard
            let first = Int(parts[0]),
            let second = Int(parts[1])
        else {
            return false
        }

        if first == 10 {
            return true
        }

        if first == 172, (16...31).contains(second) {
            return true
        }

        if first == 192, second == 168 {
            return true
        }

        return false
    }

    private static func accessPINHTML(message: String?, remainingAttempts: Int, publicShare: Bool) -> String {
        let sanitizedMessage = escapeHTML(message ?? "")
        let messageHTML: String
        if sanitizedMessage.isEmpty {
            messageHTML = ""
        } else {
            messageHTML = "<p class=\"message\">\(sanitizedMessage)</p>"
        }

        return """
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width,initial-scale=1" />
  <title>StereoShift Web Share</title>
  <style>
    :root {
      --bg: #060b1a;
      --bg2: #0c1630;
      --card: rgba(16, 26, 52, 0.86);
      --card-border: rgba(130, 165, 255, 0.26);
      --text: #eef3ff;
      --muted: #a9bbe7;
      --accent: #43d0ff;
      --accent2: #8d6bff;
      --danger: #ff8297;
      --shadow: 0 18px 42px rgba(0, 0, 0, 0.38);
    }

    @media (prefers-color-scheme: light) {
      :root {
        --bg: #eef4ff;
        --bg2: #dfe9ff;
        --card: rgba(255, 255, 255, 0.92);
        --card-border: rgba(79, 110, 180, 0.25);
        --text: #13213f;
        --muted: #4e648f;
        --accent: #2a96ff;
        --accent2: #6158ff;
        --danger: #df2f4d;
        --shadow: 0 14px 32px rgba(36, 62, 118, 0.16);
      }
    }

    :root[data-theme="dark"] {
      --bg: #060b1a;
      --bg2: #0c1630;
      --card: rgba(16, 26, 52, 0.86);
      --card-border: rgba(130, 165, 255, 0.26);
      --text: #eef3ff;
      --muted: #a9bbe7;
      --accent: #43d0ff;
      --accent2: #8d6bff;
      --danger: #ff8297;
      --shadow: 0 18px 42px rgba(0, 0, 0, 0.38);
    }

    :root[data-theme="light"] {
      --bg: #eef4ff;
      --bg2: #dfe9ff;
      --card: rgba(255, 255, 255, 0.92);
      --card-border: rgba(79, 110, 180, 0.25);
      --text: #13213f;
      --muted: #4e648f;
      --accent: #2a96ff;
      --accent2: #6158ff;
      --danger: #df2f4d;
      --shadow: 0 14px 32px rgba(36, 62, 118, 0.16);
    }

    * { box-sizing: border-box; }

    body {
      margin: 0;
      min-height: 100vh;
      display: grid;
      place-items: center;
      padding: 18px;
      color: var(--text);
      font-family: "SF Pro Text", "Segoe UI", -apple-system, BlinkMacSystemFont, sans-serif;
      background: radial-gradient(circle at 18% 10%, rgba(26, 42, 86, 0.8) 0%, transparent 36%),
                  radial-gradient(circle at 80% 0%, rgba(28, 23, 66, 0.8) 0%, transparent 34%),
                  linear-gradient(180deg, var(--bg) 0%, var(--bg2) 100%);
    }

    .card {
      width: min(460px, 100%);
      padding: 24px;
      border-radius: 18px;
      border: 1px solid var(--card-border);
      background: var(--card);
      box-shadow: var(--shadow);
      backdrop-filter: blur(12px);
    }

    h1 {
      margin: 0 0 8px;
      font-size: clamp(22px, 3vw, 30px);
      font-weight: 760;
      letter-spacing: 0.2px;
    }

    p {
      margin: 0;
      line-height: 1.45;
    }

    .subtitle {
      color: var(--muted);
      margin-bottom: 16px;
      font-size: 14px;
    }

    form {
      display: grid;
      gap: 10px;
    }

    label {
      font-size: 13px;
      color: #dce7ff;
    }

    input {
      width: 100%;
      padding: 12px 14px;
      border-radius: 12px;
      border: 1px solid rgba(146, 175, 247, 0.34);
      background: rgba(11, 17, 35, 0.72);
      color: var(--text);
      font-size: 22px;
      letter-spacing: 0.28em;
      text-align: center;
      outline: none;
    }

    input:focus {
      border-color: rgba(108, 202, 255, 0.72);
      box-shadow: 0 0 0 3px rgba(67, 208, 255, 0.2);
    }

    button {
      appearance: none;
      border: 0;
      border-radius: 12px;
      padding: 12px 16px;
      color: var(--text);
      font-size: 15px;
      font-weight: 650;
      cursor: pointer;
      background: linear-gradient(130deg, #1fb5ff 0%, #7664ff 100%);
      box-shadow: 0 8px 24px rgba(31, 181, 255, 0.34);
    }

    .hint {
      margin-top: 14px;
      font-size: 13px;
      color: var(--muted);
    }

    .message {
      margin-top: 14px;
      color: var(--danger);
      background: rgba(159, 19, 51, 0.28);
      border: 1px solid rgba(255, 115, 140, 0.44);
      padding: 10px 12px;
      border-radius: 10px;
      font-size: 13px;
    }

    .topbar {
      display: flex;
      align-items: center;
      justify-content: space-between;
      gap: 12px;
      margin-bottom: 8px;
    }

    .theme {
      display: inline-flex;
      align-items: center;
      gap: 8px;
      font-size: 13px;
      color: var(--muted);
      user-select: none;
    }

    select {
      appearance: none;
      border: 1px solid rgba(146, 175, 247, 0.34);
      background: rgba(11, 17, 35, 0.12);
      color: var(--text);
      padding: 8px 12px;
      border-radius: 12px;
      font-size: 13px;
      cursor: pointer;
      outline: none;
    }

    select:focus {
      border-color: rgba(108, 202, 255, 0.72);
      box-shadow: 0 0 0 3px rgba(67, 208, 255, 0.2);
    }
  </style>
</head>
<body>
  <script>
    (function initTheme() {
      try {
        const key = 'stereoshift_theme_auth';
        const saved = localStorage.getItem(key) || 'system';
        const select = document.getElementById('theme');
        if (select) {
          select.value = saved;
          select.addEventListener('change', () => {
            const value = select.value || 'system';
            localStorage.setItem(key, value);
            apply(value);
          });
        }
        apply(saved);

        function apply(value) {
          if (value === 'system') {
            document.documentElement.removeAttribute('data-theme');
            return;
          }
          document.documentElement.setAttribute('data-theme', value);
        }
      } catch (_) {}
    })();
  </script>
  <section class="card">
    <div class="topbar">
      <h1>StereoShift Web Share</h1>
      <div class="theme">
        <span>Theme</span>
        <select id="theme" aria-label="Theme">
          <option value="system">System</option>
          <option value="dark">Dark</option>
          <option value="light">Light</option>
        </select>
      </div>
    </div>
    <p class="subtitle">Enter the 4-digit PIN shown in the app to continue.</p>
    <form method="\(publicShare ? "post" : "get")" action="\(authPath)" autocomplete="off">
      <label for="pin">Access PIN</label>
      <input id="pin" name="pin" inputmode="numeric" pattern="[0-9]{4}" maxlength="4" minlength="4" placeholder="0000" autofocus required />
      <button type="submit">Unlock</button>
    </form>
    <p class="hint">\(remainingAttempts) attempts remaining before Web Share stops.</p>
    \(messageHTML)
  </section>
</body>
</html>
"""
    }

    private static func httpUpgradeHTML(httpsURL: String) -> String {
        let safeURL = escapeHTML(httpsURL)
        return """
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width,initial-scale=1" />
  <title>StereoShift Web Share</title>
  <style>
    :root {
      --bg: #0b0f1a;
      --card: rgba(18, 24, 40, 0.92);
      --border: rgba(255, 255, 255, 0.16);
      --text: #eef3ff;
      --muted: rgba(238, 243, 255, 0.72);
      --accent: #43d0ff;
      --shadow: 0 18px 44px rgba(0, 0, 0, 0.44);
    }
    @media (prefers-color-scheme: light) {
      :root {
        --bg: #f2f6ff;
        --card: rgba(255, 255, 255, 0.96);
        --border: rgba(42, 63, 106, 0.18);
        --text: #13213f;
        --muted: rgba(19, 33, 63, 0.68);
        --accent: #2a96ff;
        --shadow: 0 16px 36px rgba(36, 62, 118, 0.16);
      }
    }
    * { box-sizing: border-box; }
    body {
      margin: 0;
      min-height: 100vh;
      display: grid;
      place-items: center;
      padding: 18px;
      font-family: "SF Pro Text", "Segoe UI", -apple-system, BlinkMacSystemFont, sans-serif;
      color: var(--text);
      background: radial-gradient(circle at 18% 10%, rgba(67, 208, 255, 0.18) 0%, transparent 40%),
                  radial-gradient(circle at 78% 0%, rgba(141, 107, 255, 0.16) 0%, transparent 38%),
                  linear-gradient(180deg, var(--bg) 0%, rgba(2, 6, 16, 1) 100%);
    }
    .card {
      width: min(720px, 100%);
      padding: 22px;
      border-radius: 18px;
      border: 1px solid var(--border);
      background: var(--card);
      box-shadow: var(--shadow);
      backdrop-filter: blur(12px);
    }
    h1 {
      margin: 0 0 10px;
      font-size: clamp(20px, 2.8vw, 28px);
      font-weight: 760;
      letter-spacing: 0.2px;
    }
    p { margin: 0; line-height: 1.5; color: var(--muted); }
    .grid {
      display: grid;
      grid-template-columns: 1fr;
      gap: 14px;
      margin-top: 14px;
    }
    .mock {
      border-radius: 14px;
      border: 1px solid rgba(255, 255, 255, 0.12);
      padding: 16px;
      background: rgba(0, 0, 0, 0.18);
      overflow: hidden;
    }
    .warn-title {
      display: flex;
      align-items: center;
      gap: 12px;
      font-weight: 720;
      color: var(--text);
      margin-bottom: 10px;
    }
    .triangle {
      width: 0;
      height: 0;
      border-left: 14px solid transparent;
      border-right: 14px solid transparent;
      border-bottom: 26px solid #ff5a72;
      position: relative;
      filter: drop-shadow(0 8px 18px rgba(255, 90, 114, 0.28));
    }
    .triangle:after {
      content: "!";
      position: absolute;
      left: -3px;
      top: 3px;
      font-size: 16px;
      font-weight: 900;
      color: white;
    }
    .steps {
      margin-top: 12px;
      display: grid;
      gap: 10px;
    }
    .step {
      display: grid;
      grid-template-columns: 26px 1fr;
      gap: 10px;
      align-items: start;
    }
    .badge {
      width: 26px;
      height: 26px;
      border-radius: 999px;
      display: grid;
      place-items: center;
      background: rgba(67, 208, 255, 0.18);
      border: 1px solid rgba(67, 208, 255, 0.36);
      color: var(--text);
      font-weight: 760;
      font-size: 13px;
    }
    .actions {
      display: flex;
      flex-wrap: wrap;
      gap: 10px;
      margin-top: 16px;
    }
    a.button {
      display: inline-flex;
      align-items: center;
      justify-content: center;
      gap: 10px;
      padding: 12px 16px;
      border-radius: 12px;
      text-decoration: none;
      color: var(--text);
      font-weight: 700;
      background: linear-gradient(130deg, #1fb5ff 0%, #7664ff 100%);
      box-shadow: 0 8px 24px rgba(31, 181, 255, 0.28);
    }
    .url {
      font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
      font-size: 12px;
      color: var(--muted);
      word-break: break-all;
      border: 1px solid rgba(255,255,255,0.14);
      padding: 10px 12px;
      border-radius: 12px;
      background: rgba(0,0,0,0.14);
    }
  </style>
</head>
<body>
  <section class="card">
    <h1>StereoShift Web Share</h1>
    <p>VR/AR viewing requires a secure (HTTPS) page. StereoShift uses a locally generated certificate, so your browser may show a warning the first time.</p>
    <div class="grid">
      <div class="mock" role="img" aria-label="Certificate warning instructions">
        <div class="warn-title">
          <span class="triangle" aria-hidden="true"></span>
          <span>Your connection is not private</span>
        </div>
        <p>This is expected for local IP sharing. To continue, open Advanced, then proceed to the site.</p>
        <div class="steps">
          <div class="step"><div class="badge">1</div><div><p>Tap <strong>Advanced</strong> (or similar) on the warning page.</p></div></div>
          <div class="step"><div class="badge">2</div><div><p>Tap <strong>Proceed</strong> to continue to the HTTPS site (it may say “unsafe”).</p></div></div>
        </div>
      </div>
      <div class="url">\(safeURL)</div>
    </div>
    <div class="actions">
      <a class="button" href="\(safeURL)">Open Secure Web Share</a>
    </div>
  </section>
</body>
</html>
"""
    }

    private static func escapeHTML(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    private static let galleryHTML = """
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width,initial-scale=1" />
  <title>StereoShift In-App Gallery</title>
  <style>
    :root {
      --bg: #060b1a;
      --bg2: #0c1630;
      --bg-accent-a: #1a2a56;
      --bg-accent-b: #1c1742;
      --card: rgba(16, 26, 52, 0.72);
      --card-border: rgba(130, 165, 255, 0.22);
      --text: #eef3ff;
      --muted: #9cb2e5;
      --accent: #43d0ff;
      --accent2: #8d6bff;
      --danger: #ff5874;
      --shadow: 0 16px 44px rgba(0, 0, 0, 0.36);
      --btn-outline-bg: rgba(255, 255, 255, 0.03);
      --btn-outline-border: rgba(255, 255, 255, 0.2);
      --thumb-bg: linear-gradient(135deg, rgba(43, 61, 102, .62), rgba(28, 34, 58, .8));
      --overlay-bg: rgba(2, 6, 16, 0.9);
      --viewer-bg: rgba(14, 20, 38, 0.92);
      --viewer-border: rgba(143, 178, 255, 0.25);
      --viewer-divider: rgba(255, 255, 255, 0.08);
      --name-text: #dbe6ff;
      --viewer-title-text: #dce8ff;
      --viewer-time-text: #c7d7fb;
      --badge-bg: rgba(7, 12, 26, .75);
      --badge-border: rgba(255, 255, 255, .18);
      --badge-text: #eef3ff;
      --empty-border: rgba(174, 198, 255, .26);
      --empty-bg: rgba(255, 255, 255, 0.01);
      --error-text: #ffd8dd;
      --error-bg: rgba(159, 19, 51, 0.28);
      --error-border: rgba(255, 115, 140, 0.44);
      --dialog-backdrop: rgba(3, 7, 18, 0.74);
      --dialog-bg: rgba(17, 24, 43, 0.96);
      --dialog-border: rgba(152, 182, 255, 0.35);
      --dialog-text: #dce8ff;
    }

    :root[data-theme="light"] {
      --bg: #eef4ff;
      --bg2: #dfe9ff;
      --bg-accent-a: #bcd2ff;
      --bg-accent-b: #cfd9ff;
      --card: rgba(255, 255, 255, 0.9);
      --card-border: rgba(79, 110, 180, 0.25);
      --text: #13213f;
      --muted: #4e648f;
      --accent: #2a96ff;
      --accent2: #6158ff;
      --danger: #df2f4d;
      --shadow: 0 14px 32px rgba(36, 62, 118, 0.16);
      --btn-outline-bg: rgba(19, 33, 63, 0.03);
      --btn-outline-border: rgba(66, 90, 145, 0.28);
      --thumb-bg: linear-gradient(135deg, rgba(151, 177, 235, 0.58), rgba(225, 234, 255, 0.85));
      --overlay-bg: rgba(122, 138, 174, 0.52);
      --viewer-bg: rgba(249, 252, 255, 0.98);
      --viewer-border: rgba(80, 110, 180, 0.26);
      --viewer-divider: rgba(28, 43, 77, 0.12);
      --name-text: #1b2d52;
      --viewer-title-text: #1a2d55;
      --viewer-time-text: #39517e;
      --badge-bg: rgba(240, 246, 255, 0.95);
      --badge-border: rgba(80, 110, 180, 0.35);
      --badge-text: #1f3560;
      --empty-border: rgba(91, 122, 191, 0.35);
      --empty-bg: rgba(255, 255, 255, 0.52);
      --error-text: #9a1730;
      --error-bg: rgba(255, 209, 218, 0.74);
      --error-border: rgba(217, 88, 113, 0.45);
      --dialog-backdrop: rgba(72, 90, 128, 0.48);
      --dialog-bg: rgba(255, 255, 255, 0.98);
      --dialog-border: rgba(80, 110, 180, 0.25);
      --dialog-text: #20345e;
    }

    * { box-sizing: border-box; }

    body {
      margin: 0;
      color: var(--text);
      font-family: "SF Pro Text", "Segoe UI", -apple-system, BlinkMacSystemFont, sans-serif;
      background: radial-gradient(circle at 18% 10%, var(--bg-accent-a) 0%, transparent 36%),
                  radial-gradient(circle at 80% 0%, var(--bg-accent-b) 0%, transparent 34%),
                  linear-gradient(180deg, var(--bg) 0%, var(--bg2) 100%);
      min-height: 100vh;
    }

    .shell {
      max-width: 1120px;
      margin: 0 auto;
      padding: 28px 18px 54px;
    }

    .hero {
      display: flex;
      flex-wrap: wrap;
      gap: 14px;
      align-items: center;
      justify-content: space-between;
      background: var(--card);
      border: 1px solid var(--card-border);
      border-radius: 18px;
      padding: 18px;
      box-shadow: var(--shadow);
      backdrop-filter: blur(12px);
    }

    .title {
      margin: 0;
      font-weight: 760;
      letter-spacing: 0.2px;
      font-size: clamp(22px, 3vw, 30px);
    }

    .subtitle {
      margin: 6px 0 0;
      color: var(--muted);
      font-size: 14px;
    }

    .actions {
      display: flex;
      gap: 10px;
      flex-wrap: wrap;
      align-items: center;
    }

    .theme-picker {
      display: flex;
      align-items: center;
      gap: 8px;
      color: var(--muted);
      font-size: 13px;
      font-weight: 600;
    }

    .theme-picker select {
      appearance: none;
      border: 1px solid var(--btn-outline-border);
      border-radius: 10px;
      padding: 8px 10px;
      background: var(--btn-outline-bg);
      color: var(--text);
      font-size: 13px;
      font-weight: 600;
      cursor: pointer;
    }

    .theme-picker select:focus {
      outline: none;
      border-color: rgba(67, 208, 255, 0.65);
      box-shadow: 0 0 0 3px rgba(67, 208, 255, 0.2);
    }

    button {
      appearance: none;
      border: 1px solid transparent;
      border-radius: 11px;
      padding: 10px 14px;
      color: var(--text);
      font-weight: 620;
      font-size: 14px;
      cursor: pointer;
      transition: transform .18s ease, opacity .18s ease, border-color .18s ease;
    }

    button:active { transform: translateY(1px); }

    .btn-primary {
      background: linear-gradient(130deg, #1fb5ff 0%, #7664ff 100%);
      box-shadow: 0 8px 24px rgba(31, 181, 255, 0.34);
    }

    .btn-outline {
      background: var(--btn-outline-bg);
      border-color: var(--btn-outline-border);
    }

    .hint {
      margin: 16px 0 0;
      color: var(--muted);
      font-size: 13px;
    }

    .grid {
      margin-top: 18px;
      display: grid;
      grid-template-columns: repeat(auto-fill, minmax(185px, 1fr));
      gap: 12px;
    }

    .card {
      background: var(--card);
      border: 1px solid var(--card-border);
      border-radius: 14px;
      overflow: hidden;
      box-shadow: var(--shadow);
      cursor: pointer;
      transition: transform .18s ease, border-color .18s ease;
      min-height: 212px;
      display: flex;
      flex-direction: column;
    }

    .card:hover {
      transform: translateY(-2px);
      border-color: rgba(164, 192, 255, 0.42);
    }

    .thumb {
      position: relative;
      width: 100%;
      aspect-ratio: 1 / 1;
      background: var(--thumb-bg);
      overflow: hidden;
    }

    .thumb img {
      width: 100%;
      height: 100%;
      object-fit: cover;
      display: block;
    }

    .thumb.unavailable::before {
      content: attr(data-icon);
      position: absolute;
      inset: 0;
      display: grid;
      place-items: center;
      color: var(--muted);
      font-size: 28px;
    }

    .badge {
      position: absolute;
      right: 8px;
      bottom: 8px;
      padding: 4px 8px;
      border-radius: 999px;
      font-size: 11px;
      font-weight: 700;
      color: var(--badge-text);
      background: var(--badge-bg);
      border: 1px solid var(--badge-border);
      backdrop-filter: blur(8px);
    }

    .meta {
      padding: 10px;
      display: grid;
      gap: 4px;
    }

    .meta .name {
      font-size: 13px;
      line-height: 1.3;
      word-break: break-all;
      color: var(--name-text);
    }

    .meta .date {
      font-size: 12px;
      color: var(--muted);
    }

    .overlay {
      position: fixed;
      inset: 0;
      display: none;
      place-items: center;
      padding: 18px;
      background: var(--overlay-bg);
      z-index: 40;
    }

    .overlay.show { display: grid; }

    .viewer {
      width: min(1080px, 100%);
      max-height: calc(100vh - 36px);
      border-radius: 16px;
      border: 1px solid var(--viewer-border);
      background: var(--viewer-bg);
      display: grid;
      grid-template-rows: auto 1fr auto;
      overflow: hidden;
      box-shadow: var(--shadow);
    }

    .viewer-head {
      display: flex;
      align-items: center;
      justify-content: space-between;
      padding: 10px 12px;
      border-bottom: 1px solid var(--viewer-divider);
      gap: 8px;
      flex-wrap: wrap;
    }

    .viewer-title {
      font-size: 14px;
      color: var(--viewer-title-text);
      word-break: break-all;
    }

    .viewer-actions {
      display: flex;
      gap: 8px;
      align-items: center;
    }

    .viewer-time {
      font-size: 13px;
      color: var(--viewer-time-text);
      padding: 8px 12px 10px;
      white-space: nowrap;
      font-variant-numeric: tabular-nums;
      text-align: center;
    }

    .viewer-time.hidden {
      display: none;
    }

    .viewer-body {
      min-height: min(70vh, 700px);
      background: var(--bg);
      display: grid;
      place-items: center;
      overflow: auto;
      padding: 12px;
    }

    .viewer img,
    .viewer video {
      max-width: 100%;
      max-height: calc(100vh - 150px);
      width: auto;
      height: auto;
      display: block;
      border-radius: 10px;
    }

    .viewer-foot {
      border-top: 1px solid var(--viewer-divider);
    }

    .empty {
      margin-top: 18px;
      color: var(--muted);
      text-align: center;
      border: 1px dashed var(--empty-border);
      border-radius: 12px;
      padding: 24px;
      background: var(--empty-bg);
    }

    .load-more-wrap {
      margin-top: 14px;
      display: flex;
      justify-content: center;
    }

    .error {
      margin-top: 14px;
      color: var(--error-text);
      background: var(--error-bg);
      border: 1px solid var(--error-border);
      padding: 10px 12px;
      border-radius: 10px;
      display: none;
    }

    .ui-dialog-backdrop {
      position: fixed;
      inset: 0;
      display: none;
      align-items: center;
      justify-content: center;
      padding: 20px;
      background: var(--dialog-backdrop);
      z-index: 90;
    }

    .ui-dialog-backdrop.show {
      display: flex;
    }

    .ui-dialog {
      width: min(560px, 100%);
      background: var(--dialog-bg);
      border: 1px solid var(--dialog-border);
      border-radius: 16px;
      box-shadow: var(--shadow);
      padding: 16px;
      display: grid;
      gap: 12px;
    }

    .ui-dialog-title {
      margin: 0;
      font-size: 18px;
      font-weight: 700;
    }

    .ui-dialog-message {
      font-size: 14px;
      color: var(--dialog-text);
      line-height: 1.45;
      white-space: pre-line;
    }

    .ui-dialog-actions {
      display: flex;
      justify-content: flex-end;
      gap: 8px;
    }

    @media (max-width: 620px) {
      .shell { padding: 18px 12px 28px; }
      .grid { grid-template-columns: repeat(2, minmax(0, 1fr)); }
      .viewer-body { min-height: 56vh; }
    }
  </style>
</head>
<body>
  <div class="shell">
    <section class="hero">
      <div>
        <h1 class="title">StereoShift In-App Gallery</h1>
        <p class="subtitle">Browse your local converted photos and videos.</p>
      </div>
      <div class="actions">
        <div class="theme-picker">
          <label for="themeSelector">Theme</label>
          <select id="themeSelector" aria-label="Theme">
            <option value="dark" selected>Dark</option>
            <option value="light">Light</option>
          </select>
        </div>
        <button id="refreshButton" class="btn-outline">Refresh</button>
      </div>
    </section>

    <button id="liveButton" class="btn-primary" hidden>Watch Live 3D</button>
    <p class="hint">Tip: Use a VR browser on a headset for the full VR entry flow.</p>
    <div id="errorBanner" class="error"></div>

    <div id="grid" class="grid"></div>
    <div id="emptyState" class="empty" style="display:none;">No items in In-App Gallery yet.</div>

    <div class="load-more-wrap">
      <button id="loadMoreButton" class="btn-outline" style="display:none;">Load More</button>
    </div>
  </div>

  <div id="overlay" class="overlay" aria-hidden="true">
    <div class="viewer">
      <div class="viewer-head">
        <div id="viewerTitle" class="viewer-title"></div>
        <div class="viewer-actions">
          <button id="vrButton" class="btn-primary">Enter VR</button>
          <button id="closeButton" class="btn-outline">Close</button>
        </div>
      </div>
      <div id="viewerBody" class="viewer-body"></div>
      <div class="viewer-foot">
        <div id="viewerTime" class="viewer-time hidden">00:00 / 00:00</div>
      </div>
    </div>
  </div>

  <div id="uiDialogBackdrop" class="ui-dialog-backdrop" aria-hidden="true">
    <div class="ui-dialog" role="dialog" aria-modal="true" aria-labelledby="uiDialogTitle" aria-describedby="uiDialogMessage">
      <h2 id="uiDialogTitle" class="ui-dialog-title">Notice</h2>
      <div id="uiDialogMessage" class="ui-dialog-message"></div>
      <div class="ui-dialog-actions">
        <button id="uiDialogClose" class="btn-primary">Close</button>
      </div>
    </div>
  </div>

  <script>
    const state = {
      offset: 0,
      limit: 120,
      hasMore: false,
      activeItem: null
    };

    const liveButton = document.getElementById('liveButton');
    liveButton.onclick = () => openViewer({ id: 'Live 3D Video', type: 'video', mediaPath: state.livePath, live: true });
    const grid = document.getElementById('grid');
    const emptyState = document.getElementById('emptyState');
    const loadMoreButton = document.getElementById('loadMoreButton');
    const refreshButton = document.getElementById('refreshButton');
    const themeSelector = document.getElementById('themeSelector');
    const errorBanner = document.getElementById('errorBanner');

    const themeStorageKey = 'stereoshift_webshare_theme';

    const overlay = document.getElementById('overlay');
    const viewerTitle = document.getElementById('viewerTitle');
    const viewerTime = document.getElementById('viewerTime');
    const viewerBody = document.getElementById('viewerBody');
    const closeButton = document.getElementById('closeButton');
    const vrButton = document.getElementById('vrButton');
    let previewVideoElement = null;

    refreshButton.addEventListener('click', () => resetAndLoad());
    loadMoreButton.addEventListener('click', () => loadItems());
    closeButton.addEventListener('click', closeViewer);
    overlay.addEventListener('click', (event) => {
      if (event.target === overlay) {
        closeViewer();
      }
    });

    const xrRuntime = {
      session: null,
      mode: null,
      refSpace: null,
      canvas: null,
      gl: null,
      program: null,
      positionBuffer: null,
      texCoordBuffer: null,
      positionLocation: null,
      texCoordLocation: null,
      textureLocation: null,
      eyeLocation: null,
      mvpLocation: null,
      vertexCount: 0,
      texture: null,
      overlayPositionBuffer: null,
      overlayTexCoordBuffer: null,
      overlayVertexCount: 0,
      overlayTexture: null,
      overlayCanvas: null,
      overlayContext: null,
      overlayNeedsUpload: false,
      overlayLastText: '',
      mediaElement: null,
      sourceType: null,
      modelMatrix: null,
      planeDistance: 3.0,
      zoom: 1.0,
      rightStickSeekLatch: 0,
      rightStickButtonPressed: false,
      lastXRFrameTimeSec: 0
    };

    const dialogBackdrop = document.getElementById('uiDialogBackdrop');
    const dialogTitle = document.getElementById('uiDialogTitle');
    const dialogMessage = document.getElementById('uiDialogMessage');
    const dialogCloseButton = document.getElementById('uiDialogClose');

    dialogCloseButton.addEventListener('click', hideDialog);
    dialogBackdrop.addEventListener('click', (event) => {
      if (event.target === dialogBackdrop) {
        hideDialog();
      }
    });

    function normalizeTheme(value) {
      if (value === 'default-dark') {
        return 'dark';
      }
      if (value === 'light' || value === 'dark') {
        return value;
      }
      return 'dark';
    }

    function applyTheme(themeValue) {
      const normalized = normalizeTheme(themeValue);
      document.documentElement.setAttribute('data-theme', normalized);
      if (themeSelector) {
        themeSelector.value = normalized;
      }
    }

    function loadThemePreference() {
      try {
        return normalizeTheme(localStorage.getItem(themeStorageKey));
      } catch (_) {
        return 'dark';
      }
    }

    function saveThemePreference(themeValue) {
      try {
        localStorage.setItem(themeStorageKey, normalizeTheme(themeValue));
      } catch (_) {
      }
    }

    if (themeSelector) {
      themeSelector.addEventListener('change', () => {
        const selectedTheme = normalizeTheme(themeSelector.value);
        applyTheme(selectedTheme);
        saveThemePreference(selectedTheme);
      });
    }

    async function maybeRedirectToSecureVR() {
      if (window.location.protocol !== 'http:') {
        return;
      }

      if (!navigator.xr || typeof navigator.xr.isSessionSupported !== 'function') {
        return;
      }

      let xrLooksSupported = false;
      try {
        xrLooksSupported = await navigator.xr.isSessionSupported('immersive-vr');
        if (!xrLooksSupported) {
          xrLooksSupported = await navigator.xr.isSessionSupported('immersive-ar');
        }
      } catch (_) {
        xrLooksSupported = false;
      }

      if (!xrLooksSupported) {
        return;
      }

      const secureURL = new URL(window.location.href);
      secureURL.protocol = 'https:';
      window.location.replace(secureURL.toString());
    }

    applyTheme(loadThemePreference());
    maybeRedirectToSecureVR();

    function showDialog(message, title = 'Notice') {
      dialogTitle.textContent = title;
      dialogMessage.textContent = message;
      dialogBackdrop.classList.add('show');
      dialogBackdrop.setAttribute('aria-hidden', 'false');
    }

    function hideDialog() {
      dialogBackdrop.classList.remove('show');
      dialogBackdrop.setAttribute('aria-hidden', 'true');
    }

    async function immersiveModeSupported(mode) {
      if (!navigator.xr || !navigator.xr.isSessionSupported) {
        return false;
      }

      try {
        return await navigator.xr.isSessionSupported(mode);
      } catch (_) {
        return false;
      }
    }

    async function detectXRContext() {
      const hasXR = Boolean(navigator.xr);
      const hasSessionSupportCheck = hasXR && typeof navigator.xr.isSessionSupported === 'function';
      const immersiveVR = await immersiveModeSupported('immersive-vr');
      const immersiveAR = await immersiveModeSupported('immersive-ar');
      const immersiveSupported = immersiveVR || immersiveAR;
      const secureContext = window.isSecureContext === true;
      return {
        hasXR,
        hasSessionSupportCheck,
        immersiveSupported,
        immersiveVR,
        immersiveAR,
        secureContext
      };
    }

    function ensureActiveItemForXR() {
      if (!state.activeItem) {
        showDialog('Open an SBS image or video first, then tap Enter VR.', 'No Media Selected');
        return false;
      }
      return true;
    }

    async function requestXRSession(xrContext) {
      if (!navigator.xr || !navigator.xr.requestSession) {
        throw new Error('This browser does not expose WebXR session APIs.');
      }

      if (!xrContext.secureContext) {
        throw new Error('WebXR requires HTTPS secure context. Accept the certificate warning, then reload.');
      }

      const preferredModes = [];
      if (xrContext.immersiveVR) preferredModes.push('immersive-vr');
      if (xrContext.immersiveAR) preferredModes.push('immersive-ar');
      if (preferredModes.length === 0) preferredModes.push('immersive-vr', 'immersive-ar');

      let lastError;
      for (const mode of preferredModes) {
        try {
          const session = await navigator.xr.requestSession(mode, { requiredFeatures: ['local'] });
          return { session, mode };
        } catch (error) {
          lastError = error;
        }
      }

      throw lastError || new Error('Unable to start immersive XR session.');
    }

    function createShader(gl, type, source) {
      const shader = gl.createShader(type);
      gl.shaderSource(shader, source);
      gl.compileShader(shader);

      if (!gl.getShaderParameter(shader, gl.COMPILE_STATUS)) {
        const info = gl.getShaderInfoLog(shader) || 'Unknown shader compile failure.';
        gl.deleteShader(shader);
        throw new Error(info);
      }

      return shader;
    }

    function createProgram(gl, vertexSource, fragmentSource) {
      const vertexShader = createShader(gl, gl.VERTEX_SHADER, vertexSource);
      const fragmentShader = createShader(gl, gl.FRAGMENT_SHADER, fragmentSource);
      const program = gl.createProgram();
      gl.attachShader(program, vertexShader);
      gl.attachShader(program, fragmentShader);
      gl.linkProgram(program);

      if (!gl.getProgramParameter(program, gl.LINK_STATUS)) {
        const info = gl.getProgramInfoLog(program) || 'Unknown program link failure.';
        gl.deleteProgram(program);
        throw new Error(info);
      }

      gl.deleteShader(vertexShader);
      gl.deleteShader(fragmentShader);
      return program;
    }

    async function prepareXRMediaSource(item) {
      if (item.live) {
        const video = previewVideoElement;
        if (!video || video.readyState < 2) throw new Error('Wait for the first 3D frame, then enter VR.');
        await video.play();
        return { type: 'video', element: video };
      }
      if (item.type === 'video') {
        const video = document.createElement('video');
        video.src = item.mediaPath;
        video.loop = true;
        video.controls = false;
        video.muted = false;
        video.defaultMuted = false;
        video.volume = 1.0;
        video.playsInline = true;
        video.crossOrigin = 'anonymous';
        video.setAttribute('playsinline', 'true');
        video.setAttribute('webkit-playsinline', 'true');
        video.preload = 'auto';

        await new Promise((resolve, reject) => {
          const onLoaded = () => {
            cleanup();
            resolve();
          };
          const onError = () => {
            cleanup();
            reject(new Error('Unable to load video for XR session.'));
          };
          const cleanup = () => {
            video.removeEventListener('loadeddata', onLoaded);
            video.removeEventListener('error', onError);
          };

          video.addEventListener('loadeddata', onLoaded);
          video.addEventListener('error', onError);
        });

        try {
          await video.play();
        } catch (_) {
          video.muted = true;
          try {
            await video.play();
            video.muted = false;
            video.defaultMuted = false;
          } catch (_) {
            throw new Error('Unable to autoplay video texture in XR. Interact with the page and try again.');
          }
        }

        return { type: 'video', element: video };
      }

      const image = new Image();
      image.crossOrigin = 'anonymous';
      image.src = item.mediaPath;
      await image.decode();
      return { type: 'image', element: image };
    }

    function mediaEyeAspect(source) {
      if (!source || !source.element) {
        return 16 / 9;
      }

      if (source.type === 'video') {
        const width = source.element.videoWidth || 0;
        const height = source.element.videoHeight || 0;
        if (width > 0 && height > 0) {
          return (width / height) / 2;
        }
      } else {
        const width = source.element.naturalWidth || source.element.width || 0;
        const height = source.element.naturalHeight || source.element.height || 0;
        if (width > 0 && height > 0) {
          return (width / height) / 2;
        }
      }

      return 16 / 9;
    }

    function mat4Multiply(a, b) {
      const out = new Float32Array(16);
      for (let c = 0; c < 4; c += 1) {
        for (let r = 0; r < 4; r += 1) {
          out[c * 4 + r] =
            a[0 * 4 + r] * b[c * 4 + 0] +
            a[1 * 4 + r] * b[c * 4 + 1] +
            a[2 * 4 + r] * b[c * 4 + 2] +
            a[3 * 4 + r] * b[c * 4 + 3];
        }
      }
      return out;
    }

    function mat4Translation(x, y, z) {
      return new Float32Array([
        1, 0, 0, 0,
        0, 1, 0, 0,
        0, 0, 1, 0,
        x, y, z, 1
      ]);
    }

    function mat4Scale(x, y, z) {
      return new Float32Array([
        x, 0, 0, 0,
        0, y, 0, 0,
        0, 0, z, 0,
        0, 0, 0, 1
      ]);
    }

    function clamp(value, min, max) {
      return Math.max(min, Math.min(max, value));
    }

    function applyDeadzone(value, deadzone) {
      const abs = Math.abs(value);
      if (abs <= deadzone) {
        return 0;
      }
      const normalized = (abs - deadzone) / (1 - deadzone);
      return Math.sign(value) * normalized;
    }

    function quadPositions(halfWidth, halfHeight, centerY = 0) {
      const top = centerY + halfHeight;
      const bottom = centerY - halfHeight;
      return new Float32Array([
        -halfWidth, bottom, 0,
         halfWidth, bottom, 0,
        -halfWidth, top, 0,
         halfWidth, bottom, 0,
         halfWidth, top, 0,
        -halfWidth, top, 0
      ]);
    }

    function drawRoundedRectPath(context, x, y, width, height, radius) {
      const r = Math.max(0, Math.min(radius, width * 0.5, height * 0.5));
      context.beginPath();
      context.moveTo(x + r, y);
      context.lineTo(x + width - r, y);
      context.arcTo(x + width, y, x + width, y + r, r);
      context.lineTo(x + width, y + height - r);
      context.arcTo(x + width, y + height, x + width - r, y + height, r);
      context.lineTo(x + r, y + height);
      context.arcTo(x, y + height, x, y + height - r, r);
      context.lineTo(x, y + r);
      context.arcTo(x, y, x + r, y, r);
      context.closePath();
    }

    function renderStereoTimeOverlay(canvas, context, labelText) {
      const width = canvas.width;
      const height = canvas.height;
      const half = width * 0.5;
      context.clearRect(0, 0, width, height);

      const insetX = Math.round(half * 0.075);
      const insetY = Math.round(height * 0.13);
      const panelWidth = Math.round(half - (insetX * 2));
      const panelHeight = Math.round(height - (insetY * 2));
      const radius = Math.round(Math.min(panelHeight * 0.44, 30));
      const text = labelText && labelText.trim().length > 0 ? labelText : '00:00 / 00:00';

      for (let panel = 0; panel < 2; panel += 1) {
        const x = panel * half + insetX;
        const y = insetY;

        drawRoundedRectPath(context, x, y, panelWidth, panelHeight, radius);
        context.fillStyle = 'rgba(4, 10, 22, 0.66)';
        context.fill();

        drawRoundedRectPath(context, x, y, panelWidth, panelHeight, radius);
        context.strokeStyle = 'rgba(188, 211, 255, 0.7)';
        context.lineWidth = 3;
        context.stroke();

        context.font = '700 48px "SF Pro Text", "Segoe UI", sans-serif';
        context.textAlign = 'center';
        context.textBaseline = 'middle';
        context.fillStyle = '#eaf2ff';
        context.fillText(text, x + (panelWidth * 0.5), y + (panelHeight * 0.5));
      }
    }

    function updateXRVideoTimeOverlay(labelText) {
      if (!xrRuntime.overlayCanvas || !xrRuntime.overlayContext) {
        return;
      }

      const nextText = labelText && labelText.trim().length > 0 ? labelText : '00:00 / 00:00';
      if (xrRuntime.overlayLastText === nextText) {
        return;
      }

      renderStereoTimeOverlay(xrRuntime.overlayCanvas, xrRuntime.overlayContext, nextText);
      xrRuntime.overlayLastText = nextText;
      xrRuntime.overlayNeedsUpload = true;
    }

    function formatVideoTime(seconds) {
      if (!Number.isFinite(seconds) || seconds < 0) {
        return '--:--';
      }

      const total = Math.floor(seconds);
      const hours = Math.floor(total / 3600);
      const minutes = Math.floor((total % 3600) / 60);
      const secs = total % 60;

      const mm = String(minutes).padStart(2, '0');
      const ss = String(secs).padStart(2, '0');

      if (hours > 0) {
        return `${hours}:${mm}:${ss}`;
      }

      return `${mm}:${ss}`;
    }

    function hideVideoTimeLabel() {
      viewerTime.classList.add('hidden');
      viewerTime.textContent = '00:00 / 00:00';
    }

    function showVideoTimeLabel() {
      viewerTime.classList.remove('hidden');
    }

    function updateVideoTimeLabel(video) {
      if (!video) {
        hideVideoTimeLabel();
        return;
      }

      showVideoTimeLabel();
      const current = formatVideoTime(video.currentTime || 0);
      const total = video.dataset.live ? 'Live 3D' : formatVideoTime(video.duration);
      const labelText = `${current} / ${total}`;
      viewerTime.textContent = labelText;
      updateXRVideoTimeOverlay(labelText);
    }

    function seekVideoBy(secondsDelta) {
      if (xrRuntime.sourceType !== 'video' || !xrRuntime.mediaElement) {
        return;
      }

      const video = xrRuntime.mediaElement;
      if (video.dataset.live || !Number.isFinite(video.duration) || video.duration <= 0) {
        return;
      }

      const nextTime = clamp(video.currentTime + secondsDelta, 0, video.duration);
      video.currentTime = nextTime;
      updateVideoTimeLabel(video);
    }

    function toggleVideoPlaybackFromController() {
      if (xrRuntime.sourceType !== 'video' || !xrRuntime.mediaElement) {
        return;
      }

      const video = xrRuntime.mediaElement;
      if (video.paused) {
        video.play().catch(() => {});
      } else {
        video.pause();
      }

      updateVideoTimeLabel(video);
    }

    function rightControllerGamepad(frame) {
      const inputSources = frame.session.inputSources || [];
      for (const source of inputSources) {
        if (source.handedness === 'right' && source.gamepad) {
          return source.gamepad;
        }
      }
      return null;
    }

    function gamepadButtonPressed(gamepad, indices) {
      if (!gamepad || !Array.isArray(gamepad.buttons)) {
        return false;
      }
      for (const index of indices) {
        const button = gamepad.buttons[index];
        if (button && button.pressed) {
          return true;
        }
      }
      return false;
    }

    function updateXRControllerInputs(frameTimeSec, frame) {
      if (!xrRuntime.session) {
        return;
      }

      const dt = xrRuntime.lastXRFrameTimeSec > 0
        ? Math.max(0, Math.min(0.05, frameTimeSec - xrRuntime.lastXRFrameTimeSec))
        : (1 / 72);
      xrRuntime.lastXRFrameTimeSec = frameTimeSec;

      const gamepad = rightControllerGamepad(frame);
      if (!gamepad) {
        xrRuntime.rightStickSeekLatch = 0;
        xrRuntime.rightStickButtonPressed = false;
        return;
      }

      const axes = Array.isArray(gamepad.axes) ? gamepad.axes : [];
      let rawX = 0;
      let rawY = 0;

      if (axes.length >= 4) {
        rawX = axes[2] ?? 0;
        rawY = axes[3] ?? 0;
      } else if (axes.length >= 2) {
        rawX = axes[0] ?? 0;
        rawY = axes[1] ?? 0;
      }

      const stickX = applyDeadzone(rawX, 0.14);
      const stickY = applyDeadzone(rawY, 0.14);
      const rawAbsX = Math.abs(rawX);
      const rawAbsY = Math.abs(rawY);
      const absX = Math.abs(stickX);
      const intentMargin = 0.14;
      const horizontalIntent = rawAbsX > 0.18 && rawAbsX >= (rawAbsY + intentMargin);
      const verticalIntent = rawAbsY > 0.18 && rawAbsY >= (rawAbsX + intentMargin);

      if (xrRuntime.sourceType === 'video' && horizontalIntent && rawAbsX < 0.68) {
        const video = xrRuntime.mediaElement;
        const duration = Number.isFinite(video?.duration) && video.duration > 0 ? video.duration : 120;
        const scrubSpeed = clamp(duration * 0.18, 10, 90);
        seekVideoBy(stickX * scrubSpeed * dt);
        xrRuntime.rightStickSeekLatch = 0;
      } else if (horizontalIntent) {
        const seekThreshold = 0.78;
        const releaseThreshold = 0.32;
        let direction = 0;
        if (stickX >= seekThreshold) {
          direction = 1;
        } else if (stickX <= -seekThreshold) {
          direction = -1;
        }

        if (direction !== 0 && xrRuntime.rightStickSeekLatch !== direction) {
          seekVideoBy(direction * 10);
          xrRuntime.rightStickSeekLatch = direction;
        }

        if (absX <= releaseThreshold) {
          xrRuntime.rightStickSeekLatch = 0;
        }
      } else {
        xrRuntime.rightStickSeekLatch = 0;
      }

      if (verticalIntent) {
        const zoomSpeed = 1.05;
        xrRuntime.zoom = clamp(xrRuntime.zoom + (-stickY * zoomSpeed * dt), 0.55, 2.8);
      }

      const stickClickPressed = gamepadButtonPressed(gamepad, [3]);
      if (stickClickPressed && !xrRuntime.rightStickButtonPressed) {
        toggleVideoPlaybackFromController();
      }
      xrRuntime.rightStickButtonPressed = stickClickPressed;
    }

    function setupXRRenderer(gl, eyeAspect) {
      const vertexShader = `
        attribute vec3 a_position;
        attribute vec2 a_texCoord;
        uniform mat4 u_mvp;
        varying vec2 v_uv;
        void main() {
          v_uv = a_texCoord;
          gl_Position = u_mvp * vec4(a_position, 1.0);
        }
      `;

      const fragmentShader = `
        precision mediump float;
        varying vec2 v_uv;
        uniform sampler2D u_texture;
        uniform float u_eye;
        void main() {
          float x = (u_eye < 0.5) ? (v_uv.x * 0.5) : (0.5 + v_uv.x * 0.5);
          vec2 uv = vec2(x, v_uv.y);
          gl_FragColor = texture2D(u_texture, uv);
        }
      `;

      const safeAspect = Number.isFinite(eyeAspect) && eyeAspect > 0 ? eyeAspect : (16 / 9);
      const planeDistance = 3.0;
      const planeHeight = 2.2;
      const planeWidth = Math.max(1.2, Math.min(4.2, planeHeight * safeAspect));
      const halfWidth = planeWidth * 0.5;
      const halfHeight = planeHeight * 0.5;
      const overlayWidth = Math.max(1.24, Math.min(3.3, planeWidth * 0.68));
      const overlayHeight = Math.max(0.22, Math.min(0.36, planeHeight * 0.13));
      const overlayCenterY = -halfHeight - 0.18 - (overlayHeight * 0.5);

      const program = createProgram(gl, vertexShader, fragmentShader);
      const positionBuffer = gl.createBuffer();
      const texCoordBuffer = gl.createBuffer();
      const texture = gl.createTexture();
      const overlayPositionBuffer = gl.createBuffer();
      const overlayTexCoordBuffer = gl.createBuffer();
      const overlayTexture = gl.createTexture();
      const overlayCanvas = document.createElement('canvas');
      overlayCanvas.width = 1024;
      overlayCanvas.height = 160;
      const overlayContext = overlayCanvas.getContext('2d');

      if (!positionBuffer || !texCoordBuffer || !texture || !overlayPositionBuffer || !overlayTexCoordBuffer || !overlayTexture || !overlayContext) {
        throw new Error('Unable to allocate XR renderer resources.');
      }

      const positions = quadPositions(halfWidth, halfHeight, 0);
      const overlayPositions = quadPositions(overlayWidth * 0.5, overlayHeight * 0.5, overlayCenterY);

      const texCoords = new Float32Array([
        0, 0, 1, 0, 0, 1,
        1, 0, 1, 1, 0, 1
      ]);

      gl.bindBuffer(gl.ARRAY_BUFFER, positionBuffer);
      gl.bufferData(gl.ARRAY_BUFFER, positions, gl.STATIC_DRAW);

      gl.bindBuffer(gl.ARRAY_BUFFER, texCoordBuffer);
      gl.bufferData(gl.ARRAY_BUFFER, texCoords, gl.STATIC_DRAW);

      gl.bindTexture(gl.TEXTURE_2D, texture);
      gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
      gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
      gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR);
      gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR);
      gl.pixelStorei(gl.UNPACK_FLIP_Y_WEBGL, true);

      gl.bindBuffer(gl.ARRAY_BUFFER, overlayPositionBuffer);
      gl.bufferData(gl.ARRAY_BUFFER, overlayPositions, gl.STATIC_DRAW);

      gl.bindBuffer(gl.ARRAY_BUFFER, overlayTexCoordBuffer);
      gl.bufferData(gl.ARRAY_BUFFER, texCoords, gl.STATIC_DRAW);

      gl.bindTexture(gl.TEXTURE_2D, overlayTexture);
      gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
      gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
      gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR);
      gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR);

      const positionLocation = gl.getAttribLocation(program, 'a_position');
      const texCoordLocation = gl.getAttribLocation(program, 'a_texCoord');
      const textureLocation = gl.getUniformLocation(program, 'u_texture');
      const eyeLocation = gl.getUniformLocation(program, 'u_eye');
      const mvpLocation = gl.getUniformLocation(program, 'u_mvp');

      renderStereoTimeOverlay(overlayCanvas, overlayContext, '00:00 / 00:00');

      return {
        program,
        positionBuffer,
        texCoordBuffer,
        texture,
        overlayPositionBuffer,
        overlayTexCoordBuffer,
        overlayVertexCount: 6,
        overlayTexture,
        overlayCanvas,
        overlayContext,
        overlayNeedsUpload: true,
        positionLocation,
        texCoordLocation,
        textureLocation,
        eyeLocation,
        mvpLocation,
        vertexCount: 6,
        modelMatrix: mat4Translation(0, 0, -planeDistance),
        planeDistance
      };
    }

    function uploadMediaTexture(gl, texture, mediaElement) {
      gl.bindTexture(gl.TEXTURE_2D, texture);
      gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, gl.RGBA, gl.UNSIGNED_BYTE, mediaElement);
    }

    function drawTexturedPlane(gl, eye, mvpMatrix, positionBuffer, texCoordBuffer, texture, vertexCount) {
      gl.useProgram(xrRuntime.program);

      gl.bindBuffer(gl.ARRAY_BUFFER, positionBuffer);
      gl.enableVertexAttribArray(xrRuntime.positionLocation);
      gl.vertexAttribPointer(xrRuntime.positionLocation, 3, gl.FLOAT, false, 0, 0);

      gl.bindBuffer(gl.ARRAY_BUFFER, texCoordBuffer);
      gl.enableVertexAttribArray(xrRuntime.texCoordLocation);
      gl.vertexAttribPointer(xrRuntime.texCoordLocation, 2, gl.FLOAT, false, 0, 0);

      gl.uniform1f(xrRuntime.eyeLocation, eye === 'right' ? 1.0 : 0.0);
      gl.uniform1i(xrRuntime.textureLocation, 0);
      gl.uniformMatrix4fv(xrRuntime.mvpLocation, false, mvpMatrix);

      gl.activeTexture(gl.TEXTURE0);
      gl.bindTexture(gl.TEXTURE_2D, texture);

      gl.drawArrays(gl.TRIANGLES, 0, vertexCount);
    }

    function onXRFrame(_time, frame) {
      const session = frame.session;
      session.requestAnimationFrame(onXRFrame);

      const pose = frame.getViewerPose(xrRuntime.refSpace);
      if (!pose || !xrRuntime.gl) {
        return;
      }

      updateXRControllerInputs(_time * 0.001, frame);

      const gl = xrRuntime.gl;
      const baseLayer = session.renderState.baseLayer;
      gl.bindFramebuffer(gl.FRAMEBUFFER, baseLayer.framebuffer);
      gl.clearColor(0.02, 0.03, 0.06, 1.0);
      gl.clear(gl.COLOR_BUFFER_BIT);
      gl.disable(gl.DEPTH_TEST);
      gl.disable(gl.CULL_FACE);

      if (xrRuntime.sourceType === 'video' && xrRuntime.mediaElement && xrRuntime.mediaElement.readyState >= 2) {
        uploadMediaTexture(gl, xrRuntime.texture, xrRuntime.mediaElement);
        updateVideoTimeLabel(xrRuntime.mediaElement);
      }

      if (xrRuntime.sourceType === 'video' && xrRuntime.overlayNeedsUpload && xrRuntime.overlayCanvas && xrRuntime.overlayTexture) {
        uploadMediaTexture(gl, xrRuntime.overlayTexture, xrRuntime.overlayCanvas);
        xrRuntime.overlayNeedsUpload = false;
      }

      for (const view of pose.views) {
        const viewport = baseLayer.getViewport(view);
        if (!viewport) {
          continue;
        }

        const eye = view.eye === 'right' ? 'right' : 'left';
        const viewMatrix = view.transform.inverse.matrix;
        const projectionMatrix = view.projectionMatrix;
        const dynamicModelMatrix = mat4Multiply(
          mat4Translation(0, 0, -xrRuntime.planeDistance),
          mat4Scale(xrRuntime.zoom, xrRuntime.zoom, 1)
        );
        const modelViewMatrix = mat4Multiply(viewMatrix, dynamicModelMatrix);
        const mvpMatrix = mat4Multiply(projectionMatrix, modelViewMatrix);

        gl.viewport(viewport.x, viewport.y, viewport.width, viewport.height);
        drawTexturedPlane(
          gl,
          eye,
          mvpMatrix,
          xrRuntime.positionBuffer,
          xrRuntime.texCoordBuffer,
          xrRuntime.texture,
          xrRuntime.vertexCount
        );

        if (xrRuntime.sourceType === 'video' && xrRuntime.overlayTexture) {
          drawTexturedPlane(
            gl,
            eye,
            mvpMatrix,
            xrRuntime.overlayPositionBuffer,
            xrRuntime.overlayTexCoordBuffer,
            xrRuntime.overlayTexture,
            xrRuntime.overlayVertexCount
          );
        }
      }
    }

    async function startXRPlayback() {
      if (!ensureActiveItemForXR()) {
        return;
      }

      if (xrRuntime.session) {
        showDialog('XR session is already active.', 'XR Running');
        return;
      }

      const xrContext = await detectXRContext();
      if (!xrContext.hasXR || !xrContext.hasSessionSupportCheck) {
        showDialog('Entering VR requires a VR headset browser. Open this page in your headset browser and try again.', 'XR Unsupported');
        return;
      }

      if (!xrContext.secureContext) {
        showDialog('WebXR requires HTTPS secure context. Accept the certificate warning, then reload.', 'XR Unsupported');
        return;
      }

      if (!xrContext.immersiveSupported) {
        showDialog('Entering VR requires a VR headset browser. Open this page in your headset browser and try again.', 'XR Unsupported');
        return;
      }

      let sessionBundle;
      try {
        sessionBundle = await requestXRSession(xrContext);
      } catch (error) {
        showDialog(error?.message || 'Unable to start XR session.', 'XR Error');
        return;
      }

      const { session, mode } = sessionBundle;
      const canvas = document.createElement('canvas');
      const gl = canvas.getContext('webgl', { xrCompatible: true, alpha: false, antialias: true });

      if (!gl) {
        session.end();
        showDialog('WebGL context creation failed for XR session.', 'XR Error');
        return;
      }

      try {
        if (gl.makeXRCompatible) {
          await gl.makeXRCompatible();
        }

        const source = await prepareXRMediaSource(state.activeItem);
        const renderer = setupXRRenderer(gl, mediaEyeAspect(source));
        uploadMediaTexture(gl, renderer.texture, source.element);
        if (source.type === 'video') {
          updateVideoTimeLabel(source.element);
        } else {
          hideVideoTimeLabel();
        }

        session.updateRenderState({ baseLayer: new XRWebGLLayer(session, gl) });
        const refSpace = await session.requestReferenceSpace('local');

        xrRuntime.session = session;
        xrRuntime.mode = mode;
        xrRuntime.refSpace = refSpace;
        xrRuntime.canvas = canvas;
        xrRuntime.gl = gl;
        xrRuntime.program = renderer.program;
        xrRuntime.positionBuffer = renderer.positionBuffer;
        xrRuntime.texCoordBuffer = renderer.texCoordBuffer;
        xrRuntime.overlayPositionBuffer = renderer.overlayPositionBuffer;
        xrRuntime.overlayTexCoordBuffer = renderer.overlayTexCoordBuffer;
        xrRuntime.positionLocation = renderer.positionLocation;
        xrRuntime.texCoordLocation = renderer.texCoordLocation;
        xrRuntime.textureLocation = renderer.textureLocation;
        xrRuntime.eyeLocation = renderer.eyeLocation;
        xrRuntime.mvpLocation = renderer.mvpLocation;
        xrRuntime.vertexCount = renderer.vertexCount;
        xrRuntime.texture = renderer.texture;
        xrRuntime.overlayVertexCount = renderer.overlayVertexCount;
        xrRuntime.overlayTexture = renderer.overlayTexture;
        xrRuntime.overlayCanvas = renderer.overlayCanvas;
        xrRuntime.overlayContext = renderer.overlayContext;
        xrRuntime.overlayNeedsUpload = renderer.overlayNeedsUpload;
        xrRuntime.overlayLastText = '';
        xrRuntime.mediaElement = source.element;
        xrRuntime.sourceType = source.type;
        xrRuntime.modelMatrix = renderer.modelMatrix;
        xrRuntime.planeDistance = renderer.planeDistance;
        xrRuntime.zoom = 1.0;
        xrRuntime.rightStickSeekLatch = 0;
        xrRuntime.rightStickButtonPressed = false;
        xrRuntime.lastXRFrameTimeSec = 0;

        if (source.type === 'video') {
          updateVideoTimeLabel(source.element);
        }

        session.addEventListener('end', stopXRPlayback);
        session.requestAnimationFrame(onXRFrame);
      } catch (error) {
        try { session.end(); } catch (_) {}
        stopXRPlayback();
        showDialog(error?.message || 'Failed to initialize XR playback.', 'XR Error');
      }
    }

    function stopXRPlayback() {
      if (xrRuntime.mediaElement && xrRuntime.sourceType === 'video') {
        try {
          xrRuntime.mediaElement.pause();
        } catch (_) {}
      }

      xrRuntime.session = null;
      xrRuntime.mode = null;
      xrRuntime.refSpace = null;
      xrRuntime.canvas = null;
      xrRuntime.gl = null;
      xrRuntime.program = null;
      xrRuntime.positionBuffer = null;
      xrRuntime.texCoordBuffer = null;
      xrRuntime.overlayPositionBuffer = null;
      xrRuntime.overlayTexCoordBuffer = null;
      xrRuntime.positionLocation = null;
      xrRuntime.texCoordLocation = null;
      xrRuntime.textureLocation = null;
      xrRuntime.eyeLocation = null;
      xrRuntime.mvpLocation = null;
      xrRuntime.vertexCount = 0;
      xrRuntime.texture = null;
      xrRuntime.overlayVertexCount = 0;
      xrRuntime.overlayTexture = null;
      xrRuntime.overlayCanvas = null;
      xrRuntime.overlayContext = null;
      xrRuntime.overlayNeedsUpload = false;
      xrRuntime.overlayLastText = '';
      xrRuntime.mediaElement = null;
      xrRuntime.sourceType = null;
      xrRuntime.modelMatrix = null;
      xrRuntime.planeDistance = 3.0;
      xrRuntime.zoom = 1.0;
      xrRuntime.rightStickSeekLatch = 0;
      xrRuntime.rightStickButtonPressed = false;
      xrRuntime.lastXRFrameTimeSec = 0;

      if (previewVideoElement) {
        updateVideoTimeLabel(previewVideoElement);
      } else {
        hideVideoTimeLabel();
      }
    }

    vrButton.addEventListener('click', () => {
      startXRPlayback();
    });

    let activeListRequest = null;

    async function resetAndLoad() {
      activeListRequest?.abort();
      activeListRequest = null;
      state.offset = 0;
      coverObserver.disconnect();
      coverQueue.clear();
      grid.replaceChildren();
      state.hasMore = false;
      render();
      await loadItems();
    }

    async function loadItems() {
      if (activeListRequest) return;
      const request = new AbortController();
      activeListRequest = request;
      loadMoreButton.disabled = true;
      try {
        setError('');
        const response = await fetch(`/api/items?offset=${state.offset}&limit=${state.limit}`, { cache: 'no-store', signal: request.signal });
        if (request.signal.aborted) return;
        if (response.redirected && new URL(response.url).pathname === '/') {
          window.location.replace('/');
          return;
        }
        if (!response.ok) {
          throw new Error('Failed to load gallery list.');
        }

        const payload = await response.json();
        if (request.signal.aborted) return;
        state.livePath = payload.liveVideoPath;
        state.liveOnly = payload.liveOnly;
        liveButton.hidden = !state.livePath;
        document.querySelector('h1.title').textContent = state.liveOnly ? 'StereoShift Live 3D' : 'StereoShift In-App Gallery';
        document.querySelector('.subtitle').textContent = state.liveOnly
          ? 'Watch the selected video as your iPhone converts it to 3D.' : 'Browse your local converted photos and videos.';
        const incoming = Array.isArray(payload.items) ? payload.items : [];

        state.offset += incoming.length;
        state.hasMore = Boolean(payload.hasMore);

        render(incoming);
      } catch (error) {
        if (!request.signal.aborted) setError(error?.message || 'Unable to load gallery.');
      } finally {
        if (activeListRequest === request) {
          activeListRequest = null;
          loadMoreButton.disabled = false;
        }
      }
    }

    // The public connector has eight request slots. Leave room for playback and other requests.
    const coverQueue = new Set();
    let activeCovers = 0;
    const coverObserver = new IntersectionObserver(entries => {
      for (const entry of entries) {
        if (entry.isIntersecting) coverQueue.add(entry.target);
        else coverQueue.delete(entry.target);
      }
      pumpCovers();
    }, { rootMargin: '400px' });

    function pumpCovers() {
      for (const thumb of coverQueue) {
        if (activeCovers >= 4) break;
        coverQueue.delete(thumb);
        if (!thumb.isConnected) continue;
        coverObserver.unobserve(thumb);
        activeCovers++;
        loadCover(thumb).finally(() => {
          activeCovers--;
          pumpCovers();
        });
      }
    }

    async function loadCover(thumb) {
      for (const delay of [0, 400, 1200, 3000]) {
        if (delay) await new Promise(resolve => setTimeout(resolve, delay));
        if (!thumb.isConnected) return;
        const image = new Image();
        image.alt = '';
        image.src = delay ? thumb.dataset.src + '?retry=' + delay : thumb.dataset.src;
        try {
          await image.decode();
          thumb.prepend(image);
          return;
        } catch {
          // A busy tunnel or a brief disconnect can interrupt an otherwise valid cover.
        }
      }
      thumb.classList.add('unavailable');
      thumb.setAttribute('aria-label', 'Preview unavailable');
    }

    function render(items = []) {
      emptyState.style.display = !state.liveOnly && state.offset === 0 ? 'block' : 'none';
      for (const item of items) {
        const card = document.createElement('article');
        card.className = 'card';
        card.addEventListener('click', () => openViewer(item));

        const mediaType = item.type === 'video' ? 'Video' : 'Photo';

        card.innerHTML = `
          <div class="thumb">
            <span class="badge">${mediaType}</span>
          </div>
          <div class="meta">
            <div class="name">${escapeHTML(item.id || '')}</div>
            <div class="date">${formatDate(item.createdAt)}</div>
          </div>
        `;

        const thumb = card.querySelector('.thumb');
        thumb.dataset.src = item.thumbnailPath;
        thumb.dataset.kind = item.type;
        thumb.dataset.icon = item.type === 'video' ? '▶' : '▧';
        coverObserver.observe(thumb);
        grid.appendChild(card);
      }

      loadMoreButton.style.display = state.hasMore ? 'inline-flex' : 'none';
    }

    function openViewer(item) {
      if (xrRuntime.session) {
        try {
          xrRuntime.session.end();
        } catch (_) {
          stopXRPlayback();
        }
      }

      releasePreview();
      state.activeItem = item;
      vrButton.disabled = Boolean(item.live);
      viewerTitle.textContent = item.id || '';
      viewerBody.innerHTML = '';
      previewVideoElement = null;
      hideVideoTimeLabel();

      if (item.type === 'video') {
        const video = document.createElement('video');
        video.src = item.mediaPath;
        video.controls = !item.live;
        video.autoplay = Boolean(item.live);
        video.loop = !item.live;
        if (item.live) {
          video.dataset.live = 'true';
          viewerTitle.textContent = 'Preparing live 3D…';
          video.addEventListener('loadeddata', () => {
            if (previewVideoElement !== video) return;
            viewerTitle.textContent = item.id;
            vrButton.disabled = false;
          }, { once: true });
          video.addEventListener('error', () => {
            if (previewVideoElement !== video) return;
            vrButton.disabled = true;
            xrRuntime.session?.end().catch(() => {});
            showDialog('The live stream could not continue. Keep StereoShift open, close any other viewer, and open the video again.', 'Live 3D');
          });
        }
        video.playsInline = true;
        video.addEventListener('loadedmetadata', () => updateVideoTimeLabel(video));
        video.addEventListener('durationchange', () => updateVideoTimeLabel(video));
        video.addEventListener('timeupdate', () => updateVideoTimeLabel(video));
        video.addEventListener('seeked', () => updateVideoTimeLabel(video));
        previewVideoElement = video;
        updateVideoTimeLabel(video);
        viewerBody.appendChild(video);
        if (item.live) {
          const playbackButton = document.createElement('button');
          playbackButton.className = 'btn-outline';
          playbackButton.textContent = 'Play';
          playbackButton.onclick = () => {
            if (video.ended) { openViewer(item); return; }
            if (video.paused) video.play().catch(() => {});
            else video.pause();
          };
          video.onplay = () => { playbackButton.textContent = 'Pause'; };
          video.onpause = () => { playbackButton.textContent = 'Play'; };
          video.onended = () => { playbackButton.textContent = 'Watch again'; vrButton.disabled = true; };
          viewerTitle.after(playbackButton);
          playbackButton.id = 'livePlayback';
        }
      } else {
        const image = document.createElement('img');
        image.src = item.mediaPath;
        image.alt = item.id || 'image';
        viewerBody.appendChild(image);
      }

      overlay.classList.add('show');
      overlay.setAttribute('aria-hidden', 'false');
    }

    function releasePreview() {
      document.getElementById('livePlayback')?.remove();
      const video = previewVideoElement;
      previewVideoElement = null;
      if (video) {
        video.pause();
        video.removeAttribute('src');
        video.load();
      }
    }

    window.addEventListener('pagehide', releasePreview);

    function closeViewer() {
      if (xrRuntime.session) {
        try {
          xrRuntime.session.end();
        } catch (_) {
          stopXRPlayback();
        }
      }

      releasePreview();
      overlay.classList.remove('show');
      overlay.setAttribute('aria-hidden', 'true');
      viewerBody.innerHTML = '';
      previewVideoElement = null;
      hideVideoTimeLabel();
      state.activeItem = null;
    }

    function setError(message) {
      if (!message) {
        errorBanner.style.display = 'none';
        errorBanner.textContent = '';
        return;
      }

      errorBanner.style.display = 'block';
      errorBanner.textContent = message;
    }

    function formatDate(value) {
      if (!value) {
        return '';
      }

      const parsed = new Date(value);
      if (Number.isNaN(parsed.getTime())) {
        return value;
      }

      return new Intl.DateTimeFormat(undefined, {
        year: 'numeric',
        month: 'short',
        day: '2-digit',
        hour: '2-digit',
        minute: '2-digit'
      }).format(parsed);
    }

    function escapeHTML(value) {
      return String(value)
        .replaceAll('&', '&amp;')
        .replaceAll('<', '&lt;')
        .replaceAll('>', '&gt;')
        .replaceAll('"', '&quot;')
        .replaceAll("'", '&#39;');
    }

    resetAndLoad();
  </script>
</body>
</html>
"""
}

struct GalleryHTTPRequest {
    let method: String
    let path: String
    let pathAndQuery: String
    let queryItems: [String: String]
    let headers: [String: String]

    static func parse(data: Data) -> GalleryHTTPRequest? {
        guard let requestText = String(data: data, encoding: .utf8) else {
            return nil
        }

        let sections = requestText.components(separatedBy: "\r\n\r\n")
        guard let head = sections.first else {
            return nil
        }

        let lines = head.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            return nil
        }

        let parts = requestLine.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard parts.count >= 2 else {
            return nil
        }

        let method = String(parts[0]).uppercased()
        let rawTarget = String(parts[1])

        guard rawTarget.hasPrefix("/"), !rawTarget.hasPrefix("//"),
              let components = URLComponents(string: "http://localhost\(rawTarget)") else {
            return nil
        }

        let percentEncodedPath = components.percentEncodedPath
        let path = percentEncodedPath.isEmpty ? "/" : percentEncodedPath
        let pathAndQuery: String

        if let percentEncodedQuery = components.percentEncodedQuery, !percentEncodedQuery.isEmpty {
            pathAndQuery = "\(path)?\(percentEncodedQuery)"
        } else {
            pathAndQuery = path
        }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let separator = line.firstIndex(of: ":") else { continue }
            let key = line[..<separator].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespacesAndNewlines)
            headers[key] = value
        }

        var queryItems: [String: String] = [:]
        for item in components.queryItems ?? [] {
            queryItems[item.name] = item.value ?? ""
        }

        return GalleryHTTPRequest(method: method, path: path, pathAndQuery: pathAndQuery, queryItems: queryItems, headers: headers)
    }
}

private struct GalleryPayload: Encodable {
    let liveVideoPath: String?
    let liveOnly: Bool
    let items: [GalleryPayloadItem]
    let hasMore: Bool
}

private struct GalleryPayloadItem: Encodable {
    let id: String
    let type: String
    let createdAt: String
    let mediaPath: String
    let thumbnailPath: String
}
