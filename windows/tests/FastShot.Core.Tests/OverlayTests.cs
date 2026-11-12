using System.Windows;
using System.IO;
using System.Windows.Input;
using System.Windows.Media;
using Xunit;

namespace FastShot.Core.Tests;

public sealed class OverlayTests
{
    [Theory]
    [InlineData(1920, 1080, 1)]
    [InlineData(1920, 1080, 1.5)]
    [InlineData(1920, 1080, 2)]
    [InlineData(1280, 720, 2)]
    [InlineData(800, 600, 2)]
    [InlineData(640, 480, 2)]
    [InlineData(1280, 720, 3)]
    public void FullScreenButtonsStayInsideOverlay(int width, int height, double scale) => VerifyLayout(width, height, scale);

    [Fact]
    public void ToolbarContentGrowthIsRepositionedAfterInitialLayout() => VerifyLayout(1920, 1080, 1.5, grow: true);

    static void VerifyLayout(int width, int height, double scale, bool grow = false) => Sta.Run(() =>
    {
        var monitor = new FastShot.MonitorInfo(IntPtr.Zero, new(0, 0, width, height), new(0, 0, width, height), scale, true);
        var pixels = new byte[width * height * 4];
        var shot = new FastShot.ScreenShot { Monitor = monitor, Pixels = pixels, Image = ImageExporter.FromBgra(pixels, width, height, width * 4) };
        var session = new FastShot.CaptureSession(FastShot.CaptureSession.CaptureMode.Screenshot, [shot], []);
        var overlay = new FastShot.OverlayView(session, shot, scale);
        using var source = new System.Windows.Interop.HwndSource(new System.Windows.Interop.HwndSourceParameters("FastShot layout test")
        { Width = 1, Height = 1, WindowStyle = unchecked((int)0x80000000) });
        overlay.HandleKey(new KeyEventArgs(Keyboard.PrimaryDevice, source, 0, Key.Enter));
        source.RootVisual = overlay;
        overlay.Measure(new Size(width / scale, height / scale));
        overlay.Arrange(new Rect(0, 0, width / scale, height / scale));
        overlay.UpdateLayout();
        var bounds = new Rect(0, 0, width / scale, height / scale);
        var buttons = Descendants(overlay).OfType<FrameworkElement>().Where(b => b is FastShot.IconButton or FastShot.PillButton).ToList();
        Assert.NotEmpty(buttons);
        if (grow)
        {
            foreach (var button in buttons) button.Width *= 1.8;
            overlay.Measure(bounds.Size);
            overlay.Arrange(bounds);
            overlay.UpdateLayout();
        }
        foreach (var button in buttons)
        {
            var rect = button.TransformToAncestor(overlay).TransformBounds(new Rect(button.RenderSize));
            Assert.True(rect.Width > 0 && rect.Height > 0 && bounds.Contains(rect), $"{button.ToolTip}: {rect} outside {bounds}");
        }
        var bars = overlay.Children.OfType<FrameworkElement>().Where(bar => bar != overlay.CanvasView)
            .Select(bar => bar.TransformToAncestor(overlay).TransformBounds(new Rect(bar.RenderSize))).ToList();
        Assert.Equal(2, bars.Count);
        Assert.False(bars[0].IntersectsWith(bars[1]), $"Toolbars overlap: {bars[0]} and {bars[1]}");
        if (Environment.GetEnvironmentVariable("FASTSHOT_LAYOUT_PREVIEW") is { Length: > 0 } preview)
        {
            Directory.CreateDirectory(preview);
            var bitmap = new System.Windows.Media.Imaging.RenderTargetBitmap((int)bounds.Width, (int)bounds.Height, 96, 96, PixelFormats.Pbgra32);
            bitmap.Render(overlay);
            var encoder = new System.Windows.Media.Imaging.PngBitmapEncoder();
            encoder.Frames.Add(System.Windows.Media.Imaging.BitmapFrame.Create(bitmap));
            using var stream = File.Create(Path.Combine(preview, $"overlay-{width}x{height}-{scale}-{grow}.png"));
            encoder.Save(stream);
        }
    });

    static IEnumerable<DependencyObject> Descendants(DependencyObject root)
    {
        for (int i = 0; i < VisualTreeHelper.GetChildrenCount(root); i++)
        {
            var child = VisualTreeHelper.GetChild(root, i);
            yield return child;
            foreach (var descendant in Descendants(child)) yield return descendant;
        }
    }
}
