import Foundation
import FoundationModels
import ModernSpectacleCore

/// Ranks the windows with Apple's on-device model (Apple Intelligence): free, offline, and nothing leaves the Mac. The
/// answer is generated straight into a typed structure, so it is always a list of window ids with a role each.
/// Where the model is not available (Intel Macs, Apple Intelligence off, model still downloading) windows are ranked
/// locally instead.
public final class AppleRanker: WindowRanker, Sendable {
    public let name = "apple"

    public init() {}

    public enum Status: Equatable, Sendable {
        case available
        case notReady
        case notEnabled
        case unsupported
    }

    public static var status: Status {
        guard #available(macOS 26.0, *) else { return .unsupported }
        switch SystemLanguageModel.default.availability {
        case .available: return .available
        case .unavailable(.modelNotReady): return .notReady
        case .unavailable(.appleIntelligenceNotEnabled): return .notEnabled
        case .unavailable: return .unsupported
        }
    }

    public struct Unavailable: Error {}

    public func rank(_ request: LayoutRequest) async throws -> WindowRanking {
        guard #available(macOS 26.0, *), Self.status == .available else { throw Unavailable() }
        let session = LanguageModelSession(instructions: RankingPrompt.instructions)
        let response = try await session.respond(to: try RankingState(request).json(), generating: AppleAnswer.self,
                                                 options: GenerationOptions(sampling: .greedy))
        let items = response.content.windows.map { (id: $0.id, role: WindowRole(rawValue: $0.role) ?? .background) }
        return RankingPrompt.ranking(fromOrdered: items, request: request, source: name)
    }
}

@available(macOS 26.0, *)
@Generable
struct AppleAnswer {
    @Guide(description: "Every window, most relevant to the current task first")
    var windows: [AppleRankedWindow]
}

@available(macOS 26.0, *)
@Generable
struct AppleRankedWindow {
    @Guide(description: "The window's id")
    var id: Int
    @Guide(description: "task: needed for the current task; awareness: kept an eye on but not worked in; background: not needed now",
           .anyOf(["task", "awareness", "background"]))
    var role: String
}
