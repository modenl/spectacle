import Foundation
import ModernSpectacleCore

/// Whether a stored key works, checked without spending tokens.
public enum KeyCheck: Equatable, Sendable {
    case valid
    case invalid(String)
    case unreachable(String)
}

/// Asks Jev, TypeSafe's decision model, which windows matter now: a relevance score and a role per window, answered in
/// parallel in one request. Typed answers only, no prose, which is why it is fast enough to run on every key press.
public final class JevRanker: WindowRanker, Sendable {
    public let name = "jev"
    private static let endpoint = URL(string: "https://api.typesafe.ai/v1/systemone")!

    private let timeout: TimeInterval
    private let apiKeyProvider: @Sendable () -> String?

    public init(
        timeout: TimeInterval = 8,
        apiKeyProvider: @escaping @Sendable () -> String? = { KeychainStore.string(for: KeychainStore.jevKeyAccount) }
    ) {
        self.timeout = timeout
        self.apiKeyProvider = apiKeyProvider
    }

    public func rank(_ request: LayoutRequest) async throws -> WindowRanking {
        guard let apiKey = apiKeyProvider(), !apiKey.isEmpty else {
            throw ClaudeRanker.PlannerError.missingAPIKey
        }
        var urlRequest = URLRequest(url: Self.endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try JSONEncoder().encode(JevRankingRequest.body(for: request))

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.waitsForConnectivity = false
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: urlRequest)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            throw ClaudeRanker.PlannerError.http(status, String(decoding: data, as: UTF8.self))
        }
        return try JevRankingRequest.ranking(fromResponse: data, request: request)
    }

    /// Lists the models: authenticated, free.
    public static func check(apiKey: String) async -> KeyCheck {
        var request = URLRequest(url: URL(string: "https://api.typesafe.ai/v1/models")!)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 10
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 200 { return .valid }
            return .invalid("HTTP \(status): \(String(decoding: data.prefix(200), as: UTF8.self))")
        } catch {
            return .unreachable(error.localizedDescription)
        }
    }
}
