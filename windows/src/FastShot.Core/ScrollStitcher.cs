using System.IO;
using System.Windows.Media.Imaging;

namespace FastShot.Core;

public enum ScrollAppendResult { Added, Unchanged, Ambiguous, LimitReached }

/// <summary>Matches vertical overlaps of equal-sized BGRA frames. Refuses unrelated or ambiguous
/// frames rather than silently losing content. A fixed top/bottom band is retained only once.</summary>
public sealed class ScrollStitcher
{
    public const long MaxBytes = 128L * 1024 * 1024;
    readonly int width, height, stride;
    readonly MemoryStream pixels = new();
    byte[] previous;
    public int Height => (int)(pixels.Length / stride);

    public ScrollStitcher(byte[] first, int width, int height)
    {
        if (width < 32 || height < 64 || first.LongLength != (long)width * height * 4 || first.LongLength > MaxBytes)
            throw new ArgumentException("Kaydırılacak alan en az 32 × 64 piksel olmalı ve 128 MB'ı aşmamalı.");
        this.width = width; this.height = height; stride = width * 4;
        previous = (byte[])first.Clone();
        pixels.Write(first);
    }

    public ScrollAppendResult Append(byte[] frame)
    {
        if (frame.Length != previous.Length) throw new ArgumentException("Kare boyutu değişti.", nameof(frame));
        var xStep = Math.Max(1, width / 80);
        var yStep = Math.Max(1, height / 100);
        double RowError(int a, int b)
        {
            long sum = 0; var count = 0;
            for (var x = 4; x < width - 16; x += xStep)
            {
                var p = a * stride + x * 4; var q = b * stride + x * 4;
                for (var c = 0; c < 3; c++) { sum += Math.Abs(previous[p + c] - frame[q + c]); count++; }
            }
            return sum / (double)Math.Max(1, count);
        }
        double Score(int shift, int top, int bottom)
        {
            double sum = 0; var count = 0;
            for (var y = top; y < height - bottom - shift; y += yStep) { sum += RowError(y + shift, y); count++; }
            return count == 0 ? double.MaxValue : sum / count;
        }
        if (Score(0, 0, 0) < 0.6) return ScrollAppendResult.Unchanged;
        // Detect stationary chrome. A content-only selection is still preferable.
        var top = 0; var bottom = 0;
        while (top < height / 4 && RowError(top, top) < 0.6) top++;
        while (bottom < height / 6 && RowError(height - bottom - 1, height - bottom - 1) < 0.6) bottom++;
        if (top < 8) top = 0;
        if (bottom < 8) bottom = 0;
        var maxShift = (height - top - bottom) * 3 / 4;
        var scores = new double[maxShift + 1];
        var best = double.MaxValue; var offset = 0;
        for (var shift = 1; shift <= maxShift; shift++)
        {
            var score = scores[shift] = Score(shift, top, bottom);
            if (score < best) { best = score; offset = shift; }
        }
        if (offset == 0 || best > 6) return ScrollAppendResult.Ambiguous;
        // Repeated rows/blank pages do not contain enough evidence to infer a displacement.
        for (var shift = 1; shift <= maxShift; shift++)
            if (Math.Abs(shift - offset) > 3 && scores[shift] <= best + 0.8) return ScrollAppendResult.Ambiguous;
        if (Height + offset > 32767 || pixels.Length + (long)offset * stride > MaxBytes) return ScrollAppendResult.LimitReached;
        // Replace the old fixed footer with new content and the current footer.
        pixels.SetLength(pixels.Length - (long)bottom * stride);
        pixels.Position = pixels.Length;
        pixels.Write(frame, (height - bottom - offset) * stride, (offset + bottom) * stride);
        previous = (byte[])frame.Clone();
        return ScrollAppendResult.Added;
    }

    public BitmapSource Image() => ImageExporter.FromBgra(pixels.ToArray(), width, Height, stride);
}
