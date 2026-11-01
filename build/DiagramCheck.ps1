# DiagramCheck.ps1 - Checks the diagram sources against the code, so the
# diagrams cannot drift from it unnoticed (#271). Dot-sourced by the tests,
# after build\Diagrams.ps1.

function Get-CodeFunctionIndex {
    <# Every function defined in the .ps1 files under $Path, by name, with its definition. #>
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][string[]]$Path)

    $index = @{}
    foreach ($file in @(Get-ChildItem -Path $Path -Filter '*.ps1' -Recurse -File)) {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$null, [ref]$null)
        foreach ($definition in $ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
            $index[$definition.Name] = $definition
        }
    }
    return $index
}

function Get-DiagramFunctionName {
    <#
      Every function of the code's own a diagram names: the command and each
      step's functions and callers. A step marked External runs something
      that is not LazyVM's, such as a Hyper-V cmdlet or a script, so only
      what it Includes and its caller are named; a diagram marked External
      has a script, not a function, as its command.
    #>
    [OutputType([string[]])]
    param([Parameter(Mandatory)][hashtable]$Diagram)

    $names = [System.Collections.Generic.List[string]]::new()
    if (-not (Get-DiagramValue -Table $Diagram -Key 'External' -Default $false)) { $names.Add($Diagram.Command) }
    foreach ($step in $Diagram.Steps) {
        if (-not (Get-DiagramValue -Table $step -Key 'External' -Default $false)) { $names.Add($step.Function) }
        foreach ($key in 'Also', 'Includes') {
            foreach ($name in @(Get-DiagramValue -Table $step -Key $key -Default @())) { $names.Add($name) }
        }
        $caller = Get-DiagramValue -Table $step -Key 'Caller'
        if ($caller) { $names.Add($caller) }
    }
    return @($names | Select-Object -Unique)
}

function Get-DiagramUnknownFunction {
    <# The functions a diagram names that the code does not define. #>
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)][hashtable]$Diagram,
        [Parameter(Mandatory)][hashtable]$FunctionIndex
    )
    return @(Get-DiagramFunctionName -Diagram $Diagram | Where-Object { -not $FunctionIndex.ContainsKey($_) })
}

function Get-DiagramCoverageGap {
    <#
      The calls the functions a diagram Covers make to the code's own
      functions that the diagram neither shows nor lists in Omits, each as
      "<covered> calls <function>". Logging is never expected.
    #>
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)][hashtable]$Diagram,
        [Parameter(Mandatory)][hashtable]$FunctionIndex
    )

    $shown = @(Get-DiagramFunctionName -Diagram $Diagram) + @((Get-DiagramValue -Table $Diagram -Key 'Omits' -Default @{}).Keys) + $script:DiagramIgnoredCall
    $gaps = foreach ($covered in @(Get-DiagramValue -Table $Diagram -Key 'Covers' -Default @())) {
        if (-not $FunctionIndex.ContainsKey($covered)) {
            "$covered does not exist"
            continue
        }
        $calls = $FunctionIndex[$covered].Body.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] }, $true) |
            ForEach-Object { $_.GetCommandName() } |
            Where-Object { $_ -and $_ -ne $covered -and $FunctionIndex.ContainsKey($_) -and $_ -notin $shown } |
            Select-Object -Unique
        foreach ($call in $calls) { "$covered calls $call" }
    }
    return @($gaps)
}

function Test-DiagramSource {
    <# What a source is missing, as text; nothing when it is complete. #>
    [OutputType([string[]])]
    param([Parameter(Mandatory)][hashtable]$Diagram)

    $id = Get-DiagramValue -Table $Diagram -Key 'Id' -Default '(no Id)'
    $problems = foreach ($key in 'Id', 'Title', 'Command', 'Summary', 'Steps') {
        if (-not (Get-DiagramValue -Table $Diagram -Key $key)) { "${id}: no $key" }
    }
    $stepProblems = Get-DiagramStepProblem -Diagram $Diagram -Id $id
    return @($problems) + @($stepProblems)
}

function Get-DiagramStepProblem {
    <# What each step of a source, and each piece of data in it, is missing. #>
    [OutputType([string[]])]
    param([Parameter(Mandatory)][hashtable]$Diagram, [Parameter(Mandatory)][string]$Id)

    $number = 0
    foreach ($step in @(Get-DiagramValue -Table $Diagram -Key 'Steps' -Default @())) {
        $number++
        foreach ($key in 'Function', 'Area', 'Note') {
            if (-not (Get-DiagramValue -Table $step -Key $key)) { "$id step ${number}: no $key" }
        }
        foreach ($direction in 'Reads', 'Writes') {
            foreach ($data in @(Get-DiagramValue -Table $step -Key $direction -Default @())) {
                foreach ($key in 'Label', 'Kind', 'Store', 'Items') {
                    if (-not (Get-DiagramValue -Table $data -Key $key)) { "$id step $number ${direction}: no $key" }
                }
            }
        }
    }
}

function Get-DiagramOverflow {
    <#
      Text that would not fit its box in the SVG: a name or stereotype too
      long for its box, or a word in a line too long to wrap. Measured with
      the widest glyphs, so what fits here fits on Windows too.
    #>
    [OutputType([string[]])]
    param([Parameter(Mandatory)][hashtable]$Diagram)

    $l = $script:DiagramLayout
    $boxes = [System.Collections.Generic.List[object]]::new()
    $boxes.Add(@{ Where = $Diagram.Id; Text = Get-DiagramCommandText -Diagram $Diagram })
    $calledBy = Get-DiagramValue -Table $Diagram -Key 'CalledBy'
    if ($calledBy) { $boxes.Add(@{ Where = $Diagram.Id; Text = Get-DiagramCallerText -CalledBy $calledBy }) }
    $number = 0
    foreach ($step in $Diagram.Steps) {
        $number++
        $where = "$($Diagram.Id) step $number"
        $boxes.Add(@{ Where = $where; Text = Get-DiagramStepText -Step $step })
        foreach ($direction in 'Reads', 'Writes') {
            foreach ($data in @(Get-DiagramValue -Table $step -Key $direction -Default @())) {
                $boxes.Add(@{ Where = $where; Text = Get-DiagramDataText -Data $data -Direction $direction })
            }
        }
    }

    $overflow = foreach ($box in $boxes) {
        $space = Get-DiagramTextSpace -Text $box.Text
        $tooWide = @(
            if ($box.Text.Name.Length * $l.NameGlyph -gt $space.Title) { $box.Text.Name }
            if (("«$($box.Text.Stereotype)»").Length * $l.StereotypeGlyph -gt $space.Title) { "«$($box.Text.Stereotype)»" }
            $box.Text.Lines | Where-Object { $_.Length * $l.LineGlyph -gt $space.Line }
        )
        foreach ($text in $tooWide) { "$($box.Where): ""$text"" does not fit its box" }
    }
    return @($overflow)
}

function Get-DiagramStaleFile {
    <# The outputs, by path from $Root, whose file is missing or differs from what the sources make, line endings aside. #>
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Output
    )

    $stale = foreach ($path in $Output.Keys) {
        $fullPath = Join-Path -Path $Root -ChildPath $path
        if (-not (Test-Path -LiteralPath $fullPath)) {
            $path
            continue
        }
        $current = [System.IO.File]::ReadAllText($fullPath) -replace "`r`n", "`n"
        if ($current -ne ($Output[$path] -replace "`r`n", "`n")) { $path }
    }
    return @($stale)
}
