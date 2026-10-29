using System.IO;
using System.Text.Json;
using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using FastShot.Core.Media;
using Xunit;

namespace FastShot.Core.Tests;

public class AnnotationGeometryTests
{
    [Fact]
    public void RectangleHitsOnlyItsOutlineUnlessFilled()
    {
        var a = new Annotation(AnnotationKind.rectangle, [new Point(10, 10), new Point(110, 60)], lineWidth: 4);
        Assert.True(a.Contains(new Point(10, 35), 2));
        Assert.False(a.Contains(new Point(60, 35), 2));
        a.Filled = true;
        Assert.True(a.Contains(new Point(60, 35), 2));
    }

    [Fact]
    public void ArrowHitAndResizeKeepsOtherEnd()
    {
        var a = new Annotation(AnnotationKind.arrow, [new Point(0, 0), new Point(100, 0)]);
        Assert.True(a.Contains(new Point(50, 3), 2));
        var moved = Annotation.Resized(a, AnnotationHandle.End, new Point(80, 40), constrain: false);
        Assert.Equal(new Point(0, 0), moved.Points[0]);
        Assert.Equal(new Point(80, 40), moved.Points[1]);
    }

    [Fact]
    public void PenScalesWithItsBox()
    {
        var pen = new Annotation(AnnotationKind.pen, [new Point(0, 0), new Point(10, 10), new Point(20, 0)]);
        var wider = Annotation.Resized(pen, AnnotationHandle.Right, new Point(40, 5), constrain: false);
        Assert.Equal([0, 20, 40], wider.Points.Select(p => p.X));
        Assert.Equal([0, 10, 0], wider.Points.Select(p => p.Y));
    }

    [Fact]
    public void SnapAngleLocksTo45Degrees()
    {
        var p = Geo.SnapAngle(new Point(0, 0), new Point(100, 8));
        Assert.Equal(0, p.Y, 3);
        Assert.Equal(Math.Sqrt(100 * 100 + 8 * 8), p.X, 3);
    }

    [Fact]
    public void VisibilityWindow()
    {
        var a = new Annotation(AnnotationKind.line, [new Point(0, 0), new Point(5, 5)], start: 1, end: 2);
        Assert.False(a.IsVisible(0.5));
        Assert.True(a.IsVisible(1.5));
        Assert.False(a.IsVisible(2.5));
        Assert.True(new Annotation(AnnotationKind.line, [], start: 1).IsVisible(99));
    }

    [Fact]
    public void TextGrowsWithContent() => Sta.Run(() =>
    {
        var shortBox = AnnotationRenderer.TextBoxSize("Hi", 20);
        var longBox = AnnotationRenderer.TextBoxSize("Merhaba dünya", 20);
        var twoLines = AnnotationRenderer.TextBoxSize("Merhaba\ndünya", 20);
        Assert.True(longBox.Width > shortBox.Width);
        Assert.True(twoLines.Height > longBox.Height * 1.6);
    });
}

public class ProjectTests
{
    [Fact]
    public void ProjectRoundTripsThroughLibrary()
    {
        var root = Path.Combine(Path.GetTempPath(), Guid.NewGuid().ToString());
        try
        {
            var library = new ProjectLibrary(root);
            var project = library.MakeProject(CaptureKind.image, new Size(100, 50), 2, "png");
            project.Annotations = [new Annotation(AnnotationKind.text, [new Point(4, 4)], RGBAColor.Blue, text: "Not")];
            File.WriteAllBytes(library.MediaPath(project), [0]);
            library.Save(project);
            var loaded = Assert.Single(library.AllProjects());
            Assert.Equal(project.Id, loaded.Id);
            Assert.True(loaded.Annotations[0].ValueEquals(project.Annotations[0]));

            var package = Path.Combine(Path.GetTempPath(), $"{Guid.NewGuid()}.fastshot");
            try
            {
                library.ExportPackage(loaded, package);
                var copy = library.ImportPackage(package);
                Assert.NotEqual(copy.Id, project.Id);
                Assert.Equal(2, library.AllProjects().Count);
            }
            finally { if (Directory.Exists(package)) Directory.Delete(package, true); }
        }
        finally { if (Directory.Exists(root)) Directory.Delete(root, true); }
    }

