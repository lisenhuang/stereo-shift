import Foundation
import os

enum WebShareLinkState: Equatable {
    case connecting
    case ready(URL)
    case unavailable

    var url: URL? {
        if case let .ready(url) = self { return url }
        return nil
    }
}

struct GalleryQuickTunnel {
    private static let logger = Logger(subsystem: "com.huanglisen.StereoShift", category: "QuickTunnel")
    typealias Runner = (UInt16, String, @escaping @MainActor (URL) -> Void) async throws -> Void

    static func run(port: UInt16, key: String, ready: @escaping @MainActor (URL) -> Void) async throws {
        try Task.checkCancellation()
        let handle = SSQuickTunnelStart(port, key)
        try await withTaskCancellationHandler {
            defer { SSQuickTunnelStop(handle) }
            var announced = false
            while true {
                try Task.checkCancellation()
                let raw = SSQuickTunnelStatus(handle)!
                let status = String(cString: raw)
                free(raw)
                if !status.isEmpty {
                    guard let url = viewerURL(status) else {
                        logger.error("Quick Tunnel ended during \(status, privacy: .private)")
                        throw URLError(.cannotConnectToHost)
                    }
                    if !announced {
                        announced = true
                        await ready(url)
                    }
                }
                try await Task.sleep(for: announced ? .seconds(1) : .milliseconds(250))
            }
        } onCancel: {
            SSQuickTunnelStop(handle)
        }
    }

    static func viewerURL(_ value: String) -> URL? {
        guard let parts = URLComponents(string: value),
              parts.scheme == "https", parts.port == nil, parts.user == nil, parts.password == nil,
              parts.query == nil, parts.fragment == nil, parts.path.isEmpty || parts.path == "/",
              let host = parts.host, host.hasSuffix(".trycloudflare.com") else { return nil }
        let label = host.dropLast(".trycloudflare.com".count)
        guard (1...63).contains(label.count), label.first != "-", label.last != "-",
              label.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }) else { return nil }
        return parts.url
    }
}
