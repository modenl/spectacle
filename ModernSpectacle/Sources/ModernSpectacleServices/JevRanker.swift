import Foundation
import ModernSpectacleCore

/// Asks Jev, TypeSafe's decision model, which windows matter now: a relevance score and a role per window, answered in
/// parallel in one request. Window titles are sent to TypeSafe; without a key nothing is sent and windows are ranked
/// locally.
public final class JevRanker: WindowRanker, Sendable {
    public let name = "jev"
    private static let endpoint = URL(string: "https://api.typesafe.ai/v1/systemone")!

    public struct Failure: Error, CustomStringConvertible {
        public let description: String
    }

    /// Whether a key works, checked without spending tokens.
    public enum KeyCheck: Equatable, Sendable {
        case valid
        case invalid(String)
        case unreachable(String)
    }

    private let timeout: TimeInterval

    public init(timeout: TimeInterval = 5) {
        self.timeout = timeout
    }

    /// The key from Settings, else the one built into the app (`jev.key` next to build-app.sh, never committed).
    static var key: String? {
        if let stored = KeychainStore.jevKey, !stored.isEmpty { return stored }
        return builtInKey
    }

    public static var hasKey: Bool { key != nil }

    public static var hasBuiltInKey: Bool { builtInKey != nil }

    private static let builtInKey: String? = {
        guard let url = Bundle.main.url(forResource: "jev", withExtension: "key"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let key = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return key.isEmpty ? nil : key
    }()

    public func rank(_ request: LayoutRequest) async throws -> WindowRanking {
        guard let key = Self.key else { throw Failure(description: "no key") }
        var urlRequest = URLRequest(url: Self.endpoint, timeoutInterval: timeout)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try JSONEncoder().encode(JevRequest.body(for: request))
        let (data, response) = try await Self.session.data(for: urlRequest)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200, data.count <= 1_000_000 else {
            throw Failure(description: "HTTP \(status): \(String(decoding: data.prefix(200), as: UTF8.self))")
        }
        return try JevRequest.ranking(fromResponse: data, request: request, source: name)
    }

    /// Lists the models: authenticated, free.
    public static func check(key: String) async -> KeyCheck {
        var request = URLRequest(url: URL(string: "https://api.typesafe.ai/v1/models")!, timeoutInterval: 10)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        do {
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            return status == 200 ? .valid : .invalid("HTTP \(status): \(String(decoding: data.prefix(200), as: UTF8.self))")
        } catch {
            return .unreachable(error.localizedDescription)
        }
    }

    /// One session for the app's lifetime: the connection stays open between presses, so a press costs one round trip.
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }()
}
