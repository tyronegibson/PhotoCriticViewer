import Foundation

/// A fully-received HTTP/1.1 request -- `HTTPRequestParser.parse` returns nil until enough
/// bytes have arrived to build one of these (headers complete, and the full Content-Length
/// body if any), so the caller just keeps appending incoming data and retrying.
struct HTTPRequest {
    let method: String
    let path: String
    let query: [String: String]
    /// Lowercased keys -- HTTP header names are case-insensitive.
    let headers: [String: String]
    let body: Data

    var jsonBody: [String: Any]? {
        guard !body.isEmpty else { return nil }
        return (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
    }
}

enum HTTPRequestParser {
    private static let headerTerminator = Data("\r\n\r\n".utf8)

    /// Returns nil if `buffer` doesn't yet contain a complete request (more data needed, not
    /// an error) -- including when a Content-Length body is still arriving.
    static func parse(_ buffer: Data) -> HTTPRequest? {
        guard let headerEnd = buffer.firstRange(of: headerTerminator) else { return nil }
        guard let headerText = String(data: buffer[..<headerEnd.lowerBound], encoding: .utf8) else { return nil }

        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        let method = String(parts[0])
        let rawTarget = String(parts[1])

        var headers: [String: String] = [:]
        for line in lines.dropFirst() where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[key] = value
        }

        let bodyStart = headerEnd.upperBound
        let contentLength = Int(headers["content-length"] ?? "0") ?? 0
        let availableBodyBytes = buffer.count - bodyStart
        guard availableBodyBytes >= contentLength else { return nil } // body still arriving
        let body = buffer[bodyStart..<(bodyStart + contentLength)]

        let targetParts = rawTarget.split(separator: "?", maxSplits: 1)
        let path = String(targetParts[0])
        var query: [String: String] = [:]
        if targetParts.count > 1 {
            for pair in targetParts[1].split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1)
                guard let rawKey = kv.first else { continue }
                let key = String(rawKey).removingPercentEncoding ?? String(rawKey)
                let rawValue = kv.count > 1 ? String(kv[1]) : ""
                query[key] = rawValue.removingPercentEncoding ?? rawValue
            }
        }

        return HTTPRequest(method: method, path: path, query: query, headers: headers, body: Data(body))
    }
}

enum HTTPStatus {
    static func reason(for code: Int) -> String {
        switch code {
        case 200: return "OK"
        case 202: return "Accepted"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 409: return "Conflict"
        case 500: return "Internal Server Error"
        default: return "Unknown"
        }
    }
}

/// What a route hands back to be written to the wire. JSON by default -- the existing
/// handlers still return `(status, body)` tuples and are wrapped with `init(_:)`; the remote
/// endpoints (previews, downloads, the web UI) set their own content type and headers.
struct LocalAPIResponse {
    var status: Int
    var body: Data
    var contentType: String = "application/json; charset=utf-8"
    var headers: [String: String] = [:]

    init(_ status: Int, _ body: Data, contentType: String = "application/json; charset=utf-8", headers: [String: String] = [:]) {
        self.status = status
        self.body = body
        self.contentType = contentType
        self.headers = headers
    }

    init(_ tuple: (Int, Data)) {
        self.init(tuple.0, tuple.1)
    }
}

/// Builds the {"error": {"code": ..., "message": ...}} shape every non-2xx response uses.
func apiErrorBody(code: String, message: String) -> Data {
    let payload: [String: Any] = ["error": ["code": code, "message": message]]
    return (try? JSONSerialization.data(withJSONObject: payload)) ?? Data("{}".utf8)
}

func apiJSONBody(_ object: Any) -> Data {
    (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8)
}
