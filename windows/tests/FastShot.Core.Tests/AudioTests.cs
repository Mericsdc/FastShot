using System.IO;
using System.Windows;
using FastShot.Core.Media;
using Xunit;

namespace FastShot.Core.Tests;

public class AudioTests
{
    [Fact]
    public void AudioSurvivesAnnotatedTrimmedExport() => Sta.Run(() =>
    {
        var folder = Path.Combine(Path.GetTempPath(), Guid.NewGuid().ToString());
        Directory.CreateDirectory(folder);
        try
        {
            var source = Path.Combine(folder, "voice.mp4");
            const int fps = 30, seconds = 2, width = 160, height = 120;
            using (var writer = new VideoWriter(source, width, height, fps, audio: AudioFormat.Standard))
            {
                Assert.NotNull(writer.Audio);
                var frame = new byte[width * height * 4];
                for (var i = 0; i < frame.Length; i += 4) { frame[i] = 90; frame[i + 1] = 90; frame[i + 2] = 90; frame[i + 3] = 255; }
                for (var i = 0; i < fps * seconds; i++)
                {
                    writer.WriteFrame(frame, width * 4, i / (double)fps, 1.0 / fps);
                    // 1/30 s of a 440 Hz tone per video frame.
                    var frames = 48000 / fps;
                    var pcm = new byte[frames * 4];
                    for (var s = 0; s < frames; s++)
                    {
                        var t = (i * frames + s) / 48000.0;
                        var v = (short)(Math.Sin(2 * Math.PI * 440 * t) * 12000);
                        BitConverter.TryWriteBytes(pcm.AsSpan(s * 4), v);
                        BitConverter.TryWriteBytes(pcm.AsSpan(s * 4 + 2), v);
                    }
                    writer.WriteAudio(pcm, i / (double)fps);
                }
                writer.Finish();
            }
            Assert.True(VideoExporter.Probe(source).audio, "source must carry an audio track");

            var box = new Annotation(AnnotationKind.rectangle, [new Point(10, 10), new Point(40, 40)], RGBAColor.Red, filled: true);
            var output = Path.Combine(folder, "out.mp4");
            VideoExporter.Export(new VideoExportRequest { Source = source, CanvasSize = new Size(width, height), Annotations = [box], Trim = (0.5, 1.5) },
                                 output, VideoFormat.Mp4, _ => { });
            var probe = VideoExporter.Probe(output);
            Assert.True(probe.audio, "export must keep the audio track");
            Assert.InRange(probe.duration, 0.8, 1.25);

            using var reader = new VideoReader(output, audio: true);
            long loud = 0, total = 0;
            while (reader.ReadNext() is { } item)
            {
                if (item is not AudioChunk chunk) continue;
                for (var i = 0; i + 1 < chunk.Pcm.Length; i += 2)
                {
                    total++;
                    if (Math.Abs(BitConverter.ToInt16(chunk.Pcm, i)) > 4000) loud++;
                }
            }
            Assert.True(total > 48000, $"expected about a second of audio, got {total} samples");
            Assert.True(loud > total / 4, "the tone must still be audible");
        }
        finally { Directory.Delete(folder, true); }
    });
}
