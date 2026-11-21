import Foundation
import Testing
@testable import CedricCore

@Suite struct ProseFontTests {
    @Test func onlyForMarkdownAndPlainTextAndOnlyWhenOn() {
        #expect(ProseFont.applies(to: .markdown, enabled: true))
        #expect(ProseFont.applies(to: .plain, enabled: true))
        #expect(!ProseFont.applies(to: .markdown, enabled: false))
        #expect(!ProseFont.applies(to: .plain, enabled: false))
        for l in Language.allCases where l != .markdown && l != .plain {
            #expect(!ProseFont.applies(to: l, enabled: true), "\(l) keeps the monospaced font")
        }
    }

    @Test func sizeFollowsTheEditorZoom() {
        #expect(ProseFont.size(prose: 15, editor: 13, editorDefault: 13) == 15)
        // 200% zoom doubles it, 50% halves it (to the half point).
        #expect(ProseFont.size(prose: 15, editor: 26, editorDefault: 13) == 30)
        #expect(ProseFont.size(prose: 15, editor: 6.5, editorDefault: 13) == 7.5)
        #expect(ProseFont.size(prose: 15, editor: 14, editorDefault: 13) == 16)
    }

    @Test func sizeClampedTo6Through72() {
        #expect(ProseFont.clamp(2) == 6)
        #expect(ProseFont.clamp(200) == 72)
        #expect(ProseFont.size(prose: 60, editor: 26, editorDefault: 13) == 72)
        #expect(ProseFont.size(prose: 6, editor: 6, editorDefault: 13) == 6)
        #expect(ProseFont.size(prose: 15, editor: 0, editorDefault: 13) == 15)
        #expect(ProseFont.defaultSize == 15)
    }

    @Test func readableWidthCharacterOfAProportionalFont() {
        #expect(ProseFont.characterWidth(fixedPitch: true, zeroWidth: 7.8, lowercaseAlphabetWidth: 200) == 7.8)
        #expect(ProseFont.characterWidth(fixedPitch: false, zeroWidth: 9, lowercaseAlphabetWidth: 182) == 7)
        #expect(ProseFont.characterWidth(fixedPitch: false, zeroWidth: 9, lowercaseAlphabetWidth: 0) == 9)
    }
}
