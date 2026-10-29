using System.IO;
using System.IO.Compression;
using System.Text;
using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using FastShot.Core.Convert;
using FastShot.Core.Convert.Pdf;
using FastShot.Core.Media;
using Xunit;

namespace FastShot.Core.Tests;

/// <summary>The macOS FileToolsTests: the Tools and Actions wheels' work.</summary>
public sealed class FileToolsTests : IDisposable
{
    readonly string folder = Path.Combine(Path.GetTempPath(), $"tools-{Guid.NewGuid():N}");

    public FileToolsTests() => Directory.CreateDirectory(folder);

    public void Dispose()
    {
        try { Directory.Delete(folder, true); } catch { /* a viewer may hold a file */ }
    }

    [Fact]
    public void WhichToolsAndActionsApply()
    {
        string jpg = Path.Combine(folder, "a.jpg"), pdf1 = Path.Combine(folder, "a.pdf"), pdf2 = Path.Combine(folder, "b.pdf");
        Assert.Equal([FileTool.Edit, FileTool.Crop, FileTool.Background, FileTool.Compress, FileTool.Metadata, FileTool.RecognizeText, FileTool.Translate], FileTools.Tools([jpg]));
        Assert.Contains(FileTool.MergePdf, FileTools.Tools([pdf1, pdf2]));
        Assert.DoesNotContain(FileTool.MergePdf, FileTools.Tools([pdf1]));
        Assert.Empty(FileTools.Tools([jpg, pdf1]));
        Assert.Empty(FileTools.Tools([folder]));
        Assert.Equal(FileAction.Zip, FileTools.Actions([folder])[0]);
        Assert.Equal(FileAction.Unzip, FileTools.Actions([Path.Combine(folder, "x.zip")])[0]);
        Assert.Contains(FileAction.Pin, FileTools.Actions([jpg]));
        Assert.DoesNotContain(FileAction.Pin, FileTools.Actions([pdf1]));
        Assert.Equal([FileTool.Compress], FileTools.Tools([Path.Combine(folder, "s.wav")]));
    }

    [Fact]
    public void CompressMakesAPhotoSmaller() => Sta.Run(() =>
    {
        var jpg = MakePhoto("foto", "jpg");
        var output = FileTools.CompressImage(jpg, folder);
        Assert.Equal("foto (küçük).jpg", Path.GetFileName(output));
        Assert.True(new FileInfo(output).Length < new FileInfo(jpg).Length);
    });

    [Fact]
    public void StripMetadataRemovesLocation() => Sta.Run(() =>
    {
        var jpg = MakePhoto("konum", "jpg", gps: true);
        Assert.NotNull(Query(jpg, "/app1/ifd/gps/{ushort=1}"));
        var clean = FileTools.StripMetadata(jpg, folder);
        Assert.Equal("konum (temiz).jpg", Path.GetFileName(clean));
        Assert.Null(Query(clean, "/app1/ifd/gps/{ushort=1}"));
        Assert.Null(Query(clean, "/app1/ifd/{ushort=40092}"));
        Assert.Equal(300, Decode(clean).PixelWidth);
    });

    [Fact]
    public void CropAndBackground() => Sta.Run(() =>
    {
        var png = MakePhoto("ekran", "png");
        var cropped = Decode(FileTools.Crop(png, new Int32Rect(10, 20, 120, 80), folder));
        Assert.Equal((120, 80), (cropped.PixelWidth, cropped.PixelHeight));
        var framed = FileTools.AddBackground(png, folder);
        Assert.Equal("ekran (arka plan).png", Path.GetFileName(framed));
        var image = Decode(framed);
        Assert.True(image.PixelWidth > 300);
        // The corner is the gradient's violet, the middle is the picture.
        var corner = Pixel(image, 2, 2);
        Assert.True(corner.b > 200 && corner.r < 140, $"corner {corner}");
    });

