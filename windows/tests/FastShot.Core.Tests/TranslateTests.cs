using System.Windows;
using FastShot.Core.Translate;
using Xunit;

namespace FastShot.Core.Tests;

public sealed class TranslateTests
{
    static TextReflow.Line Line(string text, double top, double left = 10, double width = 400, double height = 20) =>
        new(text, new Rect(left, top, width, height));

    [Fact]
    public void WrappedLinesBecomeOneParagraph()
    {
        var text = TextReflow.Join([
            Line("Ekran görüntüsü alındı ve dosya", 0),
            Line("masaüstüne kaydedildi. Ayrıca panoya da", 24),
            Line("kopyalandı.", 48, width: 90),
            // A wider gap: the next paragraph.
            Line("Kaydı bitirmek için kısayola", 100),
            Line("yeniden basın.", 124, width: 120),
        ]);
        Assert.Equal("Ekran görüntüsü alındı ve dosya masaüstüne kaydedildi. Ayrıca panoya da kopyalandı.\n\nKaydı bitirmek için kısayola yeniden basın.", text);
    }

    [Fact]
    public void HyphenatedWordsAndListsAreKept()
    {
        var text = TextReflow.Join([
            Line("Dosyalar otomatik olarak dönüş-", 0),
            Line("türülür ve kaydedilir:", 24, width: 300),
            Line("• Görüntüler PNG olarak", 48),
            Line("• Videolar MP4 olarak", 72),
            Line("Hata ayıklama 2-3 dakika", 96),
            Line("Sürer.", 120, width: 60),
        ]);
        Assert.Equal("Dosyalar otomatik olarak dönüştürülür ve kaydedilir:\n\n• Görüntüler PNG olarak\n\n• Videolar MP4 olarak\n\nHata ayıklama 2-3 dakika Sürer.", text);
    }

    [Fact]
    public void PlainTextKeepsBlankLineParagraphs()
    {
        Assert.Equal("one two three\n\nfour five", TextReflow.Join("one\ntwo\r\nthree\n\n\nfour\nfive\n"));
        Assert.Equal("", TextReflow.Join("  \n "));
    }

    [Fact]
    public void GuessesTheLanguage()
    {
        Assert.Equal("tr", Languages.Guess("Kayıt durdu, dosya kaydedilemedi."));
        Assert.Equal("tr", Languages.Guess("Bu bir deneme ve çok kısa"));
        Assert.Equal("en", Languages.Guess("The recording stopped because the disk is full."));
        Assert.Equal("de", Languages.Guess("Die Aufnahme wurde nicht gespeichert, und das ist ein Fehler."));
        Assert.Equal("el", Languages.Guess("Καλημέρα κόσμε"));
        Assert.Null(Languages.Guess("12345 !!"));
    }

    [Fact]
    public void PairsWithoutEnglishGoThroughEnglish()
    {
        Assert.Equal([("tr", "en")], TranslationModels.Steps("tr", "en"));
        Assert.Equal([("en", "tr")], TranslationModels.Steps("en", "tr"));
        Assert.Equal([("de", "en"), ("en", "tr")], TranslationModels.Steps("de", "tr"));
        Assert.Empty(TranslationModels.Steps("tr", "tr"));
    }
}
