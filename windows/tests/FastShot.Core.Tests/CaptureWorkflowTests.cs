using System.IO;
using System.Windows.Media.Imaging;
using FastShot;
using Xunit;

namespace FastShot.Core.Tests;

public class CaptureWorkflowTests
{
    [Fact]
    public void TimelineRemovesMultiplePausesAndKeepsHistoricalTimestamps()
    {
        var timeline = new RecordingTimeline(100);
        timeline.Pause(10_000_100); timeline.Pause(11_000_100);
        Assert.Equal(1, timeline.Seconds(99_000_100));
        timeline.Resume(30_000_100); timeline.Resume(40_000_100);
        timeline.Pause(40_000_100); timeline.Resume(50_000_100);
        Assert.Equal(0.5, timeline.Seconds(5_000_100));
        Assert.Equal(1, timeline.Seconds(20_000_100));
        Assert.Equal(2, timeline.Seconds(45_000_100));
        Assert.Equal(3, timeline.Seconds(60_000_100));
        Assert.False(timeline.IsPaused);
    }

    [Fact]
    public void AudioPacketCrossingPauseIsSlicedOntoContinuousMediaClock()
    {
        var timeline = new RecordingTimeline(0);
        timeline.Pause(10_000_000); timeline.Resume(30_000_000);
        Assert.Equal(new[] { new RecordingTimeline.AudioSpan(0, 5, 5), new RecordingTimeline.AudioSpan(25, 5, 10) }, timeline.AudioSpans(5, 30, 10));
        Assert.Empty(timeline.AudioSpans(10, 20, 10));
        Assert.Equal(new[] { new RecordingTimeline.AudioSpan(0, 4, 11) }, timeline.AudioSpans(31, 4, 10));
    }

    [Fact]
    public void PausedAudioDoesNotLeakIntoMixerEvenForLatePackets()
    {
        var timeline = new RecordingTimeline(0);
        timeline.Pause(10_000_000); timeline.Resume(20_000_000);
        var mixer = new AudioMixer();
        // Eight frames around the pause boundary; the paused samples are much louder.
        var first = 48000 - 4;
        var samples = Enumerable.Repeat(0.8f, 16).ToArray();
        Array.Fill(samples, 0.2f, 0, 8);
        foreach (var span in timeline.AudioSpans(first, 8, AudioMixer.Rate)) mixer.Add(span.Destination, samples, span.Offset, span.Frames);
        var resumed = Enumerable.Repeat(0.4f, 8).ToArray();
        foreach (var span in timeline.AudioSpans(96000, 4, AudioMixer.Rate)) mixer.Add(span.Destination, resumed, span.Offset, span.Frames);
        var (pcm, _) = mixer.Flush(48004);
        Assert.InRange(BitConverter.ToInt16(pcm, first * 4), 6500, 6600);
        Assert.InRange(BitConverter.ToInt16(pcm, 48000 * 4), 13000, 13200);
    }

    [Fact]
    public void OpenPauseDropsFuturePacketsAndClipsBeforeRecording()
    {
        var timeline = new RecordingTimeline(0);
        timeline.Pause(10_000_000);
        Assert.Empty(timeline.AudioSpans(11, 10, 10));
        Assert.Equal(new[] { new RecordingTimeline.AudioSpan(2, 3, 0) }, timeline.AudioSpans(-2, 5, 10));
    }

    static BitmapSource Solid(int width, int height, byte r, byte g, byte b)
    {
        var bytes = new byte[width * height * 4];
        for (var i = 0; i < bytes.Length; i += 4) { bytes[i] = b; bytes[i + 1] = g; bytes[i + 2] = r; bytes[i + 3] = 255; }
        return ImageExporter.FromBgra(bytes, width, height, width * 4);
    }

    [Fact]
    public void QueueMoveRemoveAndCombinePreserveFullResolutionAndOrder() => Sta.Run(() =>
    {
        var queue = new CaptureSequence();
        queue.Add(Solid(4, 3, 255, 0, 0)); queue.Add(Solid(2, 2, 0, 0, 255));
        queue.Move(1, 0);
        var combined = ImageExporter.ToBgra32(queue.Combine());
        Assert.Equal(4, combined.PixelWidth); Assert.Equal(5, combined.PixelHeight);
        var bytes = new byte[4 * 5 * 4]; combined.CopyPixels(bytes, 16, 0);
        Assert.Equal(255, bytes[0]); // Blue, first capture.
        Assert.Equal(new byte[] { 255, 255, 255, 255 }, bytes.AsSpan(2 * 4, 4).ToArray()); // White padding.
        Assert.Equal(255, bytes[2 * 16 + 2]); // Red, second capture.
        queue.RemoveAt(0);
        Assert.Equal(48, queue.Bytes);
        Assert.Single(queue.Images);
    });

    [Fact]
    public void QueueExportsOrderedPdfAndPngWithoutClearingQueue() => Sta.Run(() =>
    {
        var folder = Path.Combine(Path.GetTempPath(), Guid.NewGuid().ToString()); Directory.CreateDirectory(folder);
        try
        {
            var queue = new CaptureSequence(); queue.Add(Solid(40, 30, 255, 0, 0)); queue.Add(Solid(20, 50, 0, 255, 0));
            var pdf = Path.Combine(folder, "queue.pdf"); queue.Export(pdf, true);
            var text = System.Text.Encoding.Latin1.GetString(File.ReadAllBytes(pdf));
            Assert.Contains("/Count 2", text); Assert.Contains("/Width 40 /Height 30", text); Assert.Contains("/Width 20 /Height 50", text);
            var png = Path.Combine(folder, "queue.png"); queue.Export(png, false);
            var image = ImageExporter.Load(png)!; Assert.Equal(40, image.PixelWidth); Assert.Equal(80, image.PixelHeight);
            Assert.Equal(2, queue.Images.Count);
            Assert.Equal(2, Directory.GetFiles(folder).Length);
        }
        finally { Directory.Delete(folder, true); }
    });