    [Fact]
    public void JsonMatchesTheMacFormat()
    {
        var project = new CaptureProject(CaptureKind.image, new Size(100, 50), 2, "original.png") { Id = Guid.Parse("7f8ffd1b-1b0a-4b57-9d2e-0c1a2b3c4d5e") };
        project.Annotations = [new Annotation(AnnotationKind.arrow, [new Point(1, 2), new Point(3, 4)], RGBAColor.Red)];
        var json = JsonSerializer.Serialize(project, ProjectJson.Options);
        Assert.Contains("\"canvasSize\": [\n    100,\n    50\n  ]", json.Replace("\r\n", "\n"));
        Assert.Contains("\"kind\": \"arrow\"", json);
        Assert.Contains("\"id\": \"7F8FFD1B-1B0A-4B57-9D2E-0C1A2B3C4D5E\"", json);
        Assert.Contains("\"red\": 0.95", json);
        var back = JsonSerializer.Deserialize<CaptureProject>(json, ProjectJson.Options)!;
        Assert.Equal(new Point(3, 4), back.Annotations[0].Points[1]);
        Assert.Equal(new Size(100, 50), back.CanvasSize);

        // A manifest written by the Mac app, points as arrays, dates in ISO 8601.
        const string mac = """
        {"annotations":[{"color":{"alpha":1,"blue":0.19,"green":0.19,"red":0.95},"filled":false,"fontSize":20,"id":"1D7B6A8E-2A5C-4E73-9C8B-4A1B2C3D4E5F","kind":"rectangle","lineWidth":4,"number":1,"points":[[10,10],[50,30]],"text":""}],
         "canvasSize":[160,120],"createdAt":"2025-10-28T10:00:00Z","id":"0A1B2C3D-4E5F-4A6B-8C7D-9E0F1A2B3C4D","kind":"video","mediaFile":"original.mp4","modifiedAt":"2025-10-28T10:00:00Z","pixelScale":2,"duration":4.5}
        """;
        var fromMac = JsonSerializer.Deserialize<CaptureProject>(mac, ProjectJson.Options)!;
        Assert.Equal(CaptureKind.video, fromMac.Kind);
        Assert.Equal(4.5, fromMac.Duration);
        Assert.Equal(new Rect(10, 10, 40, 20), fromMac.Annotations[0].Box);
    }

    [Fact]
    public void TrimRangeClamps()
    {
        var project = new CaptureProject(CaptureKind.video, new Size(0, 0), 1, "x.mp4") { Duration = 10, TrimStart = -2, TrimEnd = 4 };
        Assert.Equal((0, 4), project.TrimRange);
    }
}

public class RenderingTests
{
    static BitmapSource Solid(int width, int height, Color color)
    {
        var pixels = new byte[width * height * 4];
        for (var i = 0; i < pixels.Length; i += 4) { pixels[i] = color.B; pixels[i + 1] = color.G; pixels[i + 2] = color.R; pixels[i + 3] = 255; }
        return ImageExporter.FromBgra(pixels, width, height, width * 4);
    }

    [Fact]
    public void FlattenPaintsAnnotationsAtPixelScale() => Sta.Run(() =>
    {
        var background = Solid(200, 100, Colors.White);
        var box = new Annotation(AnnotationKind.rectangle, [new Point(10, 10), new Point(40, 40)], RGBAColor.Red, filled: true);
        var image = ImageExporter.Flatten(background, new Size(100, 50), [box]);
        Assert.Equal(200, image.PixelWidth);
        var inside = ImageExporter.Pixel(image, 50, 50);
        var outside = ImageExporter.Pixel(image, 150, 20);
        Assert.True(inside.r > 200);
        Assert.True(inside.g < 100);
        Assert.True(outside.g > 240);
    });

    [Fact]
    public void PixelateAveragesBlocks() => Sta.Run(() =>
    {
        // Left half black, right half white: a pixelated strip across the seam turns grey somewhere.
        var pixels = new byte[64 * 64 * 4];
        for (var y = 0; y < 64; y++)
            for (var x = 0; x < 64; x++)
            {
                var v = (byte)(x < 30 ? 0 : 255);
                var o = (y * 64 + x) * 4;
                pixels[o] = v; pixels[o + 1] = v; pixels[o + 2] = v; pixels[o + 3] = 255;
            }
        var background = ImageExporter.FromBgra(pixels, 64, 64, 256);
        var blur = new Annotation(AnnotationKind.pixelate, [new Point(0, 0), new Point(64, 64)], lineWidth: 12);
        var image = ImageExporter.Flatten(background, new Size(64, 64), [blur]);
        var values = Enumerable.Range(0, 64).Select(x => (int)ImageExporter.Pixel(image, x, 32).r).ToList();
        Assert.Contains(values, v => v > 40 && v < 215);
    });

