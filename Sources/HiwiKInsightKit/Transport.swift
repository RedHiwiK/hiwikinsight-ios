import Foundation

enum SendResult: Sendable, Equatable {
    case accepted
    /// 4xx: the request itself is invalid; drop the batch.
    case rejected(Int)
    /// 5xx / network error: retry later.
    case retry
}

protocol Transport: Sendable {
    func send(_ body: Data) async -> SendResult
}

struct HTTPTransport: Transport {
    let url: URL

    init(endpoint: URL) {
        url = endpoint.appendingPathComponent("v1/events")
    }

    func send(_ body: Data) async -> SendResult {
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // NSData's `.zlib` algorithm produces raw DEFLATE (RFC 1951), which the protocol
        // labels as `Content-Encoding: deflate`.
        if let compressed = try? (body as NSData).compressed(using: .zlib) as Data {
            request.setValue("deflate", forHTTPHeaderField: "Content-Encoding")
            request.httpBody = compressed
        } else {
            request.httpBody = body
        }
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            switch status {
            case 200..<300: return .accepted
            case 400..<500 where status != 408 && status != 429: return .rejected(status)
            default: return .retry
            }
        } catch {
            return .retry
        }
    }
}
