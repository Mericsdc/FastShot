using System.IO;
using System.Windows.Input;
using Xunit;

namespace FastShot.Core.Tests;

/// <summary>Settings must survive a restart of FastShot (which, for a tray app, means a restart of Windows).</summary>
public sealed class PreferencesTests : IDisposable
{
    readonly string folder = Path.Combine(Path.GetTempPath(), "FastShot.PreferencesTests." + Guid.NewGuid().ToString("N"));
    string File => Path.Combine(folder, "settings.json");
    static readonly KeyCombo ControlP = new(0x50, Native.MOD_CONTROL);

    public PreferencesTests() => Directory.CreateDirectory(folder);

    public void Dispose()
    {
        try { Directory.Delete(folder, recursive: true); } catch (IOException) { }
    }

    [Fact]
    public void ShortcutsSurviveARestart()
    {
        var prefs = Preferences.Load(File);
        prefs.ScreenshotHotkey = ControlP;
        prefs.ScreenshotHotkeyAlt = new KeyCombo(0x50, 0);
        prefs.RecordHotkeyAlt = null;

        var restarted = Preferences.Load(File);
        Assert.Equal(ControlP, restarted.ScreenshotHotkey);
        Assert.Equal(new KeyCombo(0x50, 0), restarted.ScreenshotHotkeyAlt);
        Assert.Equal(KeyCombo.ControlShift7, restarted.RecordHotkey);
        Assert.Null(restarted.RecordHotkeyAlt);
    }

    [Fact]
    public void SavingLeavesNoTemporaryFiles()
    {
        var prefs = Preferences.Load(File);
        prefs.ScreenshotHotkey = ControlP;
        prefs.Onboarded = true;
        Assert.Equal(["settings.json"], Directory.GetFiles(folder).Select(Path.GetFileName));
    }

    [Fact]
    public void OneUnreadableValueKeepsTheOtherSettings()
    {
        // A value this version does not know (an enum from another version, a wrong type) must not reset everything.
        System.IO.File.WriteAllText(File, """
            {
              "ScreenshotHotkey": { "VirtualKey": 80, "Modifiers": 2 },
              "RecordHotkeyAlt": null,
              "ImageFormat": "Webp",
              "FramesPerSecond": "sixty",
              "Onboarded": true
            }
            """);
        var prefs = Preferences.Load(File);
        Assert.Equal(ControlP, prefs.ScreenshotHotkey);
        Assert.Null(prefs.RecordHotkeyAlt);
        Assert.Equal(ImageFormat.Png, prefs.ImageFormat);
        Assert.Equal(30, prefs.FramesPerSecond);
        Assert.True(prefs.Onboarded);
    }

    [Fact]
    public void AnUnreadableFileIsKeptBeforeItIsReplaced()
    {
        // A file cut short (power lost while an older version wrote it) starts FastShot on the defaults,
        // but the first save (Onboarded, right at startup) must not destroy what was there.
        const string torn = """{ "ScreenshotHotkey": { "VirtualKey": 80, "Modif""";
        System.IO.File.WriteAllText(File, torn);
        var prefs = Preferences.Load(File);
        Assert.Equal(KeyCombo.ControlShift2, prefs.ScreenshotHotkey);
        prefs.Onboarded = true;

        Assert.Equal(torn, System.IO.File.ReadAllText(Path.Combine(folder, "settings.unreadable.json")));
        Assert.True(Preferences.Load(File).Onboarded);
    }

    [Fact]
    public void AFileLockedAtStartupIsReadOnceItIsFree()
    {
        // At sign-in, antivirus or backup tools can hold the file for a moment.
        var prefs = Preferences.Load(File);
        prefs.ScreenshotHotkey = ControlP;
        var locked = new FileStream(File, FileMode.Open, FileAccess.ReadWrite, FileShare.None);
        // Its own thread, so a busy thread pool (tests run in parallel) cannot delay the release.
        var release = new Thread(() =>
        {
            Thread.Sleep(400);
            locked.Dispose();
        });
        release.Start();
        var restarted = Preferences.Load(File, retryFor: TimeSpan.FromSeconds(10));
        release.Join();
        Assert.Equal(ControlP, restarted.ScreenshotHotkey);
    }

    [Fact]
    public void AFileThatStaysLockedIsNotOverwritten()
    {
        var prefs = Preferences.Load(File);
        prefs.ScreenshotHotkey = ControlP;
        Preferences restarted;
        using (new FileStream(File, FileMode.Open, FileAccess.ReadWrite, FileShare.None))
        {
            restarted = Preferences.Load(File, retryFor: TimeSpan.FromMilliseconds(200));
            Assert.Equal(KeyCombo.ControlShift2, restarted.ScreenshotHotkey);
            restarted.Onboarded = true;
        }
        // The defaults never replaced the file that could not be read.
        Assert.Equal(ControlP, Preferences.Load(File).ScreenshotHotkey);
        // Once it can be read, it is kept aside and saving works again.
        restarted.PlaySounds = false;
        Assert.Equal(ControlP, Preferences.Load(Path.Combine(folder, "settings.unreadable.json")).ScreenshotHotkey);
        var saved = Preferences.Load(File);
        Assert.True(saved.Onboarded);
        Assert.False(saved.PlaySounds);
    }

    [Theory]
    [InlineData(Key.P, ModifierKeys.None, 0x50u, 0u)]
    [InlineData(Key.P, ModifierKeys.Shift, 0x50u, Native.MOD_SHIFT)]
    [InlineData(Key.D5, ModifierKeys.None, 0x35u, 0u)]
    [InlineData(Key.Space, ModifierKeys.None, 0x20u, 0u)]
    [InlineData(Key.F8, ModifierKeys.None, 0x77u, 0u)]
    [InlineData(Key.P, ModifierKeys.Control, 0x50u, Native.MOD_CONTROL)]
    public void SingleKeysCanBeRecorded(Key key, ModifierKeys modifiers, uint virtualKey, uint flags)
    {
        Assert.Equal(new KeyCombo(virtualKey, flags), KeyCombo.FromKey(key, modifiers));
    }

    [Theory]
    [InlineData(Key.LeftShift, ModifierKeys.Shift)]
    [InlineData(Key.RightCtrl, ModifierKeys.Control)]
    [InlineData(Key.LWin, ModifierKeys.Windows)]
    [InlineData(Key.None, ModifierKeys.None)]
    public void AModifierOnItsOwnIsNotAShortcut(Key key, ModifierKeys modifiers)
    {
        Assert.Null(KeyCombo.FromKey(key, modifiers));
    }

    [Fact]
    public void SingleTypingKeysAreFlagged()
    {
        Assert.True(new KeyCombo(0x50, 0).BlocksTyping);
        Assert.True(new KeyCombo(0x50, Native.MOD_SHIFT).BlocksTyping);
        Assert.True(new KeyCombo(0x20, 0).BlocksTyping);
        Assert.False(ControlP.BlocksTyping);
        Assert.False(KeyCombo.PrintScreen.BlocksTyping);
        Assert.False(KeyCombo.ShiftPrintScreen.BlocksTyping);
        Assert.False(new KeyCombo(0x77, 0).BlocksTyping);
    }
}
