import CoreGraphics
import Testing
@testable import ModernSpectacleCore

@Suite
struct WindowLayoutCalculatorTests {
    private let calculator = WindowLayoutCalculator()
    private let screen = CGRect(x: 0, y: 24, width: 1440, height: 876)

    @Test
    func maximizeUsesVisibleFrame() {
        let result = calculator.rect(
            for: .maximize,
            currentWindow: CGRect(x: 20, y: 40, width: 400, height: 300),
            sourceVisibleFrame: screen,
            destinationVisibleFrame: screen
        )

        #expect(result == screen)
    }

    @Test
    func centerPreservesWindowSize() {
        let result = calculator.rect(
            for: .center,
            currentWindow: CGRect(x: 0, y: 0, width: 640, height: 480),
            sourceVisibleFrame: screen,
            destinationVisibleFrame: screen
        )

        #expect(result == CGRect(x: 400, y: 222, width: 640, height: 480))
    }

    @Test
    func repeatedLeftHalfCyclesThroughThirds() {
        let half = calculator.rect(
            for: .leftHalf,
            currentWindow: CGRect(x: 400, y: 300, width: 640, height: 480),
            sourceVisibleFrame: screen,
            destinationVisibleFrame: screen
        )

        let oneThird = calculator.rect(
            for: .leftHalf,
            currentWindow: half ?? .zero,
            sourceVisibleFrame: screen,
            destinationVisibleFrame: screen
        )

        let twoThirds = calculator.rect(
            for: .leftHalf,
            currentWindow: oneThird ?? .zero,
            sourceVisibleFrame: screen,
            destinationVisibleFrame: screen
        )

        #expect(half == CGRect(x: 0, y: 24, width: 720, height: 876))
        #expect(oneThird == CGRect(x: 0, y: 24, width: 480, height: 876))
        #expect(twoThirds == CGRect(x: 0, y: 24, width: 960, height: 876))
    }

    @Test
    func movingToAnotherDisplayCentersInsideDestination() {
        let destination = CGRect(x: 1440, y: 40, width: 1280, height: 800)

        let result = calculator.rect(
            for: .nextDisplay,
            currentWindow: CGRect(x: 100, y: 100, width: 700, height: 500),
            sourceVisibleFrame: screen,
            destinationVisibleFrame: destination
        )

        #expect(result == CGRect(x: 1730, y: 190, width: 700, height: 500))
    }
}
