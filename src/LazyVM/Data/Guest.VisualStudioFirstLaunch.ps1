# Guest.VisualStudioFirstLaunch.ps1 - Visual Studio's first launch, with Windows UI Automation (#268).
#
# Runs in the GUEST, under Windows PowerShell 5.1, in the signed-in user's
# desktop session: no PowerShell 7 syntax. The build copies it to
# <GuestSetupDir>\VisualStudioFirstLaunch.ps1 (C:\LazyVMSetup by default).
#
# The build (Complete-GuestVisualStudioFirstLaunch) runs it with -DevenvPath,
# -Control, -TimeoutMinutes and -ProcessIdPath: it starts Visual Studio with
# /Command Exit, records its process id in -ProcessIdPath, presses each
# control in -Control in order, found by its AutomationId, and waits for
# Visual Studio to finish starting and close itself. Whatever goes wrong, it
# describes the windows Visual Studio had open in -TreePath, stops Visual
# Studio and everything it started, and throws saying why. It removes
# -ProcessIdPath once Visual Studio has stopped, so a file left behind names
# a devenv the host is to stop.
#
# Each -Control item is @{ Name; AutomationId }: AutomationId finds the
# control, Name is only for messages.
#
# By hand, to see the AutomationIds of the first-launch window: open Visual
# Studio in the VM and, while a first-launch screen shows, run in Windows
# PowerShell:
#
#   powershell.exe -ExecutionPolicy Bypass -File C:\LazyVMSetup\VisualStudioFirstLaunch.ps1 -TreePath "$env:USERPROFILE\Desktop\VSFirstLaunch.txt"
#
# It adds every Visual Studio window's tree (ControlType, Name, AutomationId,
# ClassName of each element) to that file and changes nothing. Run it again
# on each screen.

[CmdletBinding(DefaultParameterSetName = 'Tree')]
param(
    [Parameter(Mandatory)][string]$TreePath,
    [Parameter(Mandatory, ParameterSetName = 'FirstLaunch')][string]$DevenvPath,
    [Parameter(Mandatory, ParameterSetName = 'FirstLaunch')][object[]]$Control,
    [Parameter(Mandatory, ParameterSetName = 'FirstLaunch')][ValidateRange(1, [int]::MaxValue)][int]$TimeoutMinutes,
    [Parameter(Mandatory, ParameterSetName = 'FirstLaunch')][string]$ProcessIdPath
)

$ErrorActionPreference = 'Stop'
# How long a description of the windows may take, so a failed first launch
# still stops Visual Studio well inside the time the host gives the task.
$treeSeconds = 60
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes

function Get-DevenvWindow {
    <# The top-level windows of the devenv processes with these ids. #>
    param([int[]]$ProcessId = @())

    $root = [System.Windows.Automation.AutomationElement]::RootElement
    foreach ($id in $ProcessId) {
        $condition = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ProcessIdProperty, $id)
        foreach ($window in $root.FindAll([System.Windows.Automation.TreeScope]::Children, $condition)) { $window }
    }
}

function Write-AutomationTree {
    <#
      Adds to $Path, under $Heading, the UI Automation tree of each of
      $Window: one line per element, indented by its depth. Cut short after
      $treeSeconds seconds, and says so.
    #>
    param(
        [object[]]$Window = @(),
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Heading
    )

    $walker = [System.Windows.Automation.TreeWalker]::RawViewWalker
    $clock = [System.Diagnostics.Stopwatch]::StartNew()
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("=== $(Get-Date -Format s) $Heading")
    if (@($Window).Count -eq 0) { $lines.Add('(Visual Studio has no window open)') }

    $pending = New-Object System.Collections.Generic.Stack[object]
    foreach ($window in @($Window)) { $pending.Push(@($window, 0)) }
    while ($pending.Count -gt 0) {
        if ($clock.Elapsed.TotalSeconds -ge $treeSeconds) {
            $lines.Add("(dump cut short after $treeSeconds seconds)")
            break
        }
        $element, $depth = $pending.Pop()
        try {
            $current = $element.Current
            $lines.Add(('{0}{1} | Name="{2}" | AutomationId="{3}" | ClassName="{4}"' -f ('  ' * $depth), $current.ControlType.ProgrammaticName, $current.Name, $current.AutomationId, $current.ClassName))
            # Pushed last child first, so they come off the stack in order.
            $children = @()
            $child = $walker.GetFirstChild($element)
            while ($child) { $children += $child; $child = $walker.GetNextSibling($child) }
            for ($i = $children.Count - 1; $i -ge 0; $i--) { $pending.Push(@($children[$i], ($depth + 1))) }
        }
        catch { $lines.Add("$('  ' * $depth)(element gone: $($_.Exception.Message))") }
    }
    Add-Content -LiteralPath $Path -Value $lines -Encoding UTF8
}

