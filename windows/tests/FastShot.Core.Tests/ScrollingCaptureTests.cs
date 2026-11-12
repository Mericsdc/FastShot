using System.Windows;
using FastShot;
using Xunit;

namespace FastShot.Core.Tests;

public class ScrollingCaptureTests
{
    static byte[] Frame(int start, int height = 180, int header = 0, int footer = 0)
    {
        var pixels = new byte[96 * height * 4];
        for (var y = 0; y < height; y++)
            for (var x = 0; x < 96; x++)
            {
                var p = (y * 96 + x) * 4;
                var hash = unchecked((uint)((start + y - header) * 15485863 + x * 32452843));
                hash ^= hash >> 13; hash *= 0x85ebca6b; hash ^= hash >> 16;
                var stationary = y < header || y >= height - footer;
                pixels[p] = stationary ? (byte)70 : (byte)hash;
                pixels[p + 1] = stationary ? (byte)70 : (byte)(hash >> 8);
                pixels[p + 2] = stationary ? (byte)70 : (byte)(hash >> 16); pixels[p + 3] = 255;
            }
        return pixels;
    }

    [Theory]
    [InlineData(0, 0)]
    [InlineData(20, 12)]
    public void ManualScrollBackAndForwardExtendsOnlyBeyondCapturedContent(int header, int footer) => Sta.Run(() =>
    {
        var stitcher = new ScrollStitcher(Frame(0, header: header, footer: footer), 96, 180);
        foreach (var (position, result) in new[] { (70, ScrollAppendResult.Added), (30, ScrollAppendResult.Revisited), (90, ScrollAppendResult.Added), (60, ScrollAppendResult.Revisited), (130, ScrollAppendResult.Added), (500, ScrollAppendResult.Ambiguous) })
        {
            Assert.Equal(result, stitcher.Append(Frame(position, header: header, footer: footer)));
            Assert.Equal(result == ScrollAppendResult.Ambiguous ? 130 : position, stitcher.Position);
        }
        Assert.Equal(310, stitcher.Height);
        var bytes = new byte[96 * 310 * 4]; stitcher.Image().CopyPixels(bytes, 96 * 4, 0);
        Assert.Equal(Frame(0, 310, header, footer), bytes);
    });

    [Fact]
    public void ReturningToFirstViewportDoesNotDuplicateIt()
    {
        var stitcher = new ScrollStitcher(Frame(0), 96, 180);
        Assert.Equal(ScrollAppendResult.Added, stitcher.Append(Frame(100)));
        Assert.Equal(ScrollAppendResult.Revisited, stitcher.Append(Frame(0)));
        Assert.Equal(0, stitcher.Position); Assert.Equal(280, stitcher.Height);
        Assert.Equal(ScrollAppendResult.Revisited, stitcher.Append(Frame(80)));
        Assert.Equal(ScrollAppendResult.Added, stitcher.Append(Frame(120)));
        Assert.Equal(300, stitcher.Height);
    }

    [Fact]
    public void AmbiguousJumpCanRecoverWithoutDiscardingOrDuplicatingPixels() => Sta.Run(() =>
    {
        var stitcher = new ScrollStitcher(Frame(0), 96, 180);
        stitcher.Append(Frame(60));
        var before = ImageExporter.Encode(stitcher.Image(), ImageFormat.Png);
        Assert.Equal(ScrollAppendResult.Ambiguous, stitcher.Append(Frame(500)));
        Assert.Equal(60, stitcher.Position);
        Assert.Equal(before, ImageExporter.Encode(stitcher.Image(), ImageFormat.Png));
        Assert.Equal(ScrollAppendResult.Added, stitcher.Append(Frame(110)));
        Assert.Equal(290, stitcher.Height);
    });

    [Fact]
    public void FineWheelStepsAndStationaryFramesDoNotLoseRows() => Sta.Run(() =>
    {
        var stitcher = new ScrollStitcher(Frame(0), 96, 180);
        for (var position = 1; position <= 20; position++)
        {
            Assert.Equal(ScrollAppendResult.Added, stitcher.Append(Frame(position)));
            Assert.Equal(ScrollAppendResult.Unchanged, stitcher.Append(Frame(position)));
        }
        var actual = new byte[96 * 200 * 4]; stitcher.Image().CopyPixels(actual, 96 * 4, 0);
        Assert.Equal(Frame(0, 200), actual);
    });

    [Fact]
    public void PreviewIsBoundedFrozenAndDoesNotChangeFullResolutionCapture() => Sta.Run(() =>
    {
        var stitcher = new ScrollStitcher(Frame(0), 96, 180);
        stitcher.Append(Frame(80));
        var preview = stitcher.Preview(32, 60);
        Assert.True(preview.IsFrozen); Assert.Equal(22, preview.PixelWidth); Assert.Equal(60, preview.PixelHeight);
        var first = new byte[4]; preview.CopyPixels(new Int32Rect(0, 0, 1, 1), first, 4, 0);
        Assert.Equal(Frame(0).Take(4), first);
        Assert.Equal(96, stitcher.Image().PixelWidth); Assert.Equal(260, stitcher.Image().PixelHeight);
        Assert.Throws<ArgumentOutOfRangeException>(() => stitcher.Preview(0, 60));
    });

