using LazyVM.UI.Wpf.ViewModels;

namespace LazyVM.UI.Wpf.Tests;

public sealed class VMRowViewModelTests : IDisposable
{
    private readonly CultureScope culture = new("en-GB");

    public void Dispose() => culture.Dispose();

    [Fact]
    public void HealthyVM_DoesNotNeedAttention()
    {
        var row = new VMRowViewModel(Sample.VM());

        Assert.False(row.NeedsAttention);
        Assert.Null(row.AttentionText);
    }

    [Fact]
    public void FailedMaintenance_NeedsAttention()
    {
        var row = new VMRowViewModel(Sample.VM() with { LastMaintenanceResult = "Failed (0x1)" });

        Assert.True(row.NeedsAttention);
        Assert.Equal("Needs attention: last maintenance failed", row.AttentionText);
    }

    [Fact]
    public void SettingsProblem_NeedsAttention()
    {
        var row = new VMRowViewModel(Sample.VM() with { Settings = "VM.json is not valid JSON." });

        Assert.True(row.NeedsAttention);
        Assert.Equal("Needs attention: settings problem", row.AttentionText);
    }

    [Fact]
    public void FailedMaintenanceAndSettingsProblem_NamesBoth()
    {
        var row = new VMRowViewModel(Sample.VM() with { LastMaintenanceResult = "Failed (0x1)", Settings = "Bad." });

        Assert.Equal("Needs attention: last maintenance failed, settings problem", row.AttentionText);
    }

    [Theory]
    [InlineData(0, "None")]
    [InlineData(1, "1 open finding")]
    [InlineData(3, "3 open findings")]
    [InlineData(null, "Not scanned yet")]
    public void OpenFindings_ReadsAsWords(int? count, string expected)
    {
        var row = new VMRowViewModel(Sample.VM() with { OpenFindings = count });

        Assert.Equal(expected, row.OpenFindingsText);
    }

    [Fact]
    public void LastMaintenance_GivesResultAndDay()
    {
        var row = new VMRowViewModel(Sample.VM());

        Assert.Equal("Succeeded, 12 November", row.LastMaintenanceText);
    }

    [Fact]
    public void LastMaintenance_NotRunYet()
    {
        var row = new VMRowViewModel(Sample.VM() with { LastMaintenance = null, LastMaintenanceResult = "Not run yet" });

        Assert.Equal("Not run yet", row.LastMaintenanceText);
    }

    [Fact]
    public void LastMaintenance_WithoutATask()
    {
        var row = new VMRowViewModel(Sample.VM() with
        {
            MaintenanceTask = "Not registered",
            LastMaintenance = null,
            LastMaintenanceResult = null,
        });

        Assert.Equal("No maintenance task", row.LastMaintenanceText);
    }

    [Fact]
    public void Row_ReadsAsOneSentence()
    {
        var row = new VMRowViewModel(Sample.VM() with { OpenFindings = 2 });

        Assert.Equal("DevBox, Running, last maintenance succeeded 12 November, 2 open findings", row.AutomationName);
    }

    [Fact]
    public void Row_Sentence_IncludesWhatNeedsAttention()
    {
        var row = new VMRowViewModel(Sample.VM("TestBox", "Off") with
        {
            LastMaintenance = new DateTime(2026, 11, 12, 2, 10, 0),
            LastMaintenanceResult = "Failed (0x1)",
        });

        Assert.Equal(
            "TestBox, Off, needs attention: last maintenance failed, last maintenance failed (0x1) 12 November, no open findings",
            row.AutomationName);
    }

    [Fact]
    public void WhatCouldNotBeRead_ShowsOnThatRowOnly()
    {
        var broken = new VMRowViewModel(Sample.VM("DevBox") with { Problems = ["Disks: access denied"] });
        var fine = new VMRowViewModel(Sample.VM("TestBox"));

        Assert.Equal("Could not read: Disks: access denied", broken.ProblemText);
        Assert.EndsWith(", could not read: Disks: access denied", broken.AutomationName);
        Assert.Null(fine.ProblemText);
    }

    [Fact]
    public void Update_TellsTheViewEverythingChanged()
    {
        var row = new VMRowViewModel(Sample.VM());
        var changed = new List<string?>();
        row.PropertyChanged += (_, e) => changed.Add(e.PropertyName);

        row.Update(Sample.VM(state: "Off"));

        Assert.Equal("Off", row.State);
        Assert.Contains(changed, name => string.IsNullOrEmpty(name));
    }
}
