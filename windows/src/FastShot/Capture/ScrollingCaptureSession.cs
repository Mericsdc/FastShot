using System.Windows.Interop;

namespace FastShot;

/// <summary>Scrolls the selected application's viewport and keeps only confidently matched frames.</summary>
public sealed class ScrollingCaptureSession
{
    readonly RecordRequest request;
    readonly IntPtr target, root;
    readonly Action<BitmapSource, double> completed;
    readonly Window window;
    readonly TextBlock status = new() { Text = "Yalnızca kaydırılan içeriği seçin; başlık ve görev çubuğunu dışarıda bırakın. Başlatınca hedef pencere otomatik aşağı kaydırılır.", TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 0, 0, 10) };
    readonly Button start = new() { Content = "Başlat", Padding = new Thickness(12, 5, 12, 5), Margin = new Thickness(3) };
    readonly CancellationTokenSource cancellation = new();
    readonly TaskCompletionSource completion = new(TaskCreationOptions.RunContinuationsAsynchronously);
    bool running, discard, closing;
    public event Action? Finished;

    public ScrollingCaptureSession(RecordRequest request, Action<BitmapSource, double> completed)
    {
        this.request = request; this.completed = completed;
        var r = request.PixelRect;
        target = Native.WindowFromPoint(new Native.POINT { X = r.Left + r.Width / 2, Y = r.Top + r.Height / 2 });
        root = Native.GetAncestor(target, 2);
        var panel = new StackPanel { Margin = new Thickness(16) };
        panel.Children.Add(status);
        var buttons = new WrapPanel(); buttons.Children.Add(start);
        var finish = new Button { Content = "Bitir ve düzenle", Padding = new Thickness(12, 5, 12, 5), Margin = new Thickness(3) };
        var cancel = new Button { Content = "Vazgeç", Padding = new Thickness(12, 5, 12, 5), Margin = new Thickness(3) };
        buttons.Children.Add(finish); buttons.Children.Add(cancel); panel.Children.Add(buttons);
        window = new Window { Title = "FastShot Kaydırmalı Yakalama", Icon = AppIcon.WindowIcon, Width = 430, SizeToContent = SizeToContent.Height, ResizeMode = ResizeMode.NoResize, Topmost = true, ShowActivated = false, Content = panel, WindowStartupLocation = WindowStartupLocation.CenterScreen };
        start.Click += async (_, _) => await Run();
        finish.Click += (_, _) => { if (running) cancellation.Cancel(); else window.Close(); };
        cancel.Click += (_, _) => Cancel();
        window.Closing += (_, e) =>
        {
            if (closing) return;
            discard = true; cancellation.Cancel();
            if (running) e.Cancel = true;
        };
        window.Closed += (_, _) => { completion.TrySetResult(); Finished?.Invoke(); cancellation.Dispose(); };
        window.SourceInitialized += (_, _) => Native.SetWindowDisplayAffinity(new WindowInteropHelper(window).Handle, Native.WDA_EXCLUDEFROMCAPTURE);
        window.Loaded += (_, _) =>
        {
            var handle = new WindowInteropHelper(window).Handle;
            Native.GetWindowRect(handle, out var bounds);
            var work = request.Monitor.Work;
            var y = r.Bottom + 8;
            if (y + bounds.Height > work.Bottom) y = Math.Max(work.Top, r.Top - bounds.Height - 8);
            var x = Math.Clamp(r.Left, work.Left, Math.Max(work.Left, work.Right - bounds.Width));
            Native.SetWindowPos(handle, Native.HWND_TOPMOST, x, y, bounds.Width, bounds.Height, Native.SWP_NOACTIVATE);
        };
    }

    public void Show() => window.Show();
    public void Cancel() { if (completion.Task.IsCompleted) return; discard = true; cancellation.Cancel(); if (!running) window.Close(); }
    public Task CancelAsync() { Cancel(); return completion.Task; }

    async Task Run()
    {
        if (running) return;
        running = true; start.IsEnabled = false;
        status.Text = "Yakalanıyor… İşlem bitene kadar hedef pencereyi değiştirmeyin. İstediğiniz yerde Bitir'e basabilirsiniz.";
        var token = cancellation.Token;
        var previousCursor = Native.CursorPosition();
        var r = request.PixelRect;
        Native.GetWindowRect(new WindowInteropHelper(window).Handle, out var controls);
        var wheelPoint = new[] {
            new Native.POINT { X = r.Left + r.Width / 2, Y = r.Top + r.Height / 2 },
            new Native.POINT { X = r.Right - 20, Y = r.Bottom - 20 },
            new Native.POINT { X = r.Left + 20, Y = r.Top + 20 },
        }.FirstOrDefault(p => !controls.Contains(p.X, p.Y));
        Native.SetForegroundWindow(root);
        try
        {
            await Task.Delay(350, token);
            if (wheelPoint.X == 0 && wheelPoint.Y == 0) throw new InvalidOperationException("Denetim penceresi seçili alanı kapatıyor. Daha büyük bir kaydırma alanı seçin.");
            Native.SetCursorPos(wheelPoint.X, wheelPoint.Y);
            var result = await Task.Run(async () =>
            {
                using var capture = new GdiCapture(r.Width, r.Height);
                byte[] Grab()
                {
                    if (!Native.IsWindow(target) || Native.IsIconic(root) || Native.GetForegroundWindow() != root)
                        throw new InvalidOperationException("Hedef pencere değişti. Kaydırmalı yakalama durduruldu.");
                    if (!capture.Grab(r.Left, r.Top, cursor: false, layered: true)) throw new IOException("Ekran okunamadı.");
                    if (Native.GetForegroundWindow() != root) throw new InvalidOperationException("Hedef pencere değişti. Son geçerli görüntü saklandı.");
                    return capture.ToArray();
                }
                var stitcher = new ScrollStitcher(Grab(), r.Width, r.Height);
                var added = 0; var unchanged = 0; var steps = 0; string? note = null;
                for (var i = 0; i < 80 && !token.IsCancellationRequested; i++)
                {
                    steps++;
                    // One wheel notch at a time keeps enough overlap even on small viewports.
                    if (Native.GetForegroundWindow() != root) { note = "Hedef pencere değişti. Son geçerli görüntü saklandı."; break; }
                    var cursor = Native.CursorPosition();
                    if (cursor.X != wheelPoint.X || cursor.Y != wheelPoint.Y) { note = "Fare hareket ettiği için yakalama durduruldu."; break; }
                    if (!Native.ScrollWheel(-120)) throw new InvalidOperationException("Windows bu pencereye kaydırma girdisi gönderemedi.");
                    try { await Task.Delay(650, token); }
                    catch (OperationCanceledException) { break; }
                    if (token.IsCancellationRequested) break;
                    byte[] frame;
                    try { frame = Grab(); }
                    catch (Exception error) when (error is InvalidOperationException or IOException) { note = error.Message; break; }
                    var next = stitcher.Append(frame);
                    if (next == ScrollAppendResult.Added) { added++; unchanged = 0; }
                    else if (next == ScrollAppendResult.Unchanged) { if (++unchanged >= 2) break; }
                    else
                    {
                        note = next == ScrollAppendResult.LimitReached ? "Görüntü boyut sınırına ulaştı." : "Son kare güvenle birleştirilemedi. Daha dar, yalnızca kayan içeriği kapsayan bir alan seçin.";
                        break;
                    }
                }
                if (added == 0) note ??= "Sayfa kaymadı veya sayfanın sonundasınız. Kaydırılabilen içerik alanını seçin.";
                if (steps == 80) note ??= "80 kare sınırına ulaşıldı. Devamı için yeni bir kaydırmalı yakalama başlatabilirsiniz.";
                return (image: stitcher.Image(), note);
            });
            if (!discard)
            {
                completed(result.image, request.Scale);
                if (result.note is { } note) Toast.Show("Kaydırmalı yakalama", Icons.Scan, note);
            }
        }
        catch (OperationCanceledException) { }
        catch (Exception error) { if (!discard) Output.ShowError(error, "Kaydırmalı yakalama durdu"); }
        finally
        {
            var cursor = Native.CursorPosition();
            if (cursor.X == wheelPoint.X && cursor.Y == wheelPoint.Y) Native.SetCursorPos(previousCursor.X, previousCursor.Y);
            running = false; closing = true; window.Close();
        }
    }
}