    [Fact]
    public void EncodedPngCarriesPointScale() => Sta.Run(() =>
    {
        var data = ImageExporter.Encode(Solid(20, 10, Colors.Blue), ImageFormat.Png, pointScale: 2);
        var path = Path.Combine(Path.GetTempPath(), $"{Guid.NewGuid()}.png");
        File.WriteAllBytes(path, data);
        try
        {
            Assert.Equal(2, ImageExporter.PointScale(path));
            var loaded = ImageExporter.Load(path)!;
            var pixel = ImageExporter.Pixel(loaded, 3, 3);
            Assert.Equal((0, 0, 255), (pixel.r, pixel.g, pixel.b));
        }
        finally { File.Delete(path); }
    });

    [Fact]
    public void VideoRoundTripAndExportBurnsTimedAnnotations() => Sta.Run(() =>
    {
        var folder = Path.Combine(Path.GetTempPath(), Guid.NewGuid().ToString());
        Directory.CreateDirectory(folder);
        try
        {
            var source = Path.Combine(folder, "source.mp4");
            MakeVideo(source, 320, 240, seconds: 2);

            using (var reader = new VideoReader(source))
            {
                Assert.Equal(320, reader.Width);
                Assert.Equal(240, reader.Height);
                Assert.InRange(reader.Duration, 1.8, 2.2);
                var frame = reader.FrameAt(0.5)!;
                var top = Pixel(frame, 160, 20);
                var bottom = Pixel(frame, 160, 220);
                Assert.True(top.r > 180 && top.b < 80, $"top row should be red, got {top}");
                Assert.True(bottom.b > 180 && bottom.r < 80, $"bottom row should be blue, got {bottom}");
            }

            // Canvas in points at 2x: the box covers pixels 40...120 and shows only during the second half.
            var box = new Annotation(AnnotationKind.rectangle, [new Point(20, 20), new Point(60, 60)], RGBAColor.Green, filled: true, start: 1.0, end: 2.0);
            var request = new VideoExportRequest { Source = source, CanvasSize = new Size(160, 120), Annotations = [box] };
            var output = Path.Combine(folder, "out.mp4");
            VideoExporter.Export(request, output, VideoFormat.Mp4, _ => { });

            var early = VideoExporter.Frame(output, 0.4)!;
            var late = VideoExporter.Frame(output, 1.5)!;
            Assert.True(ImageExporter.Pixel(early, 80, 80).g < 120, "annotation must be hidden before its start");
            Assert.True(ImageExporter.Pixel(late, 80, 80).g > 150, "annotation must be visible inside its range");
            Assert.True(ImageExporter.Pixel(late, 250, 200).b > 150, "frame outside the box keeps the source");

            var trimmed = Path.Combine(folder, "trim.mp4");
            var trimRequest = new VideoExportRequest { Source = source, CanvasSize = new Size(160, 120), Annotations = [box], Trim = (0.5, 1.5) };
            VideoExporter.Export(trimRequest, trimmed, VideoFormat.Mp4, _ => { });
            Assert.InRange(VideoExporter.Probe(trimmed).duration, 0.8, 1.2);

            var gif = Path.Combine(folder, "out.gif");
            VideoExporter.Export(trimRequest, gif, VideoFormat.Gif, _ => { });
            using var stream = File.OpenRead(gif);
            var decoder = new GifBitmapDecoder(stream, BitmapCreateOptions.None, BitmapCacheOption.OnLoad);
            Assert.True(decoder.Frames.Count >= 10, $"expected at least 10 GIF frames, got {decoder.Frames.Count}");
        }
        finally { Directory.Delete(folder, true); }
    });

    static (int r, int g, int b) Pixel(VideoFrame frame, int x, int y)
    {
        var o = (y * frame.Width + x) * 4;
        return (frame.Bgra[o + 2], frame.Bgra[o + 1], frame.Bgra[o]);
    }

    /// <summary>Writes a short H.264 movie: red top half, blue bottom half.</summary>
    static void MakeVideo(string path, int width, int height, int seconds)
    {
        const int fps = 30;
        using var writer = new VideoWriter(path, width, height, fps);
        var frame = new byte[width * height * 4];
        for (var y = 0; y < height; y++)
            for (var x = 0; x < width; x++)
            {
                var o = (y * width + x) * 4;
                if (y < height / 2) { frame[o] = 20; frame[o + 1] = 40; frame[o + 2] = 200; }
                else { frame[o] = 200; frame[o + 1] = 40; frame[o + 2] = 20; }
                frame[o + 3] = 255;
            }
        for (var i = 0; i < fps * seconds; i++) writer.WriteFrame(frame, width * 4, i / (double)fps, 1.0 / fps);
        writer.Finish();
    }
}
