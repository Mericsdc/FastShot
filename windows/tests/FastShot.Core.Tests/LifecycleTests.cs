using System.IO;
using FastShot.Core.Convert;
using Xunit;

namespace FastShot.Core.Tests;

public sealed class LifecycleTests
{
    [Fact]
    public async Task QuitWaitsForRecordingAndRepeatedQuitRequestsShareTheSameWork()
    {
        var saved = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        int stops = 0, exits = 0;
        var coordinator = new FastShot.ShutdownCoordinator(() => { stops++; return saved.Task; }, () => exits++);
        var quit = coordinator.QuitAsync();
        Assert.Same(quit, coordinator.QuitAsync());
        Assert.False(quit.IsCompleted);
        Assert.Equal(1, stops);
        Assert.Equal(0, exits);
        saved.SetResult();
        await quit;
        Assert.Equal(1, exits);
    }

    [Fact]
    public async Task UpdatePreparationWaitsForSaveWithoutExitingBeforeInstallerStarts()
    {
        var saved = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var events = new List<string>();
        var coordinator = new FastShot.ShutdownCoordinator(async () => { await saved.Task; events.Add("saved"); }, () => events.Add("exit"));
        var preparation = coordinator.PrepareAsync();
        Assert.Same(preparation, coordinator.PrepareAsync());
        Assert.Empty(events);
        saved.SetResult();
        await preparation;
        events.Add("installer");
        await coordinator.QuitAsync();
        Assert.Equal(["saved", "installer", "exit"], events);
    }

    [Fact]
    public async Task FailedPreparationDoesNotShutdown()
    {
        int exits = 0;
        var coordinator = new FastShot.ShutdownCoordinator(() => Task.FromException(new IOException("save failed")), () => exits++);
        await Assert.ThrowsAsync<IOException>(() => coordinator.QuitAsync());
        Assert.Equal(0, exits);
    }

    [Fact]
    public async Task FailedInstallerCanResumeAndPrepareAgain()
    {
        int stops = 0, exits = 0;
        var coordinator = new FastShot.ShutdownCoordinator(() => { stops++; return Task.CompletedTask; }, () => exits++);
        await coordinator.PrepareAsync();
        Assert.True(coordinator.ResetPreparation());
        await coordinator.QuitAsync();
        Assert.Equal(2, stops);
        Assert.Equal(1, exits);
        Assert.False(coordinator.ResetPreparation());
    }

    [Fact]
    public void WordTimeoutOnlyTerminatesTheOwnedInstance()
    {
        int owned = 0, unrelated = 0;
        var lifetime = new WordProcessLifetime();
        lifetime.Track(false, () => unrelated++);
        lifetime.Track(true, () => owned++);
        lifetime.Timeout();
        lifetime.Timeout();
        Assert.Equal(1, owned);
        Assert.Equal(0, unrelated);
        Assert.Throws<ConversionException>(lifetime.ThrowIfTimedOut);
    }

    [Fact]
    public void WordActivationAfterTimeoutIsStoppedBeforeOpeningDocuments()
    {
        var lifetime = new WordProcessLifetime();
        int owned = 0, unrelated = 0;
        lifetime.Timeout();
        lifetime.Track(false, () => unrelated++);
        lifetime.Track(true, () => owned++);
        Assert.Equal(1, owned);
        Assert.Equal(0, unrelated);
        Assert.Throws<ConversionException>(lifetime.ThrowIfTimedOut);
    }

    [Fact]
    public void WordCompletedConversionCannotKillAProcessOnLateTimeout()
    {
        int terminated = 0;
        var lifetime = new WordProcessLifetime();
        lifetime.Track(true, () => terminated++);
        lifetime.Complete();
        lifetime.Timeout();
        Assert.Equal(0, terminated);
    }
}
