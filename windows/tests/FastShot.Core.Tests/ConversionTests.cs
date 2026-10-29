using System.IO;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using FastShot.Core.Convert;
using FastShot.Core.Media;
using Xunit;
using Xunit.Abstractions;

namespace FastShot.Core.Tests;

/// <summary>The macOS FileConverterTests, on Windows' engines. Word is left out (it would start Word on the test machine);
/// set FASTSHOT_TEST_WORD=1 to include it.</summary>
public sealed class ConversionTests : IDisposable
{
    readonly string folder = Path.Combine(Path.GetTempPath(), $"conv-{Guid.NewGuid():N}");
    readonly ITestOutputHelper output;

    public ConversionTests(ITestOutputHelper output)
    {
        this.output = output;
        Directory.CreateDirectory(folder);
        WordEngine.Enabled = Environment.GetEnvironmentVariable("FASTSHOT_TEST_WORD") == "1";
    }

    public void Dispose()
    {
        try { Directory.Delete(folder, true); } catch { /* a viewer may hold a file */ }
    }

    ConversionFormat Format(string id, params string[] paths) =>
        FileConverter.Targets(paths).FirstOrDefault(f => f.Id == id) ?? throw new Xunit.Sdk.XunitException($"no {id} target for {string.Join(", ", paths.Select(Path.GetFileName))}");

    string Convert(string path, string id)
    {
        var outputs = FileConverter.Convert([path], Format(id, path), _ => folder, 0.9, _ => { });
        var result = Assert.Single(outputs);
        Assert.True(File.Exists(result) || Directory.Exists(result), result);
        output.WriteLine($"{Path.GetFileName(path)} → {Path.GetFileName(result)}");
        return result;
    }

    // MARK: Targets

    [Fact]
    public void TargetsSkipTheSourceFormatAndMixedFamilies()
    {
        var png = Path.Combine(folder, "a.png");
        var wav = Path.Combine(folder, "b.wav");
        var imageTargets = FileConverter.Targets([png]).Select(f => f.Id).ToList();
        Assert.DoesNotContain("png", imageTargets);
        Assert.Contains("jpeg", imageTargets);
        Assert.Contains("pdf", imageTargets);
        Assert.Empty(FileConverter.Targets([png, wav]));
        Assert.Equal(FileFamily.Document, FileConverter.Family("x.docx"));
        Assert.Equal(FileFamily.Video, FileConverter.Family("x.mov"));
        Assert.Equal(FileFamily.Pdf, FileConverter.Family("x.pdf"));
        Assert.Null(FileConverter.Family("x.zip"));
        Assert.DoesNotContain("jpeg", FileConverter.Targets([Path.Combine(folder, "c.JPEG")]).Select(f => f.Id));
    }

    // MARK: Images

    [Fact]
    public void ImageConversionsAndTransparencyOnJpeg() => Sta.Run(() =>
    {
        var png = MakeTransparentPng("transparent");
        var ids = new List<string> { "jpeg", "tiff", "gif", "bmp" };
        if (Capabilities.HeifEncoder) ids.Add("heic");
        foreach (var id in ids)
        {
            var result = Convert(png, id);
            var image = ImageExporter.Load(result);
            Assert.NotNull(image);
            Assert.Equal(40, image!.PixelWidth);
        }
        var jpeg = ImageExporter.Load(Path.Combine(folder, "transparent.jpg"))!;
        Assert.True(ImageExporter.Pixel(jpeg, 35, 5).r > 240, "transparent area must become white, not black");
        Assert.True(ImageExporter.Pixel(jpeg, 5, 5).b > 180, "opaque area keeps its colour");
    });

    [Fact]
    public void SeveralImagesBecomeOnePdf() => Sta.Run(() =>
    {
        var first = MakeTransparentPng("one");
        var second = MakeTransparentPng("two");
        var outputs = FileConverter.Convert([first, second], Format("pdf", first, second), _ => folder, 0.9, _ => { });
        Assert.Equal(2, PdfConversion.PageCount(Assert.Single(outputs)));
        var page = PdfConversion.RenderPage(PdfConversion.Open(outputs[0]), 0, 1);
        Assert.InRange(page.PixelWidth, 38, 42); // a 40 px image at 96 dpi makes a 30 pt page, drawn back at 96 dpi
    });

    // MARK: Documents and PDF

    TextDocument Sample()
    {
        var document = new TextDocument();
        var heading = new DocParagraph { Heading = 1 };
        heading.Add("Başlık", default);
        document.Paragraphs.Add(heading);
        var first = new DocParagraph();
        first.Add("Merhaba ", default);
        first.Add("FastShot", new RunStyle(Bold: true, Color: "C00000"));
        document.Paragraphs.Add(first);
        document.Paragraphs.Add(DocParagraph.Plain("İkinci satır\tsekme"));
        return document;
    }