function Wait-AutomationElement {
    <#
      The element of $Control (an item of -Control) in a window of devenv
      $Process, once it shows. Throws when devenv exits first or $Deadline
      passes.
    #>
    param(
        [Parameter(Mandatory)][System.Diagnostics.Process]$Process,
        [Parameter(Mandatory)][object]$Control,
        [Parameter(Mandatory)][datetime]$Deadline
    )

    $name = $Control.Name
    $automationId = $Control.AutomationId
    $condition = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::AutomationIdProperty, $automationId)
    while ((Get-Date) -lt $Deadline) {
        if ($Process.HasExited) { throw "Visual Studio exited (code $($Process.ExitCode)) before showing '$name' (AutomationId $automationId)" }
        foreach ($window in @(Get-DevenvWindow -ProcessId $Process.Id)) {
            $element = $window.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $condition)
            if ($element) { return $element }
        }
        Start-Sleep -Seconds 2
    }
    throw "Visual Studio did not show '$name' (AutomationId $automationId) by $($Deadline.ToString('T'))"
}

function Invoke-AutomationElement {
    <# Presses $Element, the button or link of $Control (an item of -Control), with its Invoke pattern. #>
    param(
        [Parameter(Mandatory)][object]$Element,
        [Parameter(Mandatory)][object]$Control
    )

    $pattern = $null
    if (-not $Element.TryGetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern, [ref]$pattern)) {
        throw "'$($Control.Name)' (AutomationId $($Control.AutomationId)) cannot be pressed: it has no Invoke pattern"
    }
    $pattern.Invoke()
}

if ($PSCmdlet.ParameterSetName -eq 'Tree') {
    $ids = @(Get-Process -Name devenv -ErrorAction SilentlyContinue | ForEach-Object { $_.Id })
    Write-AutomationTree -Window @(Get-DevenvWindow -ProcessId $ids) -Path $TreePath -Heading 'Visual Studio windows'
    return
}

Remove-Item -LiteralPath $TreePath -Force -ErrorAction SilentlyContinue
$deadline = (Get-Date).AddMinutes($TimeoutMinutes)
$process = Start-Process -FilePath $DevenvPath -ArgumentList '/NoSplash', '/Command', 'Exit' -PassThru
try {
    Set-Content -LiteralPath $ProcessIdPath -Value $process.Id
    foreach ($step in $Control) {
        $element = Wait-AutomationElement -Process $process -Control $step -Deadline $deadline
        Invoke-AutomationElement -Element $element -Control $step
    }
    $remaining = [int][Math]::Max(0, ($deadline - (Get-Date)).TotalMilliseconds)
    if (-not $process.WaitForExit($remaining)) { throw "Visual Studio did not close itself within $TimeoutMinutes minute(s) of starting" }
}
catch {
    $reason = $_.Exception.Message
    try {
        Write-AutomationTree -Window @(Get-DevenvWindow -ProcessId $process.Id) -Path $TreePath -Heading $reason
        $reason += ". The windows Visual Studio had open are described in $TreePath"
    }
    catch { $reason += ". Its windows could not be described: $($_.Exception.Message)" }
    throw $reason
}
finally {
    if (-not $process.HasExited) { $null = taskkill.exe /PID $process.Id /T /F }
    Remove-Item -LiteralPath $ProcessIdPath -Force -ErrorAction SilentlyContinue
}
