using System.IO;
using System.Windows;
using FastShot.Core.Media;
using Xunit;

namespace FastShot.Core.Tests;

public sealed class VideoExportSafetyTests : IDisposable
{
    readonly string folder = Path.Combine(Path.GetTempPath(), "FastShot-export-tests-" + Guid.NewGuid());
    public VideoExportSafetyTests() => Directory.CreateDirectory(folder);
    public void Dispose() => Directory.Delete(folder, true);

    [Theory]
    [InlineData(VideoFormat.Mp4)]
    [InlineData(VideoFormat.Gif)]
    public void UnreadableSourcePreservesExistingOutput(VideoFormat format) => Sta.Run(() =>
    {
        var output = Path.Combine(folder, "existing." + format.FileExtension());
        File.WriteAllText(output, "previous output");
        Assert.ThrowsAny<Exception>(() => VideoExporter.Export(new() { Source = Path.Combine(folder, "missing.mp4"), CanvasSize = new Size(160, 120) }, output, format, _ => { }));
        Assert.Equal("previous output", File.ReadAllText(output));
        Assert.Single(Directory.GetFiles(folder));
    });

    [Theory]
    [InlineData(VideoFormat.Mp4)]
    [InlineData(VideoFormat.Gif)]
    public void CancellationDuringExportPreservesOutputAndRemovesTemporaryFile(VideoFormat format) => Sta.Run(() =>
    {
        var source = MakeVideo();
        var output = Path.Combine(folder, "existing." + format.FileExtension());
        File.WriteAllText(output, "previous output");
        using var cancellation = new CancellationTokenSource();
        Assert.ThrowsAny<OperationCanceledException>(() => VideoExporter.Export(new()
        {
            Source = source, CanvasSize = new Size(160, 120), ForceReencode = true,
        }, output, format, _ => cancellation.Cancel(), cancellation.Token));
        Assert.Equal("previous output", File.ReadAllText(output));
        Assert.Equal(2, Directory.GetFiles(folder).Length);
    });

    [Fact]
    public void ExportCannotOverwriteItsSource() => Sta.Run(() =>
    {
        var source = MakeVideo();
        var bytes = File.ReadAllBytes(source);
        Assert.Throws<VideoExportException>(() => VideoExporter.Export(new() { Source = source, CanvasSize = new Size(160, 120) }, source, VideoFormat.Mp4, _ => { }));
        Assert.Equal(bytes, File.ReadAllBytes(source));
    });

    [Fact]
    public void SuccessfulExportReplacesOldOutput() => Sta.Run(() =>
    {
        var source = MakeVideo();
        var output = Path.Combine(folder, "existing.mp4");
        File.WriteAllText(output, "previous output");
        double progress = 0;
        VideoExporter.Export(new() { Source = source, CanvasSize = new Size(160, 120) }, output, VideoFormat.Mp4, value => progress = value);
        Assert.Equal(File.ReadAllBytes(source), File.ReadAllBytes(output));
        Assert.Equal(1, progress);
        Assert.Equal(2, Directory.GetFiles(folder).Length);
    });

    [Fact]
    public void CodecPreferenceAppliesWithoutAnnotationsAndSupportsH264OnExportBack() => Sta.Run(() =>
    {
        var source = MakeVideo();
        var hevcAvailable = MediaProbe.CanEncodeHevc();
        var output = Path.Combine(folder, "preferred.mp4");
        VideoExporter.Export(new() { Source = source, CanvasSize = new Size(160, 120), PreferHEVC = true }, output, VideoFormat.Mp4, _ => { });
        using (var reader = new VideoReader(output))
            Assert.Equal(new Guid(hevcAvailable ? "43564548-0000-0010-8000-00aa00389b71" : "34363248-0000-0010-8000-00aa00389b71"), reader.Codec);
        var h264 = Path.Combine(folder, "h264.mp4");
        VideoExporter.Export(new() { Source = output, CanvasSize = new Size(160, 120) }, h264, VideoFormat.Mp4, _ => { });
        using var decoded = new VideoReader(h264);
        Assert.Equal(new Guid("34363248-0000-0010-8000-00aa00389b71"), decoded.Codec);
    });

    [Fact]
    public void ResizeAndAudioRemovalAreAppliedWithoutForceReencode() => Sta.Run(() =>
    {
        var source = MakeVideo(audio: true);
        var output = Path.Combine(folder, "small-silent.mp4");
        VideoExporter.Export(new() { Source = source, CanvasSize = new Size(160, 120), MaxSize = (80, 60), IncludeAudio = false }, output, VideoFormat.Mp4, _ => { });
        var probe = VideoExporter.Probe(output);
        Assert.Equal((80, 60, false), (probe.width, probe.height, probe.audio));
    });

    string MakeVideo(bool audio = false)
    {
        var path = Path.Combine(folder, "source.mp4");
        using var writer = new VideoWriter(path, 160, 120, 30, audio: audio ? AudioFormat.Standard : null);
        if (audio) Assert.NotNull(writer.Audio);
        var frame = new byte[160 * 120 * 4];
        for (int i = 0; i < frame.Length; i += 4) { frame[i + 1] = 180; frame[i + 3] = 255; }
        for (int i = 0; i < 30; i++)
        {
            writer.WriteFrame(frame, 640, i / 30.0, 1 / 30.0);
            if (audio) writer.WriteAudio(new byte[1600 * 4], i / 30.0);
        }
        writer.Finish();
        return path;
    }
}
