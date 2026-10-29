using System.Runtime.ExceptionServices;

namespace FastShot.Core.Tests;

/// <summary>WPF bitmaps and drawing need an STA thread; this runs a test body on one.</summary>
public static class Sta
{
    public static void Run(Action body)
    {
        ExceptionDispatchInfo? failure = null;
        var thread = new Thread(() =>
        {
            try { body(); }
            catch (Exception error) { failure = ExceptionDispatchInfo.Capture(error); }
        });
        thread.SetApartmentState(ApartmentState.STA);
        thread.Start();
        thread.Join();
        failure?.Throw();
    }
}