    [Fact]
    public void CancelledMatchLeavesCaptureUntouched()
    {
        var stitcher = new ScrollStitcher(Frame(0), 96, 180);
        Assert.Throws<OperationCanceledException>(() => stitcher.Append(Frame(60), new CancellationToken(true)));
        Assert.Equal(180, stitcher.Height); Assert.Equal(0, stitcher.Position);
    }

    [Theory]
    [InlineData(1)]
    [InlineData(1.5)]
    [InlineData(2)]
    [InlineData(3)]
    public void FullScreenControlsAndPreviewStayInsideWorkAreaAndDoNotOverlap(double scale) => Sta.Run(() =>
    {
        var hud = new ScrollingCaptureHud(() => { }, () => { }, () => { }, () => { });
        foreach (var width in new[] { 300d, 1280d, 2560d })
        {
            var work = new Rect(-width, -200, width, 900);
            hud.Update("Aşağı kaydırın; istediğiniz yerde Bitir’e basın.", 2560, 24000, true, true, false);
            var size = hud.Measure(new Size(width / scale, work.Height / scale));
            var layout = ScrollingCaptureLayout.Place(work, work, new Size(size.Width * scale, size.Height * scale), new Size(200 * scale, 440 * scale), 10 * scale);
            Assert.True(work.Contains(layout.Toolbar));
            Assert.True(layout.Preview.IsEmpty || work.Contains(layout.Preview));
            Assert.False(!layout.Preview.IsEmpty && layout.Toolbar.IntersectsWith(layout.Preview));
        }
    });

    [Fact]
    public void PreviewUsesSpaceBesideSelectionWhenAvailable()
    {
        var selection = new Rect(400, 100, 900, 600); var work = new Rect(0, 0, 1600, 1000);
        var layout = ScrollingCaptureLayout.Place(selection, work, new Size(500, 100), new Size(200, 400), 10);
        Assert.True(layout.Preview.Right < selection.Left);
        Assert.True(layout.Toolbar.Top > selection.Bottom);
    }

    [Fact]
    public void GrowingPreviewShowsTheWholeImageImmediatelyAfterEachUpdate() => Sta.Run(() =>
    {
        var preview = new ScrollingCapturePreview();
        foreach (var height in new[] { 987, 1021, 1287, 4200, 20000, 987 })
        {
            var bitmap = ImageExporter.FromBgra(Frame(0), 96, 180, 96 * 4);
            var size = preview.Update(bitmap, 1509, height, 440);
            preview.Root.Measure(size); preview.Root.Arrange(new Rect(size)); preview.Root.UpdateLayout();
            var stack = (System.Windows.Controls.StackPanel)((System.Windows.Controls.Border)preview.Root).Child;
            var image = (System.Windows.Controls.Image)stack.Children[1];
            Assert.True(preview.HasImage);
            Assert.Equal(size, preview.Root.RenderSize);
            Assert.InRange(image.ActualHeight, image.Height - 0.01, image.Height + 0.01);
            Assert.InRange(image.ActualWidth, image.Width - 0.01, image.Width + 0.01);
            Assert.InRange(image.ActualHeight, 1, 440.01);
            Assert.Equal(1509d / height, image.ActualWidth / image.ActualHeight, 8);
        }
    });

    [Fact]
    public void HudResizesForWrappedWarningAndKeepsAllButtonsVisible() => Sta.Run(() =>
    {
        var hud = new ScrollingCaptureHud(() => { }, () => { }, () => { }, () => { });
        foreach (var width in new[] { 1000d, 250d })
        {
            hud.Update("Aşağı kaydırın.", 1509, 987, false, true, true);
            var first = hud.Measure(new Size(width, 400));
            hud.Root.Measure(first); hud.Root.Arrange(new Rect(first));
            hud.Update("Daha yavaş kaydırın veya son yakalanan bölüme dönün; önizleme korundu.", 1509, 4200, true, true, false);
            var next = hud.Measure(new Size(width, 400));
            hud.Root.Measure(next); hud.Root.Arrange(new Rect(next)); hud.Root.UpdateLayout();
            Assert.InRange(next.Width, 1, width + 0.01);
            void CheckButtons(DependencyObject node)
            {
                if (node is System.Windows.Controls.Button button)
                {
                    var bounds = button.TransformToAncestor(hud.Root).TransformBounds(new Rect(button.RenderSize));
                    var rootBounds = new Rect(new Point(-0.01, -0.01), new Size(next.Width + 0.02, next.Height + 0.02));
                    Assert.True(rootBounds.Contains(bounds));
                }
                for (var i = 0; i < System.Windows.Media.VisualTreeHelper.GetChildrenCount(node); i++)
                    CheckButtons(System.Windows.Media.VisualTreeHelper.GetChild(node, i));
            }
            CheckButtons(hud.Root);
        }
    });

    [Fact]
    public void TinyScreenKeepsButtonsAndOmitsPreviewWhenThereIsNoRoom()
    {
        var work = new Rect(0, 0, 250, 90);
        var layout = ScrollingCaptureLayout.Place(work, work, new Size(600, 110), new Size(200, 400), 10);
        Assert.True(work.Contains(layout.Toolbar)); Assert.True(layout.Preview.IsEmpty);
    }
}
