# Diagrams.ps1 - Draws the flow diagrams in docs\Diagrams.md from their sources.
# Dot-sourced by Update-Diagram.ps1 and the tests.
#
# Each diagram has one source, docs\diagrams\source\<id>.psd1, and both its
# SVG and its numbered list in docs\Diagrams.md are made from it, so the two
# cannot disagree. docs\diagrams\source\Diagrams.psd1 holds the page's
# introduction and the order of the diagrams. build\DiagramCheck.ps1 checks
# the sources against the code (#271).

# The layout, in pixels: inputs on the left, calls down the middle, outputs on the right.
$script:DiagramLayout = @{
    Width       = 1030
    InputX      = 20;  InputWidth  = 255
    CallX       = 335; CallWidth   = 305
    OutputX     = 740; OutputWidth = 270
    SpineX      = 305
    Top         = 34
    RowGap      = 28
    StackGap    = 12
    LineHeight  = 17
    # Characters per line of 11.5 px monospace text in each column.
    CallChars   = 40
    InputChars  = 33
    OutputChars = 35
    # The widest each character of a name (13 px, bold), a stereotype
    # (10 px) and a line (11.5 px) draws, measured with DejaVu Sans Mono,
    # which is wider than Cascadia Mono and Consolas.
    NameGlyph       = 7.85
    StereotypeGlyph = 6.02
    LineGlyph       = 6.93
}

# Calls no diagram has to show: logging, which every step does;
# Invoke-CommandRun, which the page's "How to read them" describes once; and
# Set-ForceConfirmation, which only turns -Force into no confirmation prompt.
$script:DiagramIgnoredCall = @('Write-LogEntry', 'Write-LogError', 'Invoke-CommandRun', 'Set-ForceConfirmation')

function Import-DiagramSet {
    <# The page's index and every diagram source, in the index's order. #>
    param([Parameter(Mandatory)][string]$Root)

    $sourceDir = Join-Path -Path $Root -ChildPath 'docs/diagrams/source'
    $index = Import-PowerShellDataFile -Path (Join-Path -Path $sourceDir -ChildPath 'Diagrams.psd1')
    $diagrams = foreach ($id in @($index.Groups | ForEach-Object { $_.Diagrams })) {
        $path = Join-Path -Path $sourceDir -ChildPath "$id.psd1"
        if (-not (Test-Path -LiteralPath $path)) { throw "Diagrams.psd1 lists '$id', but there is no $path." }
        $diagram = Import-PowerShellDataFile -Path $path
        if ($diagram.Id -ne $id) { throw "$path has Id '$($diagram.Id)'; it must be '$id', its file name." }
        $diagram
    }
    return @{ Root = $Root; Index = $index; Diagrams = @($diagrams) }
}

function Split-DiagramText {
    <# Wraps text at spaces into lines of at most $Width characters; a longer word keeps a line of its own. #>
    [OutputType([string[]])]
    param(
        [AllowEmptyString()][string]$Text,
        [Parameter(Mandatory)][int]$Width
    )

    $line = ''
    foreach ($word in @($Text -split '\s+' | Where-Object { $_ })) {
        if ($line -and ($line.Length + 1 + $word.Length) -gt $Width) {
            $line
            $line = $word
        }
        elseif ($line) { $line = "$line $word" }
        else { $line = $word }
    }
    if ($line) { $line }
}

function Get-DiagramValue {
    <# A key of a source's table, or $Default when the source leaves it out. #>
    param([Parameter(Mandatory)][hashtable]$Table, [Parameter(Mandatory)][string]$Key, $Default = $null)
    if ($Table.ContainsKey($Key)) { return $Table[$Key] }
    return $Default
}

function Format-DiagramCode {
    <# Text as Markdown code: `Name`. #>
    param([Parameter(Mandatory)][string]$Text)
    return '`' + $Text + '`'
}