    [Fact]
    public void DocumentsRoundTripBetweenFormats() => Sta.Run(() =>
    {
        var rtf = Path.Combine(folder, "not.rtf");
        Rtf.Write(Sample(), rtf);
        foreach (var id in new[] { "docx", "odt", "html", "txt" }) Convert(rtf, id);

        foreach (var name in new[] { "not.docx", "not.odt", "not.html" })
        {
            var document = DocumentConversion.Read(Path.Combine(folder, name));
            var text = document.PlainText();
            Assert.Contains("İkinci satır", text);
            var bold = document.Paragraphs.SelectMany(p => p.Runs).FirstOrDefault(r => r.Text.Contains("FastShot"));
            Assert.True(bold is not null && bold.Style.Bold, $"{name}: bold run lost");
            Assert.Equal("C00000", bold!.Style.Color);
        }
        var plain = File.ReadAllText(Path.Combine(folder, "not.txt"));
        Assert.Contains("Merhaba FastShot", plain);

        // Headings survive a DOCX written by FastShot (RTF itself has no notion of headings).
        var headed = Path.Combine(folder, "headed.docx");
        Docx.Write(Sample(), headed);
        var docx = DocumentConversion.Read(headed);
        Assert.Equal(1, docx.Paragraphs.First(p => p.Text == "Başlık").Heading);
    });

    [Fact]
    public void MarkdownAndHtmlParseFormatting()
    {
        var md = Markdown.Read("# Başlık\n\nBir **kalın** ve *eğik* `kod`\n\n- madde bir\n- madde iki\n\n1. ilk\n");
        Assert.Equal(1, md.Paragraphs[0].Heading);
        Assert.Contains(md.Paragraphs[1].Runs, r => r.Text == "kalın" && r.Style.Bold);
        Assert.Contains(md.Paragraphs[1].Runs, r => r.Text == "eğik" && r.Style.Italic);
        Assert.Contains(md.Paragraphs[1].Runs, r => r.Text == "kod" && r.Style.Code);
        Assert.Equal("• ", md.Paragraphs[2].Prefix);
        Assert.Equal("1. ", md.Paragraphs[4].Prefix);

        var html = Html.Read("<html><head><title>T</title><style>p{}</style></head><body><h2>Alt</h2><p>Bir <b>kalın</b>&nbsp;ve <span style=\"color:#ff0000\">kırmızı</span></p><ul><li>a</li><li>b</li></ul><table><tr><td>x</td><td>y</td></tr></table></body></html>");
        Assert.Equal("T", html.Title);
        Assert.Equal(2, html.Paragraphs[0].Heading);
        Assert.Contains(html.Paragraphs[1].Runs, r => r.Text == "kalın" && r.Style.Bold);
        Assert.Contains(html.Paragraphs[1].Runs, r => r.Text == "kırmızı" && r.Style.Color == "FF0000");
        Assert.Equal("• ", html.Paragraphs[2].Prefix);
        Assert.Equal("x\ty", html.Paragraphs[4].Text);
    }

    [Fact]
    public void DocumentToPdfAndBack() => Sta.Run(() =>
    {
        var rtf = Path.Combine(folder, "pdf.rtf");
        var sample = Sample();
        sample.Paragraphs[1].Runs.Insert(0, new DocRun("", default));
        Rtf.Write(sample, rtf);
        var pdf = Convert(rtf, "pdf");
        Assert.Equal(1, PdfConversion.PageCount(pdf));

        var pageImage = Convert(pdf, "png");
        Assert.NotNull(ImageExporter.Load(pageImage));
        var text = Convert(pdf, "txt");
        var content = File.ReadAllText(text);
        output.WriteLine(content);
        Assert.Contains("Merhaba", content);

        // The Tools wheel's PDF work keeps the text of a PDF it did not write itself (Edge's xref and object streams).
        var merged = FileTools.MergePdfs([pdf, pdf], folder);
        Assert.Equal(2, PdfConversion.PageCount(merged));
        foreach (var result in new[] { merged, FileTools.Compress(pdf, folder), FileTools.StripMetadata(pdf, folder) })
            Assert.Contains("Merhaba", File.ReadAllText(Convert(result, "txt")));
    });

    [Fact]
    public void LongDocumentPaginatesAndMultiPagePdfBecomesAFolder() => Sta.Run(() =>
    {
        var txt = Path.Combine(folder, "uzun.txt");
        File.WriteAllText(txt, string.Join("\n", Enumerable.Range(1, 200).Select(i => $"Satır {i}")));
        var pdf = Convert(txt, "pdf");
        var pages = PdfConversion.PageCount(pdf);
        Assert.True(pages > 2, $"expected more than 2 pages, got {pages}");
        var pagesFolder = Convert(pdf, "jpeg");
        Assert.True(Directory.Exists(pagesFolder));
        Assert.Equal(pages, Directory.GetFiles(pagesFolder).Length);
    });

