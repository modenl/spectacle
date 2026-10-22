import Foundation
import ModernSpectacleCore

/// Asks Claude for a layout. One HTTPS request per plan; the system prompt and schema are cached server-side.
public final class ClaudePlanner: LayoutPlanner, Sendable {
    public enum PlannerError: Error, CustomStringConvertible {
        case missingAPIKey
        case http(Int, String)
        case refused(String)
        case truncated
        case malformed(String)

        public var description: String {
            switch self {
            case .missingAPIKey: "No API key in the keychain"
            case let .http(code, body): "HTTP \(code): \(body.prefix(300))"
            case let .refused(reason): "Model declined: \(reason)"
            case .truncated: "Response hit max_tokens"
            case let .malformed(detail): "Unexpected response: \(detail)"
            }
        }
    }

    public let name = "claude-haiku-5-5"
    public let model = "claude-haiku-5-5"

    private let timeout: TimeInterval
    private let apiKeyProvider: @Sendable () -> String?

    public init(
        timeout: TimeInterval = 12,
        apiKeyProvider: @escaping @Sendable () -> String? = { KeychainStore.string(for: KeychainStore.apiKeyAccount) }
    ) {
        self.timeout = timeout
        self.apiKeyProvider = apiKeyProvider
    }

    /// A fresh session per call, torn down afterwards, so no connection pool or cache stays resident between plans.
    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.waitsForConnectivity = false
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        return URLSession(configuration: configuration)
    }

    public enum KeyCheck: Equatable, Sendable {
        case valid
        case invalid(String)
        case unreachable(String)
    }

    /// Cheapest possible authenticated call: lists one model. Says whether the key works without spending tokens.
    public static func check(apiKey: String) async -> KeyCheck {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/models?limit=1")!)
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.timeoutInterval = 10
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 200 { return .valid }
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])
                .flatMap { $0["error"] as? [String: Any] }?["message"] as? String
            return .invalid("HTTP \(status): \(message ?? "unexpected response")")
        } catch {
            return .unreachable(error.localizedDescription)
        }
    }

    public func plan(_ request: LayoutRequest) async throws -> LayoutPlan {
        guard let apiKey = apiKeyProvider(), !apiKey.isEmpty else {
            throw PlannerError.missingAPIKey
        }

        var urlRequest = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        urlRequest.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        urlRequest.httpBody = try requestBody(for: request)

        let session = makeSession()
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: urlRequest)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            throw PlannerError.http(status, String(decoding: data, as: UTF8.self))
        }
        let choice = try parseTemplatePlan(from: data)
        var plan = LayoutTemplates.plan(from: choice, for: request)
        let picked = choice.displays.map { "\($0.template)" }.joined(separator: ", ")
        plan.summary = "[\(picked)] " + plan.summary
        return plan
    }

    func requestBody(for request: LayoutRequest) throws -> Data {
        let schema = try JSONSerialization.jsonObject(with: Data(LayoutPrompt.outputSchemaJSON.utf8))
        let body: [String: Any] = [
            "model": model,
            "max_tokens": 4096,
            // Lowest latency: no thinking pass, minimum effort. Layout is a fast structured task.
            "thinking": ["type": "disabled"],
            "output_config": [
                "effort": "low",
                "format": ["type": "json_schema", "schema": schema],
            ],
            "system": [
                [
                    "type": "text",
                    "text": LayoutPrompt.systemPrompt,
                    "cache_control": ["type": "ephemeral"],
                ],
            ],
            "messages": [
                ["role": "user", "content": try LayoutPrompt.userMessage(for: request)],
            ],
        ]
        return try JSONSerialization.data(withJSONObject: body)
    }

    func parseTemplatePlan(from data: Data) throws -> TemplatePlan {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw PlannerError.malformed("not a JSON object")
        }
        let stopReason = object["stop_reason"] as? String
        if stopReason == "refusal" {
            let details = object["stop_details"] as? [String: Any]
            throw PlannerError.refused(details?["explanation"] as? String ?? "no explanation")
        }
        if stopReason == "max_tokens" {
            throw PlannerError.truncated
        }
        guard
            let content = object["content"] as? [[String: Any]],
            let text = content.first(where: { $0["type"] as? String == "text" })?["text"] as? String
        else {
            throw PlannerError.malformed("no text block")
        }
        return try LayoutPrompt.decodeTemplatePlan(from: text)
    }
}