function Get-DiagramStepName {
    <# How a step's call is named in the list: the function, its arguments, and the function it is paired with. #>
    param([Parameter(Mandatory)][hashtable]$Step)

    $name = $Step.Function
    $arguments = Get-DiagramValue -Table $Step -Key 'Arguments'
    if ($arguments) { $name = "$name $arguments" }
    $names = @(Format-DiagramCode $name) + @(Get-DiagramValue -Table $Step -Key 'Also' -Default @() | ForEach-Object { Format-DiagramCode $_ })
    if ($names.Count -eq 1) { return $names[0] }
    return "$($names[0..($names.Count - 2)] -join ', ') and $($names[-1])"
}

function Get-DiagramStepArea {
    <# The step's area, and what calls it when that is not the command itself. #>
    param([Parameter(Mandatory)][hashtable]$Step)
    $caller = Get-DiagramValue -Table $Step -Key 'Caller'
    if ($caller) { return "$($Step.Area), called by $caller" }
    return $Step.Area
}

function ConvertTo-DiagramMarkdown {
    <# One diagram's section of docs\Diagrams.md: the command, the picture and the same as a numbered list. #>
    [OutputType([string])]
    param([Parameter(Mandatory)][hashtable]$Diagram)

    $out = [System.Collections.Generic.List[string]]::new()
    $out.Add("<a id=""$($Diagram.Id)""></a>")
    $out.Add('')
    $out.Add("## $($Diagram.Title)")
    $out.Add('')
    $out.Add((@($Diagram.Command) + @(Get-DiagramValue -Table $Diagram -Key 'Parameters' -Default @()) | ForEach-Object { Format-DiagramCode $_ }) -join ' ')
    $out.Add('')
    $out.Add($Diagram.Summary)
    $out.Add('')
    $calledBy = Get-DiagramValue -Table $Diagram -Key 'CalledBy'
    if ($calledBy) {
        $notes = @(Get-DiagramValue -Table $calledBy -Key 'Notes' -Default @())
        $suffix = if ($notes.Count) { " ($($notes -join ', '))" } else { '' }
        $out.Add("Called by: $(Format-DiagramCode $calledBy.Name)$suffix.")
        $out.Add('')
    }
    $out.Add("![$($Diagram.Title): call order and data flow](diagrams/$($Diagram.Id).svg)")
    $out.Add('')

    $badge = 0
    $number = 0
    foreach ($step in $Diagram.Steps) {
        $number++
        $out.Add("$number. $(Get-DiagramStepName -Step $step) ($(Get-DiagramStepArea -Step $step)): $($step.Note)")
        $includes = @(Get-DiagramValue -Table $step -Key 'Includes' -Default @())
        if ($includes.Count) {
            $codes = $includes | ForEach-Object { Format-DiagramCode $_ }
            $out.Add("   - Also runs $($codes -join ', ')")
        }
        foreach ($direction in 'Reads', 'Writes') {
            foreach ($data in @(Get-DiagramValue -Table $step -Key $direction -Default @())) {
                $badge++
                $out.Add("   - $direction D$badge, $($data.Label): $($data.Store) ($(@($data.Items) -join ', '))")
            }
        }
    }
    return ($out -join "`n") + "`n"
}

function ConvertTo-DiagramDocument {
    <# The whole of docs\Diagrams.md: the introduction, the contents by group, then each diagram. #>
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][hashtable]$Index,
        [Parameter(Mandatory)][hashtable[]]$Diagrams
    )

    $byId = @{}
    foreach ($diagram in $Diagrams) { $byId[$diagram.Id] = $diagram }

    $out = [System.Collections.Generic.List[string]]::new()
    $out.Add("# $($Index.Title)")
    $out.Add('')
    $out.Add($Index.Intro)
    $out.Add('')
    $out.Add('## How to read them')
    $out.Add('')
    foreach ($point in $Index.HowToRead) { $out.Add("- $point") }
    $out.Add('')
    $out.Add('## Contents')
    $out.Add('')
    foreach ($group in $Index.Groups) {
        $links = $group.Diagrams | ForEach-Object { "[$($byId[$_].Title)](#$_)" }
        $out.Add("- $($group.Name): $($links -join ', ')")
    }
    $out.Add('')
    foreach ($group in $Index.Groups) {
        foreach ($id in $group.Diagrams) { $out.Add((ConvertTo-DiagramMarkdown -Diagram $byId[$id])) }
    }
    $out.Add('---')
    $out.Add('')
    $out.Add($Index.Footer)
    return ($out -join "`n") + "`n"
}

