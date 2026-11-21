import Foundation
import Testing
@testable import CedricCore

@Suite struct PrintMetricsTests {
    @Test func lineNumberColumnUsesTheWidestDigit() {
        // At least two places; then one per digit of the line count.
        #expect(PrintMetrics.digitPlaces(lineCount: 0) == 2)
        #expect(PrintMetrics.digitPlaces(lineCount: 1) == 2)
        #expect(PrintMetrics.digitPlaces(lineCount: 99) == 2)
        #expect(PrintMetrics.digitPlaces(lineCount: 100) == 3)
        #expect(PrintMetrics.digitPlaces(lineCount: 9999) == 4)

        #expect(PrintMetrics.widestDigit([]) == 0)
        #expect(PrintMetrics.widestDigit([4, 8.5, 7]) == 8.5)

        // Monospaced: a digit is as wide as a space, so the column is unchanged.
        #expect(PrintMetrics.lineNumberColumnWidth(widestDigit: 7, lineCount: 100) == 21)
        // Proportional: the digit (8) is wider than the space (3). A space-sized
        // column (3 × 2 = 6) is short of the digits (8 × 2 = 16).
        let places = PrintMetrics.digitPlaces(lineCount: 50)
        #expect(places == 2)
        #expect(PrintMetrics.lineNumberColumnWidth(widestDigit: 8, lineCount: 50) == 16)
        #expect(3.0 * Double(places) < PrintMetrics.lineNumberColumnWidth(widestDigit: 8, lineCount: 50))
        // A single line still reserves two places.
        #expect(PrintMetrics.lineNumberColumnWidth(widestDigit: 8, lineCount: 1) == 16)
    }
}