    [Fact]
    public void RasterPdfFallbackWorksWithoutEdgeOrWord() => Sta.Run(() =>
    {
        var path = Path.Combine(folder, "raster.pdf");
        DocumentConversion.RasterPdf(Sample(), path, default);
        Assert.Equal(1, PdfConversion.PageCount(path));
    });

    // MARK: Audio and video

    [Fact]
    public void AudioConversions() => Sta.Run(() =>
    {
        var wav = MakeTone(1);
        var ids = new List<string> { "m4a", "aiff", "caf" };
        if (Capabilities.FlacEncoder) ids.Add("flac");
        if (Capabilities.Mp3Encoder) ids.Add("mp3");
        output.WriteLine($"mp3 native={Capabilities.NativeMp3} flac native={Capabilities.NativeFlac}");
        foreach (var id in ids)
        {
            var result = Convert(wav, id);
            var seconds = Duration(result);
            Assert.True(Math.Abs(seconds - 1) < 0.12, $"{id}: {seconds:F3} s");
        }
        // AIFF and CAF come back through FastShot's own readers.
        var back = Convert(Path.Combine(folder, "ton.aiff"), "wav");
        Assert.True(Math.Abs(Duration(back) - 1) < 0.02);
    });

    [Fact]
    public void VideoConversions() => Sta.Run(() =>
    {
        var mp4 = Path.Combine(folder, "klip.mp4");
        using (var writer = new VideoWriter(mp4, 160, 120, 30, audio: AudioFormat.Standard))
        {
            var frame = new byte[160 * 120 * 4];
            for (var i = 0; i < 30; i++)
            {
                writer.WriteFrame(frame, 640, i / 30.0, 1 / 30.0);
                writer.WriteAudio(new byte[1600 * 4], i / 30.0);
            }
            writer.Finish();
        }
        var ids = new List<string> { "gif", "m4a", "wav" };
        if (Capabilities.HevcEncoder) ids.Add("hevc");
        foreach (var id in ids) Assert.True(new FileInfo(Convert(mp4, id)).Length > 0, id);

        // A copy into a new MP4 without re-encoding keeps both tracks.
        var remuxed = Path.Combine(folder, "remux.mp4");
        Remuxer.ToMp4(mp4, remuxed, _ => { });
        var probe = VideoExporter.Probe(remuxed);
        Assert.True(probe.audio);
        Assert.InRange(probe.duration, 0.9, 1.1);

        var silent = Path.Combine(folder, "sessiz.mp4");
        using (var writer = new VideoWriter(silent, 160, 120, 30))
        {
            for (var i = 0; i < 10; i++) writer.WriteFrame(new byte[160 * 120 * 4], 640, i / 30.0, 1 / 30.0);
            writer.Finish();
        }
        var error = Assert.Throws<ConversionException>(() => Convert(silent, "m4a"));
        Assert.Contains("ses yok", error.Message);
    });

    [Fact]
    public void WordConversionsWhenEnabled() => Sta.Run(() =>
    {
        if (!Capabilities.Word) return;
        var rtf = Path.Combine(folder, "word.rtf");
        Rtf.Write(Sample(), rtf);
        var doc = Convert(rtf, "doc");
        Assert.Contains("İkinci satır", DocumentConversion.Read(doc).PlainText());
        Assert.Equal(1, PdfConversion.PageCount(Convert(doc, "pdf")));
    });

    // MARK: Helpers

    static double Duration(string path)
    {
        using var reader = AudioReader.Open(path);
        long bytes = 0;
        while (reader.Read() is { } chunk) bytes += chunk.Length;
        return bytes / (double)reader.Format.BlockAlign / reader.Format.SampleRate;
    }

    string MakeTransparentPng(string name)
    {
        var pixels = new byte[40 * 30 * 4];
        for (var y = 0; y < 30; y++)
            for (var x = 0; x < 20; x++)
            {
                var o = (y * 40 + x) * 4;
                pixels[o] = 230; pixels[o + 1] = 100; pixels[o + 2] = 25; pixels[o + 3] = 255;
            }
        var image = BitmapSource.Create(40, 30, 96, 96, PixelFormats.Bgra32, null, pixels, 160);
        var path = Path.Combine(folder, $"{name}.png");
        File.WriteAllBytes(path, ImageExporter.Encode(image, ImageFormat.Png));
        return path;
    }

    string MakeTone(double seconds)
    {
        var path = Path.Combine(folder, "ton.wav");
        var format = new AudioFormat(44100, 2);
        using var writer = AudioWriter.Create(path, "wav", format);
        var frames = (int)(44100 * seconds);
        var pcm = new byte[frames * 4];
        for (var i = 0; i < frames; i++)
        {
            var v = (short)(Math.Sin(i * 2 * Math.PI * 440 / 44100) * 0.3 * short.MaxValue);
            BitConverter.TryWriteBytes(pcm.AsSpan(i * 4), v);
            BitConverter.TryWriteBytes(pcm.AsSpan(i * 4 + 2), v);
        }
        writer.Write(pcm);
        writer.Finish();
        return path;
    }
}