function ConvertTo-SvgText {
    <# Text made safe to put inside SVG. #>
    param([AllowEmptyString()][string]$Text)
    return [System.Security.SecurityElement]::Escape($Text)
}

function Get-DiagramBoxHeight {
    <# A box's height for its lines of text; every box has room for at least two. #>
    param([int]$LineCount)
    return 50 + $script:DiagramLayout.LineHeight * [math]::Max($LineCount, 2)
}

function Get-DiagramCommandText {
    <# The command's box: its name and each parameter. #>
    param([Parameter(Mandatory)][hashtable]$Diagram)
    $l = $script:DiagramLayout
    return @{
        Stereotype = 'command'; Name = $Diagram.Command; Width = $l.CallWidth; Numbered = $false
        Lines      = @(foreach ($parameter in @(Get-DiagramValue -Table $Diagram -Key 'Parameters' -Default @())) { Split-DiagramText -Text $parameter -Width $l.CallChars })
    }
}

function Get-DiagramCallerText {
    <# The box for what calls the command, such as its scheduled task. #>
    param([Parameter(Mandatory)][hashtable]$CalledBy)
    return @{
        Stereotype = $CalledBy.Kind; Name = $CalledBy.Name; Width = $script:DiagramLayout.InputWidth; Numbered = $false
        Lines      = @(Get-DiagramValue -Table $CalledBy -Key 'Notes' -Default @())
    }
}

function Get-DiagramStepText {
    <#
      A call's box: its area as the stereotype, the function as its name,
      then what calls it, the functions paired with it and its note. The
      caller has a line of its own, clear of the step number.
    #>
    param([Parameter(Mandatory)][hashtable]$Step)
    $l = $script:DiagramLayout
    $name = if (Get-DiagramValue -Table $Step -Key 'Arguments') { "$($Step.Function) $($Step.Arguments)" } else { "$($Step.Function)()" }
    $caller = Get-DiagramValue -Table $Step -Key 'Caller'
    $callerLine = @(if ($caller) { "called by $caller" })
    $alsoLines = @(@(Get-DiagramValue -Table $Step -Key 'Also' -Default @()) | ForEach-Object { "and $_()" })
    $lines = $callerLine + $alsoLines + @(Split-DiagramText -Text $Step.Note -Width $l.CallChars)
    return @{ Stereotype = $Step.Area; Name = $name; Width = $l.CallWidth; Numbered = $true; Lines = $lines }
}

function Get-DiagramDataText {
    <# A data box: its kind, where the data is, and each item wrapped to the column. #>
    param([Parameter(Mandatory)][hashtable]$Data, [Parameter(Mandatory)][ValidateSet('Reads', 'Writes')][string]$Direction)
    $l = $script:DiagramLayout
    $width, $chars = if ($Direction -eq 'Reads') { $l.InputWidth, $l.InputChars } else { $l.OutputWidth, $l.OutputChars }
    return @{
        Stereotype = $Data.Kind; Name = $Data.Store; Width = $width; Numbered = $false
        Lines      = @(foreach ($item in @($Data.Items)) { Split-DiagramText -Text $item -Width $chars })
    }
}

function Get-DiagramTextSpace {
    <# The room, in pixels, a box's name and stereotype have, and the room its lines have. #>
    param([Parameter(Mandatory)][hashtable]$Text)
    $title = if ($Text.Numbered) { $Text.Width - 38 } else { $Text.Width - 12 }
    return @{ Title = $title; Line = $Text.Width - 14 }
}

