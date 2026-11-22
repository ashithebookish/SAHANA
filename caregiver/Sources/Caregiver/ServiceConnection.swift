import Foundation

struct ServiceConnection {
    let url: URL
    let token: String?

    static func current() -> ServiceConnection {
        let environment = ProcessInfo.processInfo.environment
        if let address = environment["SAHANA_API_URL"], let url = localURL(address) {
            return ServiceConnection(url: url, token: environment["SAHANA_API_TOKEN"])
        }
        let runtime = project.appending(path: ".sahana-runtime/live")
        if let address = read(runtime.appending(path: "url")), let url = localURL(address),
           let token = read(runtime.appending(path: "token")), token.count >= 24 {
            return ServiceConnection(url: url, token: token)
        }
        // A bare app launch must not attach to a different service using a customary port.
        return ServiceConnection(url: URL(string: "http://127.0.0.1:1")!, token: nil)
    }

    static var actionModelPath: String? {
        if let configured = ProcessInfo.processInfo.environment["SAHANA_ACTION_MODEL"] {
            return configured
        }
        return installedActionModel(in: "live", named: "SAHANAMovement.mlmodelc")
            ?? installedActionModel(in: "reduced", named: "SAHANAMovementReduced.mlmodelc")
    }

    private static func installedActionModel(in profile: String, named filename: String) -> String? {
        let directory = project.appending(path: "training/models").appending(path: profile)
        let model = directory.appending(path: filename)
        let files = FileManager.default
        guard files.fileExists(atPath: directory.appending(path: "model-info.json").path),
              files.fileExists(atPath: model.path) else { return nil }
        return model.path
    }

    private static var project: URL {
        Bundle.main.bundleURL.deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }

    private static func localURL(_ address: String) -> URL? {
        guard let url = URL(string: address), url.scheme == "http", url.host == "127.0.0.1",
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.path.isEmpty || url.path == "/" else { return nil }
        return url
    }

    private static func read(_ url: URL) -> String? {
        try? String(contentsOf: url, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

final class RejectRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
