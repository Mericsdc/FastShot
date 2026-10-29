import CoreGraphics
import XCTest
@testable import FastShotCore

final class TranslationTests: XCTestCase {
    private func line(_ text: String, y: CGFloat, x: CGFloat = 10, width: CGFloat = 400) -> TextReflow.Line {
        TextReflow.Line(text: text, box: CGRect(x: x, y: y, width: width, height: 20))
    }

    func testWrappedLinesBecomeOneParagraph() {
        let text = TextReflow.join([line("Bu cümle ekranda iki satıra", y: 0), line("bölünmüş durumda.", y: 24, width: 160)])
        XCTAssertEqual(text, "Bu cümle ekranda iki satıra bölünmüş durumda.")
    }

    func testGapsAndListItemsStartParagraphs() {
        let text = TextReflow.join([
            line("Başlık", y: 0, width: 80),
            line("İlk paragraf burada", y: 60),
            line("• birinci madde", y: 84),
            line("• ikinci madde", y: 108),
        ])
        XCTAssertEqual(text.components(separatedBy: "\n\n").count, 4)
    }

    func testHyphenatedWordIsRejoined() {
        let text = TextReflow.join([line("Metin otomatik çevi-", y: 0), line("rilir.", y: 24, width: 60)])
        XCTAssertEqual(text, "Metin otomatik çevirilir.")
    }

    func testPlainTextReflow() {
        XCTAssertEqual(TextReflow.join("bir\niki\n\nüç"), "bir iki\n\nüç")
    }

    func testLanguageGuess() {
        XCTAssertEqual(TranslationLanguages.guess("Bu bir deneme ve çok güzel bir gün"), "tr")
        XCTAssertEqual(TranslationLanguages.guess("This is the side of the road and it is long"), "en")
        // A Turkish recogniser reading "side" as "sideı" must not turn English into Turkish.
        XCTAssertEqual(TranslationLanguages.guess("The sideı of the house is in the shade and it is cold"), "en")
        XCTAssertEqual(TranslationLanguages.guess("Это русский текст"), "ru")
        XCTAssertNil(TranslationLanguages.guess("1234"))
    }
}