    [Fact]
    public void MergeCleanAndCompressPdfs() => Sta.Run(() =>
    {
        var first = MakePdf("bir", 2);
        var second = MakePdf("iki", 3);
        var merged = FileTools.MergePdfs([first, second], folder);
        Assert.Equal("bir (birleşik).pdf", Path.GetFileName(merged));
        Assert.Equal(5, PdfConversion.PageCount(merged));
        Assert.Equal(5, PdfFile.Load(merged).Pages().Count);

        var clean = FileTools.StripMetadata(first, folder);
        Assert.Equal(2, PdfConversion.PageCount(clean));
        Assert.DoesNotContain("/Author", Encoding.Latin1.GetString(File.ReadAllBytes(clean)));

        var small = FileTools.Compress(first, folder);
        Assert.Equal(2, PdfConversion.PageCount(small));
        Assert.True(new FileInfo(small).Length < new FileInfo(first).Length * 0.8, $"{new FileInfo(small).Length} vs {new FileInfo(first).Length}");
        var page = PdfConversion.RenderPage(PdfConversion.Open(small), 0, 1);
        Assert.True(page.PixelWidth > 100);
    });

    [Fact]
    public void ZipRoundTrip()
    {
        string a = Path.Combine(folder, "a.txt"), b = Path.Combine(folder, "b.txt");
        File.WriteAllText(a, "bir");
        File.WriteAllText(b, "iki");
        var single = FileTools.Zip([a], folder);
        Assert.Equal("a.zip", Path.GetFileName(single));
        var singleOut = FileTools.Unzip(single, folder);
        Assert.Equal(["a.txt"], Directory.GetFileSystemEntries(singleOut).Select(Path.GetFileName));
        var archive = FileTools.Zip([a, b], folder);
        Assert.Equal("Arşiv.zip", Path.GetFileName(archive));
        var extracted = FileTools.Unzip(archive, folder);
        Assert.Equal(["a.txt", "b.txt"], Directory.GetFileSystemEntries(extracted).Select(Path.GetFileName).Order());

        // A folder keeps its name inside the archive, nested and empty folders included.
        var project = Path.Combine(folder, "Proje");
        Directory.CreateDirectory(Path.Combine(project, "alt"));
        Directory.CreateDirectory(Path.Combine(project, "boş"));
        File.WriteAllText(Path.Combine(project, "alt", "c.txt"), "üç");
        var zipped = FileTools.Zip([project], folder);
        Assert.Equal("Proje.zip", Path.GetFileName(zipped));
        using var zip = ZipFile.OpenRead(zipped);
        Assert.Equal(["Proje/alt/c.txt", "Proje/boş/"], zip.Entries.Select(e => e.FullName).Order());
    }