    [Fact]
    public void EmptyQueueCannotOverwriteExistingFile() => Sta.Run(() =>
    {
        var path = Path.GetTempFileName();
        try
        {
            File.WriteAllText(path, "keep");
            Assert.Throws<InvalidOperationException>(() => new CaptureSequence().Export(path, true));
            Assert.Equal("keep", File.ReadAllText(path));
        }
        finally { File.Delete(path); }
    });

    [Fact]
    public void QueueLimitRejectsExtraCaptureWithoutLosingExistingItems() => Sta.Run(() =>
    {
        var queue = new CaptureSequence();
        var image = Solid(1, 1, 0, 0, 0);
        for (var i = 0; i < 100; i++) queue.Add(image);
        Assert.Throws<InvalidOperationException>(() => queue.Add(image));
        Assert.Equal(100, queue.Images.Count); Assert.Equal(400, queue.Bytes);
        Assert.Throws<ArgumentOutOfRangeException>(() => queue.Move(0, 100));
    });

    static byte[] Frame(int start, int width = 96, int height = 180, int header = 0, int footer = 0)
    {
        var pixels = new byte[width * height * 4];
        for (var y = 0; y < height; y++)
            for (var x = 0; x < width; x++)
            {
                var p = (y * width + x) * 4;
                var fixedRow = y < header || y >= height - footer;
                var hash = unchecked((uint)((start + y - header) * 15485863 + x * 32452843));
                hash ^= hash >> 13; hash *= 0x85ebca6b; hash ^= hash >> 16;
                pixels[p] = fixedRow ? (byte)100 : (byte)hash;
                pixels[p + 1] = fixedRow ? (byte)100 : (byte)(hash >> 8);
                pixels[p + 2] = fixedRow ? (byte)100 : (byte)(hash >> 16); pixels[p + 3] = 255;
            }
        return pixels;
    }

    [Fact]
    public void ScrollingVariableOffsetsMatchPixelsExactly() => Sta.Run(() =>
    {
        var stitcher = new ScrollStitcher(Frame(0), 96, 180);
        Assert.Equal(ScrollAppendResult.Added, stitcher.Append(Frame(53)));
        Assert.Equal(ScrollAppendResult.Added, stitcher.Append(Frame(117)));
        var image = stitcher.Image(); Assert.Equal(297, image.PixelHeight);
        var bytes = new byte[96 * 297 * 4]; image.CopyPixels(bytes, 96 * 4, 0);
        Assert.Equal(Frame(0, height: 297), bytes);
        Assert.Equal(ScrollAppendResult.Unchanged, stitcher.Append(Frame(117)));
    });

    [Fact]
    public void ScrollingRetainsFixedHeaderAndFooterOnlyOnce() => Sta.Run(() =>
    {
        var stitcher = new ScrollStitcher(Frame(0, header: 20, footer: 12), 96, 180);
        Assert.Equal(ScrollAppendResult.Added, stitcher.Append(Frame(47, header: 20, footer: 12)));
        var image = stitcher.Image(); Assert.Equal(227, image.PixelHeight);
        var bytes = new byte[96 * 227 * 4]; image.CopyPixels(bytes, 96 * 4, 0);
        Assert.Equal(Frame(0, height: 227, header: 20, footer: 12), bytes);
    });

    [Fact]
    public void ScrollingRejectsUnrelatedFramesWithoutChangingOutput() => Sta.Run(() =>
    {
        var stitcher = new ScrollStitcher(Frame(0), 96, 180);
        Assert.Equal(ScrollAppendResult.Ambiguous, stitcher.Append(Frame(500)));
        Assert.Equal(180, stitcher.Height);
        Assert.Throws<ArgumentException>(() => stitcher.Append(new byte[8]));
    });

    [Fact]
    public void ScrollingRejectsRepeatingPatternsWithSeveralValidOffsets()
    {
        byte[] Repeating(int offset)
        {
            var rows = Frame(0, height: 40);
            var image = new byte[96 * 180 * 4];
            for (var y = 0; y < 180; y++) Array.Copy(rows, ((y + offset) % 40) * 96 * 4, image, y * 96 * 4, 96 * 4);
            return image;
        }
        var stitcher = new ScrollStitcher(Repeating(0), 96, 180);
        Assert.Equal(ScrollAppendResult.Ambiguous, stitcher.Append(Repeating(10)));
        Assert.Equal(180, stitcher.Height);
    }

    [Fact]
    public void ScrollingStopsBeforeBitmapHeightLimit()
    {
        var stitcher = new ScrollStitcher(Frame(0, width: 32, height: 32600), 32, 32600);
        Assert.Equal(ScrollAppendResult.LimitReached, stitcher.Append(Frame(500, width: 32, height: 32600)));
        Assert.Equal(32600, stitcher.Height);
    }
}