function New-DiagramBox {
    <#
      One box: a stereotype, a name, a divider and its lines of text. $Height
      stretches it to the row, so arrows into it always land on it. A
      numbered box centres its name to the right of the number.
    #>
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Class,
        [Parameter(Mandatory)][hashtable]$Text,
        [Parameter(Mandatory)][double]$X,
        [Parameter(Mandatory)][double]$Y,
        [Parameter(Mandatory)][double]$Height,
        [int]$Number = 0
    )

    $width = $Text.Width
    $centre = if ($Number -gt 0) { $X + 32 + ($width - 38) / 2 } else { $X + $width / 2 }
    $svg = [System.Text.StringBuilder]::new()
    $null = $svg.AppendLine("<g class=""$Class""><rect x=""$X"" y=""$Y"" width=""$width"" height=""$Height"" rx=""3""/>")
    $null = $svg.AppendLine("<text class=""st"" x=""$centre"" y=""$($Y + 14)"" text-anchor=""middle"">«$(ConvertTo-SvgText $Text.Stereotype)»</text>")
    $null = $svg.AppendLine("<text class=""nm"" x=""$centre"" y=""$($Y + 30)"" text-anchor=""middle"">$(ConvertTo-SvgText $Text.Name)</text>")
    $null = $svg.AppendLine("<line class=""div"" x1=""$X"" y1=""$($Y + 37)"" x2=""$($X + $width)"" y2=""$($Y + 37)""/>")
    if ($Number -gt 0) {
        $null = $svg.AppendLine("<g class=""sn""><circle cx=""$($X + 16)"" cy=""$($Y + 21)"" r=""10""/><text x=""$($X + 16)"" y=""$($Y + 25)"" text-anchor=""middle"">$Number</text></g>")
    }
    $lineY = $Y + 52
    foreach ($line in $Text.Lines) {
        $null = $svg.AppendLine("<text class=""at"" x=""$($X + 10)"" y=""$lineY"">$(ConvertTo-SvgText $line)</text>")
        $lineY += $script:DiagramLayout.LineHeight
    }
    $null = $svg.Append('</g>')
    return $svg.ToString()
}