    [Fact]
    public void RemoveAudioAndCompressVideo() => Sta.Run(() =>
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
        var silent = FileTools.RemoveAudio(mp4, folder);
        Assert.Equal("klip (sessiz).mp4", Path.GetFileName(silent));
        var probe = VideoExporter.Probe(silent);
        Assert.False(probe.audio);
        Assert.InRange(probe.duration, 0.9, 1.1);
        var small = FileTools.Compress(mp4, folder);
        Assert.True(new FileInfo(small).Length > 0);
        Assert.Equal(160, VideoExporter.Probe(small).width);
        Assert.Equal((1920, 1080), VideoExporter.OutputSize(3840, 2160, (1920, 1080)));
        Assert.Equal((1080, 1920), VideoExporter.OutputSize(2160, 3840, (1920, 1080)));
    });

    // MARK: Helpers

    static BitmapSource Decode(string path) => BitmapDecoder.Create(new Uri(path), BitmapCreateOptions.None, BitmapCacheOption.OnLoad).Frames[0];

    static object? Query(string path, string query)
    {
        using var stream = File.OpenRead(path);
        var frame = BitmapDecoder.Create(stream, BitmapCreateOptions.PreservePixelFormat, BitmapCacheOption.OnLoad).Frames[0];
        try { return (frame.Metadata as BitmapMetadata)?.GetQuery(query); }
        catch { return null; }
    }

    static (int r, int g, int b) Pixel(BitmapSource image, int x, int y)
    {
        var bgra = new FormatConvertedBitmap(image, PixelFormats.Bgra32, null, 0);
        var pixel = new byte[4];
        bgra.CopyPixels(new Int32Rect(x, y, 1, 1), pixel, 4, 0);
        return (pixel[2], pixel[1], pixel[0]);
    }

    /// <summary>A noisy 300×200 image, so compression has something to remove.</summary>
    string MakePhoto(string name, string extension, bool gps = false)
    {
        var pixels = new byte[300 * 200 * 4];
        ulong seed = 42;
        for (var y = 0; y < 200; y += 2)
            for (var x = 0; x < 300; x += 2)
            {
                seed = seed * 6364136223846793005 + 1442695040888963407;
                var v = (byte)(seed >> 56);
                for (var dy = 0; dy < 2; dy++)
                    for (var dx = 0; dx < 2; dx++)
                    {
                        var o = ((y + dy) * 300 + x + dx) * 4;
                        pixels[o] = (byte)(y * 255 / 200); pixels[o + 1] = (byte)(x * 255 / 300); pixels[o + 2] = v; pixels[o + 3] = 255;
                    }
            }
        var image = BitmapSource.Create(300, 200, 96, 96, PixelFormats.Bgra32, null, pixels, 1200);
        BitmapEncoder encoder = extension == "png" ? new PngBitmapEncoder() : new JpegBitmapEncoder { QualityLevel = 100 };
        BitmapMetadata? metadata = null;
        if (gps)
        {
            metadata = new BitmapMetadata("jpg");
            metadata.SetQuery("/app1/ifd/gps/{ushort=1}", "N");
            metadata.SetQuery("/app1/ifd/gps/{ushort=2}", new ulong[] { 41ul | (1ul << 32), 0ul | (1ul << 32), 36ul | (1ul << 32) });
            metadata.SetQuery("/app1/ifd/{ushort=40092}", Encoding.Unicode.GetBytes("gizli yorum\0"));
        }
        encoder.Frames.Add(BitmapFrame.Create(new FormatConvertedBitmap(image, PixelFormats.Bgr24, null, 0), null, metadata, null));
        var path = Path.Combine(folder, $"{name}.{extension}");
        using (var file = File.Create(path)) encoder.Save(file);
        return path;
    }

    /// <summary>Uncompressed RGB pages (so compression has work to do) and an /Author in the document information.</summary>
    string MakePdf(string name, int pages)
    {
        var builder = new PdfBuilder();
        var pagesNumber = builder.Reserve();
        var kids = new List<PdfObject>();
        for (var i = 0; i < pages; i++)
        {
            const int size = 400;
            var rgb = new byte[size * size * 3];
            var random = new Random(i);
            for (var p = 0; p < rgb.Length; p += 3) { rgb[p] = (byte)(p / 3 % size * 255 / size); rgb[p + 1] = (byte)random.Next(60, 80); rgb[p + 2] = (byte)(200 - i * 30); }
            var image = builder.Add(new PdfStream(new()
            {
                ["Type"] = new PdfName("XObject"), ["Subtype"] = new PdfName("Image"),
                ["Width"] = new PdfNumber(size, true), ["Height"] = new PdfNumber(size, true),
                ["ColorSpace"] = new PdfName("DeviceRGB"), ["BitsPerComponent"] = new PdfNumber(8, true),
            }, rgb));
            var content = builder.Add(new PdfStream(new(), Encoding.ASCII.GetBytes("q 200 0 0 200 0 0 cm /Im0 Do Q")));
            kids.Add(new PdfReference(builder.Add(new PdfDictionary(new()
            {
                ["Type"] = new PdfName("Page"), ["Parent"] = new PdfReference(pagesNumber, 0),
                ["MediaBox"] = new PdfArray([new PdfNumber(0, true), new PdfNumber(0, true), new PdfNumber(200, true), new PdfNumber(200, true)]),
                ["Resources"] = new PdfDictionary(new() { ["XObject"] = new PdfDictionary(new() { ["Im0"] = new PdfReference(image, 0) }) }),
                ["Contents"] = new PdfReference(content, 0),
            })), 0));
        }
        builder.Set(pagesNumber, new PdfDictionary(new() { ["Type"] = new PdfName("Pages"), ["Kids"] = new PdfArray(kids), ["Count"] = new PdfNumber(pages, true) }));
        var root = builder.Add(new PdfDictionary(new() { ["Type"] = new PdfName("Catalog"), ["Pages"] = new PdfReference(pagesNumber, 0) }));
        var info = builder.Add(new PdfDictionary(new() { ["Author"] = new PdfString(Encoding.ASCII.GetBytes("Gizli Yazar"), false) }));
        var path = Path.Combine(folder, $"{name}.pdf");
        builder.Save(path, root, info);
        return path;
    }
}
