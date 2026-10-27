import Foundation

struct HTTPRequest {
    let method: String
    let path: String
    let query: [String: String]
    let headers: [String: String]
    let body: Data
}

struct HTTPResponse {
    var status: Int
    var contentType: String
    var body: Data
    var extraHeaders: [(String, String)]
    /// HEAD requests keep the headers but drop the payload.
    var omitBody: Bool = false

    init(status: Int = 200,
         contentType: String = "application/octet-stream",
         body: Data = Data(),
         extraHeaders: [(String, String)] = []) {
        self.status = status
        self.contentType = contentType
        self.body = body
        self.extraHeaders = extraHeaders
    }

    static func text(_ string: String, status: Int = 200) -> HTTPResponse {
        HTTPResponse(status: status,
                     contentType: "text/plain; charset=utf-8",
                     body: Data(string.utf8))
    }

    static func json(_ value: Any, status: Int = 200) -> HTTPResponse {
        let data = (try? JSONSerialization.data(withJSONObject: value, options: [])) ?? Data("{}".utf8)
        return HTTPResponse(status: status, contentType: "application/json", body: data)
    }

    static func jsonError(_ message: String, status: Int) -> HTTPResponse {
        HTTPResponse.json(["error": message], status: status)
    }

    static func file(_ data: Data, contentType: String) -> HTTPResponse {
        HTTPResponse(contentType: contentType, body: data)
    }

    var reason: String {
        switch status {
        case 200: return "OK"
        case 204: return "No Content"
        case 400: return "Bad Request"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 500: return "Internal Server Error"
        default: return "Status"
        }
    }
}

enum MIME {
    static func type(forExtension ext: String) -> String {
        switch ext.lowercased() {
        case "js", "mjs": return "text/javascript; charset=utf-8"
        case "css": return "text/css; charset=utf-8"
        case "json", "map", "webmanifest": return "application/json; charset=utf-8"
        case "html", "htm": return "text/html; charset=utf-8"
        case "svg": return "image/svg+xml"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "ico": return "image/x-icon"
        case "ttf": return "font/ttf"
        case "otf": return "font/otf"
        case "woff": return "font/woff"
        case "woff2": return "font/woff2"
        case "wasm": return "application/wasm"
        case "md", "markdown", "txt": return "text/plain; charset=utf-8"
        default: return "application/octet-stream"
        }
    }

    static func type(forPath path: String) -> String {
        type(forExtension: (path as NSString).pathExtension)
    }
}
