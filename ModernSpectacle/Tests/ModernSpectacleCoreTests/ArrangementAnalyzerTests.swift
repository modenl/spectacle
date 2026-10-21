import CoreGraphics
import Testing
@testable import ModernSpectacleCore

@Suite
struct ArrangementAnalyzerTests {
    private let screen = CGRect(x: 0, y: 25, width: 1440, height: 875)

    private func window(_ id: Int, _ frame: CGRect) -> WindowInfo {
        WindowInfo(id: id, app: "Finder", bundleID: "com.apple.finder", kind: .files, title: "w\(id)", frame: frame, displayID: 0, isFocused: false, appActiveSecondsAgo: nil)
    }

    @Test
    func recognisesTiledCascadedAndStacked() {
        let tiled = ArrangementAnalyzer.tileFrames(count: 4, in: screen)
        #expect(ArrangementAnalyzer.style(of: tiled) == .tiled)

        let cascaded = ArrangementAnalyzer.cascadeFrames(count: 3, in: screen)
        #expect(ArrangementAnalyzer.style(of: cascaded) == .cascaded)

        let same = CGRect(x: 100, y: 100, width: 600, height: 400)
        #expect(ArrangementAnalyzer.style(of: [same, same.offsetBy(dx: 3, dy: -2)]) == .stacked)

        let scattered = [CGRect(x: 0, y: 25, width: 500, height: 400), CGRect(x: 900, y: 300, width: 300, height: 300)]
        #expect(ArrangementAnalyzer.style(of: scattered) == .scattered)
    }

    @Test
    func handTiledWindowsCountAsTiledWithSmallGapsAndImperfectEdges() {
        let left = CGRect(x: 0, y: 25, width: 700, height: 860)
        let right = CGRect(x: 712, y: 31, width: 720, height: 850)
        #expect(ArrangementAnalyzer.style(of: [left, right]) == .tiled)
    }

    @Test
    func detectsPartialTilingAndTheRemainingWindows() {
        let left = window(1, CGRect(x: 0, y: 25, width: 700, height: 860))
        let right = window(2, CGRect(x: 710, y: 25, width: 730, height: 860))
        let others = (3...6).map { window($0, CGRect(x: 200 + $0 * 30, y: 200 + $0 * 30, width: 800, height: 500)) }

        let result = ArrangementAnalyzer.partialTiling(windows: [left, right] + others, recentlyMoved: [1, 2])
        #expect(result?.tiled.map(\.id) == [1, 2])
        #expect(result?.remaining.map(\.id) == [3, 4, 5, 6])

        // One moved window is not a tiling; nothing to suggest.
        #expect(ArrangementAnalyzer.partialTiling(windows: [left, right] + others, recentlyMoved: [1]) == nil)
        // Everything already tiled: nothing left to suggest.
        #expect(ArrangementAnalyzer.partialTiling(windows: [left, right], recentlyMoved: [1, 2]) == nil)
    }

    @Test
    func tileFramesCoverTheFrameWithoutOverlap() {
        for count in 1...7 {
            let frames = ArrangementAnalyzer.tileFrames(count: count, in: screen)
            #expect(frames.count == count)
            if count >= 2 {
                #expect(ArrangementAnalyzer.isTiled(frames))
            }
            for frame in frames {
                #expect(screen.insetBy(dx: -1, dy: -1).contains(frame))
            }
        }
    }
}