function ConvertTo-DiagramSvg {
    <#
      One diagram as SVG: the command at the top, each call below it in
      order, the data each reads on its left and writes on its right. It
      follows the viewer's light or dark theme.
    #>
    [OutputType([string])]
    param([Parameter(Mandatory)][hashtable]$Diagram)

    $l = $script:DiagramLayout
    $boxes = [System.Collections.Generic.List[string]]::new()
    $arrows = [System.Collections.Generic.List[string]]::new()
    $badges = [System.Collections.Generic.List[string]]::new()

    # The command, and what calls it beside it on the left.
    $command = Get-DiagramCommandText -Diagram $Diagram
    $commandHeight = Get-DiagramBoxHeight -LineCount $command.Lines.Count
    $calledBy = Get-DiagramValue -Table $Diagram -Key 'CalledBy'
    if ($calledBy) {
        $caller = Get-DiagramCallerText -CalledBy $calledBy
        $commandHeight = [math]::Max($commandHeight, (Get-DiagramBoxHeight -LineCount $caller.Lines.Count))
        $boxes.Add((New-DiagramBox -Class 'bx-caller' -Text $caller -X $l.InputX -Y $l.Top -Height $commandHeight))
        $arrows.Add("<path class=""cl"" d=""M$($l.InputX + $l.InputWidth),$($l.Top + 24) L$($l.CallX),$($l.Top + 24)"" marker-end=""url(#ac)""/>")
    }
    $boxes.Add((New-DiagramBox -Class 'bx-cmd' -Text $command -X $l.CallX -Y $l.Top -Height $commandHeight))

    $y = $l.Top + $commandHeight + $l.RowGap
    $spineTop = $l.Top + [math]::Min(42, $commandHeight / 2)
    $spineBottom = $spineTop
    $badge = 0
    $number = 0
    foreach ($step in $Diagram.Steps) {
        $number++
        $call = Get-DiagramStepText -Step $step

        # Stack the data on each side, then size the row to the tallest column.
        $columns = @{}
        foreach ($side in @(@{ Key = 'Reads'; X = $l.InputX }, @{ Key = 'Writes'; X = $l.OutputX })) {
            $stackY = $y
            $placed = foreach ($data in @(Get-DiagramValue -Table $step -Key $side.Key -Default @())) {
                $text = Get-DiagramDataText -Data $data -Direction $side.Key
                $height = Get-DiagramBoxHeight -LineCount $text.Lines.Count
                @{ Text = $text; X = $side.X; Y = $stackY; Height = $height }
                $stackY += $height + $l.StackGap
            }
            $columns[$side.Key] = @{ Boxes = @($placed); Height = [math]::Max(0, $stackY - $y - $l.StackGap) }
        }
        $rowHeight = [math]::Max((Get-DiagramBoxHeight -LineCount $call.Lines.Count), [math]::Max($columns.Reads.Height, $columns.Writes.Height))

        $boxes.Add((New-DiagramBox -Class 'bx-mod' -Text $call -X $l.CallX -Y $y -Height $rowHeight -Number $number))
        $branchY = $y + 20
        $arrows.Add("<path class=""cl"" d=""M$($l.SpineX),$branchY L$($l.CallX),$branchY"" marker-end=""url(#ac)""/>")
        $spineBottom = $branchY

        foreach ($key in 'Reads', 'Writes') {
            foreach ($box in $columns[$key].Boxes) {
                $badge++
                $middle = $box.Y + $box.Height / 2
                if ($key -eq 'Reads') {
                    $from = $l.InputX + $l.InputWidth; $to = $l.CallX; $badgeX = $from + 18
                }
                else {
                    $from = $l.CallX + $l.CallWidth; $to = $l.OutputX; $badgeX = ($from + $to) / 2
                }
                $arrows.Add("<path class=""df"" d=""M$from,$middle L$to,$middle"" marker-end=""url(#ad)""/>")
                $badges.Add("<g class=""bd""><circle cx=""$badgeX"" cy=""$middle"" r=""10""/><text x=""$badgeX"" y=""$($middle + 3.5)"" text-anchor=""middle"">D$badge</text></g>")
                $boxes.Add((New-DiagramBox -Class 'bx-store' -Text $box.Text -X $box.X -Y $box.Y -Height $box.Height))
            }
        }
        $y += $rowHeight + $l.RowGap
    }
    if ($number -gt 0) {
        $arrows.Insert(0, "<path class=""cl"" d=""M$($l.CallX),$spineTop L$($l.SpineX),$spineTop L$($l.SpineX),$spineBottom""/>")
    }

    $height = $y - $l.RowGap + 30
    $title = "$(ConvertTo-SvgText $Diagram.Title): calls in order, with data flowing in from the left and out to the right"
    $svg = [System.Collections.Generic.List[string]]::new()
    $svg.Add("<svg xmlns=""http://www.w3.org/2000/svg"" viewBox=""0 0 $($l.Width) $height"" width=""$($l.Width)"" height=""$height"" role=""img"" aria-labelledby=""t-$($Diagram.Id)"">")
    $svg.Add("<title id=""t-$($Diagram.Id)"">$title</title>")
    $svg.Add(@'
<style>
svg{--bg:#ffffff;--fg:#17202a;--muted:#52606d;--line:#9aa5b1;--mod:#eef2f6;--store:#fbf6ea;--cmd:#e9eef9;--call:#1f5fbf;--data:#b86e00;--on:#ffffff}
@media (prefers-color-scheme: dark){svg{--bg:#0d1117;--fg:#e6edf3;--muted:#9da7b3;--line:#5d6b78;--mod:#1d2733;--store:#2a2418;--cmd:#1b2537;--call:#6ea2ff;--data:#f2a93b;--on:#0d1117}}
text{font-family:ui-monospace,"Cascadia Mono",Consolas,Menlo,monospace;fill:var(--fg)}
.bg{fill:var(--bg)}
.cap{font:600 11px system-ui,"Segoe UI",sans-serif;letter-spacing:.12em;fill:var(--muted)}
.bx-cmd rect{fill:var(--cmd);stroke:var(--fg);stroke-width:1.6}
.bx-caller rect{fill:var(--cmd);stroke:var(--call);stroke-width:1.2;stroke-dasharray:3 3}
.bx-mod rect{fill:var(--mod);stroke:var(--line);stroke-width:1.2}
.bx-store rect{fill:var(--store);stroke:var(--data);stroke-width:1.2;stroke-dasharray:6 3}
.st{font-size:10px;fill:var(--muted)}
.nm{font-size:13px;font-weight:600}
.div{stroke:var(--line)}
.at{font-size:11.5px;fill:var(--muted)}
.cl{fill:none;stroke:var(--call);stroke-width:2}
.df{fill:none;stroke:var(--data);stroke-width:2;stroke-dasharray:7 4}
.sn circle{fill:var(--call)} .sn text{font:600 10px system-ui,sans-serif;fill:var(--on)}
.bd circle{fill:var(--data)} .bd text{font:600 9px system-ui,sans-serif;fill:var(--on)}
.mk-c{fill:var(--call)} .mk-d{fill:var(--data)}
</style>
<defs>
<marker id="ac" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" markerHeight="7" orient="auto-start-reverse"><path class="mk-c" d="M0,0 L10,5 L0,10 z"/></marker>
<marker id="ad" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" markerHeight="7" orient="auto-start-reverse"><path class="mk-d" d="M0,0 L10,5 L0,10 z"/></marker>
</defs>
'@.TrimEnd())
    $svg.Add("<rect class=""bg"" x=""0"" y=""0"" width=""$($l.Width)"" height=""$height""/>")
    $svg.Add("<text class=""cap"" x=""$($l.InputX)"" y=""16"">INPUTS</text>")
    $svg.Add("<text class=""cap"" x=""$($l.CallX)"" y=""16"">CALLS IN ORDER</text>")
    $svg.Add("<text class=""cap"" x=""$($l.OutputX)"" y=""16"">OUTPUTS</text>")
    $svg.AddRange($arrows)
    $svg.AddRange($badges)
    $svg.AddRange($boxes)
    $svg.Add('</svg>')
    return ($svg -join "`n") + "`n"
}

function Get-DiagramOutput {
    <# Every file the sources make, by path from the repository root: docs\Diagrams.md and one SVG per diagram. #>
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param([Parameter(Mandatory)][hashtable]$Set)

    $output = [ordered]@{ 'docs/Diagrams.md' = ConvertTo-DiagramDocument -Index $Set.Index -Diagrams $Set.Diagrams }
    foreach ($diagram in $Set.Diagrams) {
        $output["docs/diagrams/$($diagram.Id).svg"] = ConvertTo-DiagramSvg -Diagram $diagram
    }
    return $output
}

function Update-Diagram {
    <# Writes docs\Diagrams.md and every SVG from the sources, with LF line endings and no BOM. #>
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string]$Root)

    $output = Get-DiagramOutput -Set (Import-DiagramSet -Root $Root)
    foreach ($path in $output.Keys) {
        $fullPath = Join-Path -Path $Root -ChildPath $path
        if ($PSCmdlet.ShouldProcess($fullPath, 'Write')) {
            [System.IO.File]::WriteAllText($fullPath, $output[$path], [System.Text.UTF8Encoding]::new($false))
        }
    }
}
