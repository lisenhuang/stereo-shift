import Combine
import Foundation
import Network
import Security

#if canImport(Darwin)
import Darwin
#endif

final class GalleryWebServer: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var isWiFiConnected = false
    @Published private(set) var hostAddress: String?
    @Published private(set) var browseURL: String?
    @Published var errorMessage: String?

    private var httpListener: NWListener?
    private var httpsListener: NWListener?
    private let queue = DispatchQueue(label: "com.stereoshift.gallery-web-server", qos: .utility)
    private let pathMonitor = NWPathMonitor()
    private var holdsScreenAwakeLock = false

    private static let identityFilename = "WebShareIdentity"
    private static let identityExtension = "p12"
    private static let identityPassword = "StereoShiftLocalWebShare"

    init() {
        configureNetworkMonitor()
        refreshWiFiStatus()
    }

    deinit {
        pathMonitor.cancel()
        stop()
    }

    func toggle() {
        if isRunning {
            stop()
        } else {
            start()
        }
    }

    func start() {
        guard !isRunning else { return }

        errorMessage = nil

        guard let hostAddress = Self.localWiFiIPv4Address() else {
            isWiFiConnected = false
            errorMessage = NSLocalizedString("Connect to Wi-Fi to start Web Share.", comment: "")
            return
        }
        isWiFiConnected = true

        do {
            let httpsParameters = try Self.makeHTTPSParameters()
            let httpsListener = try NWListener(using: httpsParameters, on: 443)
            let httpListener = try NWListener(using: .tcp, on: 80)

            configure(listener: httpsListener, isTLS: true, hostAddress: hostAddress)
            configure(listener: httpListener, isTLS: false, hostAddress: hostAddress)

            self.httpsListener = httpsListener
            self.httpListener = httpListener

            httpsListener.start(queue: queue)
            httpListener.start(queue: queue)

            isRunning = true
            self.hostAddress = hostAddress
            browseURL = "https://\(hostAddress)"
            acquireScreenAwakeLockIfNeeded()
        } catch {
            stop()
            errorMessage = Self.describe(error: error)
        }
    }

    func stop() {
        httpListener?.cancel()
        httpsListener?.cancel()
        httpListener = nil
        httpsListener = nil
        isRunning = false
        hostAddress = nil
        browseURL = nil
        releaseScreenAwakeLockIfNeeded()
    }

    private func configureNetworkMonitor() {
        pathMonitor.pathUpdateHandler = { [weak self] _ in
            guard let self else { return }
            DispatchQueue.main.async {
                self.refreshWiFiStatus()
            }
        }
        pathMonitor.start(queue: queue)
    }

    private func refreshWiFiStatus() {
        let wifiAddress = Self.localWiFiIPv4Address()
        isWiFiConnected = (wifiAddress != nil)

        if isRunning, wifiAddress == nil {
            stop()
            errorMessage = NSLocalizedString("Web Share requires Wi-Fi connection.", comment: "")
        }
    }

    private func configure(listener: NWListener, isTLS: Bool, hostAddress: String) {
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }

            switch state {
            case .failed(let error):
                Task { @MainActor in
                    self.stop()
                    self.errorMessage = Self.describe(error: error)
                }
            default:
                break
            }
        }

        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection: connection, isTLS: isTLS, hostAddress: hostAddress)
        }
    }

    private func handle(connection: NWConnection, isTLS: Bool, hostAddress: String) {
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
                    self.handleRequestData(received, on: connection, isTLS: isTLS, hostAddress: hostAddress)
                    return
                }

                if isComplete || received.count > 128 * 1024 {
                    self.sendTextResponse(
                        statusCode: 400,
                        reasonPhrase: "Bad Request",
                        text: "Invalid request.",
                        method: "GET",
                        on: connection
                    )
                    return
                }

                receiveNextChunk()
            }
        }

        receiveNextChunk()
    }

    private func handleRequestData(_ data: Data, on connection: NWConnection, isTLS: Bool, hostAddress: String) {
        guard let request = HTTPRequest.parse(data: data) else {
            sendTextResponse(statusCode: 400, reasonPhrase: "Bad Request", text: "Invalid request.", method: "GET", on: connection)
            return
        }

        guard request.method == "GET" || request.method == "HEAD" else {
            sendTextResponse(statusCode: 405, reasonPhrase: "Method Not Allowed", text: "Method not allowed.", method: request.method, on: connection)
            return
        }

        if !isTLS {
            sendRedirectResponse(to: "https://\(hostAddress)\(request.pathAndQuery)", method: request.method, on: connection)
            return
        }

        route(request: request, on: connection)
    }

    private func route(request: HTTPRequest, on connection: NWConnection) {
        switch request.path {
        case "/":
            sendDataResponse(
                statusCode: 200,
                reasonPhrase: "OK",
                headers: [
                    "Content-Type": "text/html; charset=utf-8",
                    "Cache-Control": "no-store"
                ],
                body: Data(Self.galleryHTML.utf8),
                method: request.method,
                on: connection
            )
        case "/api/items":
            sendItemsJSON(request: request, on: connection)
        default:
            if request.path.hasPrefix("/thumb/") {
                sendThumbnail(request: request, on: connection)
                return
            }

            if request.path.hasPrefix("/media/") {
                sendMedia(request: request, on: connection)
                return
            }

            sendTextResponse(statusCode: 404, reasonPhrase: "Not Found", text: "Not found.", method: request.method, on: connection)
        }
    }

    private func sendItemsJSON(request: HTTPRequest, on connection: NWConnection) {
        let offset = max(Int(request.queryItems["offset"] ?? "") ?? 0, 0)
        let limit = min(max(Int(request.queryItems["limit"] ?? "") ?? 200, 1), 500)

        do {
            let allItems = try AppGalleryLibrary.loadItemsForWeb()
            let slice = allItems.dropFirst(offset).prefix(limit)
            var payloadItems: [GalleryPayloadItem] = []
            payloadItems.reserveCapacity(slice.count)

            let formatter = ISO8601DateFormatter()

            for item in slice {
                let thumbnailURL = item.thumbnailURL ?? AppGalleryLibrary.ensureThumbnailExists(for: item)
                let encodedID = Self.encodedPathComponent(item.id)

                payloadItems.append(
                    GalleryPayloadItem(
                        id: item.id,
                        type: item.type.rawValue,
                        createdAt: formatter.string(from: item.createdAt),
                        mediaPath: "/media/\(encodedID)",
                        thumbnailPath: thumbnailURL == nil ? nil : "/thumb/\(encodedID)"
                    )
                )
            }

            let payload = GalleryPayload(items: payloadItems, hasMore: offset + payloadItems.count < allItems.count)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.withoutEscapingSlashes]
            let body = try encoder.encode(payload)

            sendDataResponse(
                statusCode: 200,
                reasonPhrase: "OK",
                headers: [
                    "Content-Type": "application/json; charset=utf-8",
                    "Cache-Control": "no-store"
                ],
                body: body,
                method: request.method,
                on: connection
            )
        } catch {
            sendTextResponse(statusCode: 500, reasonPhrase: "Internal Server Error", text: "Failed to load gallery.", method: request.method, on: connection)
        }
    }

    private func sendThumbnail(request: HTTPRequest, on connection: NWConnection) {
        guard let item = item(forPath: request.path, prefix: "/thumb/") else {
            sendTextResponse(statusCode: 404, reasonPhrase: "Not Found", text: "Thumbnail not found.", method: request.method, on: connection)
            return
        }

        guard let thumbnailURL = item.thumbnailURL ?? AppGalleryLibrary.ensureThumbnailExists(for: item) else {
            sendTextResponse(statusCode: 404, reasonPhrase: "Not Found", text: "Thumbnail not found.", method: request.method, on: connection)
            return
        }

        sendFileResponse(
            fileURL: thumbnailURL,
            fallbackContentType: "image/jpeg",
            method: request.method,
            rangeHeader: request.headers["range"],
            on: connection
        )
    }

    private func sendMedia(request: HTTPRequest, on connection: NWConnection) {
        guard let item = item(forPath: request.path, prefix: "/media/") else {
            sendTextResponse(statusCode: 404, reasonPhrase: "Not Found", text: "Media not found.", method: request.method, on: connection)
            return
        }

        sendFileResponse(
            fileURL: item.url,
            fallbackContentType: Self.contentType(for: item.url) ?? "application/octet-stream",
            method: request.method,
            rangeHeader: request.headers["range"],
            on: connection
        )
    }

    private func item(forPath path: String, prefix: String) -> GalleryItem? {
        let encodedID = String(path.dropFirst(prefix.count))
        let decodedID = encodedID.removingPercentEncoding ?? encodedID

        guard !decodedID.isEmpty else {
            return nil
        }

        guard let items = try? AppGalleryLibrary.loadItemsForWeb() else {
            return nil
        }

        return items.first { $0.id == decodedID }
    }

    private func sendFileResponse(
        fileURL: URL,
        fallbackContentType: String,
        method: String,
        rangeHeader: String?,
        on connection: NWConnection
    ) {
        do {
            let values = try fileURL.resourceValues(forKeys: [.fileSizeKey])
            guard let fileSizeValue = values.fileSize else {
                throw StereoPipelineError.mediaDecodingFailed
            }

            let fileSize = Int64(fileSizeValue)
            let contentType = Self.contentType(for: fileURL) ?? fallbackContentType

            if let rangeHeader, let range = Self.byteRange(from: rangeHeader, fileSize: fileSize) {
                let data = try readRange(range, from: fileURL)
                let responseHeaders = [
                    "Content-Type": contentType,
                    "Accept-Ranges": "bytes",
                    "Content-Range": "bytes \(range.lowerBound)-\(range.upperBound)/\(fileSize)",
                    "Cache-Control": "no-store"
                ]

                sendDataResponse(
                    statusCode: 206,
                    reasonPhrase: "Partial Content",
                    headers: responseHeaders,
                    body: data,
                    method: method,
                    on: connection
                )
                return
            }

            if method == "HEAD" {
                sendDataResponse(
                    statusCode: 200,
                    reasonPhrase: "OK",
                    headers: [
                        "Content-Type": contentType,
                        "Accept-Ranges": "bytes",
                        "Cache-Control": "no-store"
                    ],
                    body: Data(),
                    method: method,
                    explicitContentLength: fileSize,
                    on: connection
                )
                return
            }

            let body = try Data(contentsOf: fileURL, options: [.mappedIfSafe])
            sendDataResponse(
                statusCode: 200,
                reasonPhrase: "OK",
                headers: [
                    "Content-Type": contentType,
                    "Accept-Ranges": "bytes",
                    "Cache-Control": "no-store"
                ],
                body: body,
                method: method,
                on: connection
            )
        } catch {
            sendTextResponse(statusCode: 500, reasonPhrase: "Internal Server Error", text: "Failed to read file.", method: method, on: connection)
        }
    }

    private func readRange(_ range: ClosedRange<Int64>, from fileURL: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer {
            try? handle.close()
        }

        try handle.seek(toOffset: UInt64(range.lowerBound))
        let length = Int(range.upperBound - range.lowerBound + 1)
        let chunk = try handle.read(upToCount: length) ?? Data()
        return chunk
    }

    private func sendRedirectResponse(to location: String, method: String, on connection: NWConnection) {
        sendDataResponse(
            statusCode: 301,
            reasonPhrase: "Moved Permanently",
            headers: ["Location": location],
            body: Data(),
            method: method,
            on: connection
        )
    }

    private func sendTextResponse(
        statusCode: Int,
        reasonPhrase: String,
        text: String,
        method: String,
        on connection: NWConnection
    ) {
        sendDataResponse(
            statusCode: statusCode,
            reasonPhrase: reasonPhrase,
            headers: ["Content-Type": "text/plain; charset=utf-8"],
            body: Data(text.utf8),
            method: method,
            on: connection
        )
    }

    private func sendDataResponse(
        statusCode: Int,
        reasonPhrase: String,
        headers: [String: String],
        body: Data,
        method: String,
        explicitContentLength: Int64? = nil,
        on connection: NWConnection
    ) {
        var responseHeaders = headers
        responseHeaders["Connection"] = "close"
        responseHeaders["Content-Length"] = String(explicitContentLength ?? Int64(body.count))

        var headerText = "HTTP/1.1 \(statusCode) \(reasonPhrase)\r\n"
        for key in responseHeaders.keys.sorted() {
            if let value = responseHeaders[key] {
                headerText += "\(key): \(value)\r\n"
            }
        }
        headerText += "\r\n"

        let headerData = Data(headerText.utf8)

        connection.send(content: headerData, completion: .contentProcessed { [body] _ in
            if method == "HEAD" || body.isEmpty {
                connection.cancel()
                return
            }

            connection.send(content: body, completion: .contentProcessed { _ in
                connection.cancel()
            })
        })
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

    private static func localWiFiIPv4Address() -> String? {
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
                if preferredInterfaces.contains(name) {
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

        for interfaceName in preferredInterfaces {
            if let match = candidates.first(where: { $0.name == interfaceName && isPrivateIPv4($0.ip) }) {
                return match.ip
            }
        }

        for interfaceName in preferredInterfaces {
            if let match = candidates.first(where: { $0.name == interfaceName }) {
                return match.ip
            }
        }

        if let privateMatch = candidates.first(where: { isPrivateIPv4($0.ip) }) {
            return privateMatch.ip
        }

        return candidates.first?.ip
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
      --card: rgba(16, 26, 52, 0.72);
      --card-border: rgba(130, 165, 255, 0.22);
      --text: #eef3ff;
      --muted: #9cb2e5;
      --accent: #43d0ff;
      --accent2: #8d6bff;
      --danger: #ff5874;
      --shadow: 0 16px 44px rgba(0, 0, 0, 0.36);
    }

    * { box-sizing: border-box; }

    body {
      margin: 0;
      color: var(--text);
      font-family: "SF Pro Text", "Segoe UI", -apple-system, BlinkMacSystemFont, sans-serif;
      background: radial-gradient(circle at 18% 10%, #1a2a56 0%, transparent 36%),
                  radial-gradient(circle at 80% 0%, #1c1742 0%, transparent 34%),
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
      background: rgba(255, 255, 255, 0.03);
      border-color: rgba(255, 255, 255, 0.2);
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
      background: linear-gradient(135deg, rgba(43, 61, 102, .62), rgba(28, 34, 58, .8));
      overflow: hidden;
    }

    .thumb img {
      width: 100%;
      height: 100%;
      object-fit: cover;
      display: block;
    }

    .badge {
      position: absolute;
      right: 8px;
      bottom: 8px;
      padding: 4px 8px;
      border-radius: 999px;
      font-size: 11px;
      font-weight: 700;
      background: rgba(7, 12, 26, .75);
      border: 1px solid rgba(255, 255, 255, .18);
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
      color: #dbe6ff;
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
      background: rgba(2, 6, 16, 0.9);
      z-index: 40;
    }

    .overlay.show { display: grid; }

    .viewer {
      width: min(1080px, 100%);
      max-height: calc(100vh - 36px);
      border-radius: 16px;
      border: 1px solid rgba(143, 178, 255, 0.25);
      background: rgba(14, 20, 38, 0.92);
      display: grid;
      grid-template-rows: auto 1fr;
      overflow: hidden;
      box-shadow: var(--shadow);
    }

    .viewer-head {
      display: flex;
      align-items: center;
      justify-content: space-between;
      padding: 10px 12px;
      border-bottom: 1px solid rgba(255, 255, 255, 0.08);
      gap: 8px;
      flex-wrap: wrap;
    }

    .viewer-title {
      font-size: 14px;
      color: #dce8ff;
      word-break: break-all;
    }

    .viewer-actions {
      display: flex;
      gap: 8px;
      align-items: center;
    }

    .viewer-body {
      min-height: min(70vh, 700px);
      background: #010409;
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

    .empty {
      margin-top: 18px;
      color: var(--muted);
      text-align: center;
      border: 1px dashed rgba(174, 198, 255, .26);
      border-radius: 12px;
      padding: 24px;
      background: rgba(255, 255, 255, 0.01);
    }

    .load-more-wrap {
      margin-top: 14px;
      display: flex;
      justify-content: center;
    }

    .error {
      margin-top: 14px;
      color: #ffd8dd;
      background: rgba(159, 19, 51, 0.28);
      border: 1px solid rgba(255, 115, 140, 0.44);
      padding: 10px 12px;
      border-radius: 10px;
      display: none;
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
        <button id="refreshButton" class="btn-outline">Refresh</button>
      </div>
    </section>

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
    </div>
  </div>

  <script>
    const state = {
      offset: 0,
      limit: 120,
      hasMore: false,
      items: [],
      activeItem: null
    };

    const grid = document.getElementById('grid');
    const emptyState = document.getElementById('emptyState');
    const loadMoreButton = document.getElementById('loadMoreButton');
    const refreshButton = document.getElementById('refreshButton');
    const errorBanner = document.getElementById('errorBanner');

    const overlay = document.getElementById('overlay');
    const viewerTitle = document.getElementById('viewerTitle');
    const viewerBody = document.getElementById('viewerBody');
    const closeButton = document.getElementById('closeButton');
    const vrButton = document.getElementById('vrButton');

    refreshButton.addEventListener('click', () => resetAndLoad());
    loadMoreButton.addEventListener('click', () => loadItems());
    closeButton.addEventListener('click', closeViewer);
    overlay.addEventListener('click', (event) => {
      if (event.target === overlay) {
        closeViewer();
      }
    });

    vrButton.addEventListener('click', async () => {
      const inVRBrowser = /oculusbrowser|quest|vive|vr/i.test(navigator.userAgent);
      let supportsImmersiveVR = false;

      if (navigator.xr && navigator.xr.isSessionSupported) {
        try {
          supportsImmersiveVR = await navigator.xr.isSessionSupported('immersive-vr');
        } catch (_) {
          supportsImmersiveVR = false;
        }
      }

      if (!inVRBrowser && !supportsImmersiveVR) {
        alert('Open this page on a VR headset browser to use VR mode.');
        return;
      }

      alert('VR mode is available only on VR headset browsers.');
    });

    async function resetAndLoad() {
      state.offset = 0;
      state.items = [];
      state.hasMore = false;
      render();
      await loadItems();
    }

    async function loadItems() {
      try {
        setError('');
        const response = await fetch(`/api/items?offset=${state.offset}&limit=${state.limit}`, { cache: 'no-store' });
        if (!response.ok) {
          throw new Error('Failed to load gallery list.');
        }

        const payload = await response.json();
        const incoming = Array.isArray(payload.items) ? payload.items : [];

        state.items = state.items.concat(incoming);
        state.offset += incoming.length;
        state.hasMore = Boolean(payload.hasMore);

        render();
      } catch (error) {
        setError(error?.message || 'Unable to load gallery.');
      }
    }

    function render() {
      grid.innerHTML = '';

      if (state.items.length === 0) {
        emptyState.style.display = 'block';
      } else {
        emptyState.style.display = 'none';
      }

      for (const item of state.items) {
        const card = document.createElement('article');
        card.className = 'card';
        card.addEventListener('click', () => openViewer(item));

        const thumbnailURL = item.thumbnailPath || '';
        const mediaType = item.type === 'video' ? 'Video' : 'Photo';

        card.innerHTML = `
          <div class="thumb">
            ${thumbnailURL ? `<img src="${escapeAttribute(thumbnailURL)}" loading="lazy" alt="thumbnail" />` : ''}
            <span class="badge">${mediaType}</span>
          </div>
          <div class="meta">
            <div class="name">${escapeHTML(item.id || '')}</div>
            <div class="date">${formatDate(item.createdAt)}</div>
          </div>
        `;

        grid.appendChild(card);
      }

      loadMoreButton.style.display = state.hasMore ? 'inline-flex' : 'none';
    }

    function openViewer(item) {
      state.activeItem = item;
      viewerTitle.textContent = item.id || '';
      viewerBody.innerHTML = '';

      if (item.type === 'video') {
        const video = document.createElement('video');
        video.src = item.mediaPath;
        video.controls = true;
        video.autoplay = true;
        video.loop = true;
        video.playsInline = true;
        viewerBody.appendChild(video);
      } else {
        const image = document.createElement('img');
        image.src = item.mediaPath;
        image.alt = item.id || 'image';
        viewerBody.appendChild(image);
      }

      overlay.classList.add('show');
      overlay.setAttribute('aria-hidden', 'false');
    }

    function closeViewer() {
      overlay.classList.remove('show');
      overlay.setAttribute('aria-hidden', 'true');
      viewerBody.innerHTML = '';
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

    function escapeAttribute(value) {
      return escapeHTML(value).replaceAll('`', '&#96;');
    }

    resetAndLoad();
  </script>
</body>
</html>
"""
}

private struct HTTPRequest {
    let method: String
    let path: String
    let pathAndQuery: String
    let queryItems: [String: String]
    let headers: [String: String]

    static func parse(data: Data) -> HTTPRequest? {
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

        guard let components = URLComponents(string: "http://localhost\(rawTarget)") else {
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

        return HTTPRequest(method: method, path: path, pathAndQuery: pathAndQuery, queryItems: queryItems, headers: headers)
    }
}

private struct GalleryPayload: Encodable {
    let items: [GalleryPayloadItem]
    let hasMore: Bool
}

private struct GalleryPayloadItem: Encodable {
    let id: String
    let type: String
    let createdAt: String
    let mediaPath: String
    let thumbnailPath: String?
}
