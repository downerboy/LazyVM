# Diagrams.Tests.ps1
# The flow diagrams in docs\Diagrams.md: how build\Diagrams.ps1 draws them
# from docs\diagrams\source, and the checks in build\DiagramCheck.ps1 that
# keep them in step with the code (#271).

BeforeAll {
    # Update-Diagram.ps1 runs these under strict mode, so the tests do too.
    Set-StrictMode -Version 3.0
    $script:repoRoot = Split-Path -Path $PSScriptRoot -Parent
    . (Join-Path -Path $script:repoRoot -ChildPath 'build/Diagrams.ps1')
    . (Join-Path -Path $script:repoRoot -ChildPath 'build/DiagramCheck.ps1')

    function New-TestDiagram {
        @{
            Id         = 'sample'
            Title      = 'See a sample'
            Command    = 'Get-Sample'
            Parameters = @('-Name <VM>', '-Raw  (optional)')
            Summary    = 'Returns a sample & more.'
            Steps      = @(
                @{
                    Function = 'Read-Thing'; Area = 'Settings'; Note = 'finds the thing'
                    Reads    = @(@{ Label = 'settings'; Kind = 'file'; Store = 'Settings files'; Items = @('Shared\a.json', '<VM>\b.json') })
                }
                @{
                    Function = 'Write-Thing'; Area = 'Common'; Caller = 'Read-Thing'; Note = 'writes it'; Includes = @('Format-Thing', 'Test-Thing')
                    Reads    = @(@{ Label = 'key'; Kind = 'file'; Store = 'Key'; Items = @('k') })
                    Writes   = @(@{ Label = 'result'; Kind = 'output'; Store = 'Pipeline'; Items = @('text') })
                }
            )
        }
    }
}

Describe 'Split-DiagramText' {
    It 'wraps at word boundaries within the width' {
        Split-DiagramText -Text 'one two three four' -Width 9 | Should -Be @('one two', 'three', 'four')
    }

    It 'keeps a word longer than the width whole, on its own line' {
        Split-DiagramText -Text 'a Initialize-SqlServerIso b' -Width 10 | Should -Be @('a', 'Initialize-SqlServerIso', 'b')
    }

    It 'returns nothing for empty text' {
        @(Split-DiagramText -Text '' -Width 10).Count | Should -Be 0
    }
}

Describe 'ConvertTo-DiagramMarkdown' {
    BeforeAll {
        $script:markdown = ConvertTo-DiagramMarkdown -Diagram (New-TestDiagram)
        $script:lines = $script:markdown -split "`n"
    }

    It 'starts with the anchor the contents link to, then the title' {
        $script:lines[0] | Should -Be '<a id="sample"></a>'
        $script:lines | Should -Contain '## See a sample'
    }

    It 'shows the command with each parameter' {
        $script:lines | Should -Contain '`Get-Sample` `-Name <VM>` `-Raw  (optional)`'
    }

    It 'links the diagram''s SVG' {
        $script:lines | Should -Contain '![See a sample: call order and data flow](diagrams/sample.svg)'
    }

    It 'numbers the calls in order, with their area and caller' {
        $script:lines | Should -Contain '1. `Read-Thing` (Settings): finds the thing'
        $script:lines | Should -Contain '2. `Write-Thing` (Common, called by Read-Thing): writes it'
    }

    It 'numbers the data across the whole diagram, reads before writes' {
        $script:lines | Should -Contain '   - Reads D1, settings: Settings files (Shared\a.json, <VM>\b.json)'
        $script:lines | Should -Contain '   - Reads D2, key: Key (k)'
        $script:lines | Should -Contain '   - Writes D3, result: Pipeline (text)'
    }

    It 'lists the functions a step runs for it' {
        $script:lines | Should -Contain '   - Also runs `Format-Thing`, `Test-Thing`'
    }

    It 'says what calls the command, when something does' {
        $diagram = New-TestDiagram
        $diagram.CalledBy = @{ Name = 'LazyVM-Maintain-<VM>'; Kind = 'task'; Notes = @('daily at MaintenanceTime', 'as SYSTEM') }

        (ConvertTo-DiagramMarkdown -Diagram $diagram) -split "`n" | Should -Contain 'Called by: `LazyVM-Maintain-<VM>` (daily at MaintenanceTime, as SYSTEM).'
    }

    It 'names a step''s second function and its arguments' {
        $diagram = New-TestDiagram
        $diagram.Steps[0].Also = @('Read-Other')
        $diagram.Steps[1].Arguments = '-Force'

        $lines = (ConvertTo-DiagramMarkdown -Diagram $diagram) -split "`n"

        $lines | Should -Contain '1. `Read-Thing` and `Read-Other` (Settings): finds the thing'
        $lines | Should -Contain '2. `Write-Thing -Force` (Common, called by Read-Thing): writes it'
    }

    It 'lists three or more paired functions as a list' {
        $diagram = New-TestDiagram
        $diagram.Steps[0].Also = @('Read-Other', 'Read-Third')

        (ConvertTo-DiagramMarkdown -Diagram $diagram) -split "`n" | Should -Contain '1. `Read-Thing`, `Read-Other` and `Read-Third` (Settings): finds the thing'
    }
}

Describe 'ConvertTo-DiagramDocument' {
    It 'puts the introduction, the contents by group and every diagram in the index''s order' {
        $first = New-TestDiagram
        $second = New-TestDiagram
        $second.Id = 'other'
        $second.Title = 'See another'
        $index = @{
            Title     = 'Diagrams'
            Intro     = 'One per thing.'
            HowToRead = @('Blue is calls.')
            Groups    = @(@{ Name = 'Check'; Diagrams = @('sample', 'other') })
            Footer    = 'Generated.'
        }

        $document = ConvertTo-DiagramDocument -Index $index -Diagrams @($first, $second)

        $document | Should -Match '(?s)^# Diagrams\n\nOne per thing\.\n\n## How to read them\n\n- Blue is calls\.\n'
        $document | Should -Match '- Check: \[See a sample\]\(#sample\), \[See another\]\(#other\)'
        $document.IndexOf('## See a sample') | Should -BeLessThan $document.IndexOf('## See another')
        $document | Should -Match '(?s)---\n\nGenerated\.\n$'
    }
}

Describe 'ConvertTo-DiagramSvg' {
    BeforeAll {
        $script:svgText = ConvertTo-DiagramSvg -Diagram (New-TestDiagram)
        $script:svg = [xml]$script:svgText
        $script:ns = [System.Xml.XmlNamespaceManager]::new($script:svg.NameTable)
        $script:ns.AddNamespace('s', 'http://www.w3.org/2000/svg')
    }

    It 'is well-formed SVG with a title for screen readers' {
        $script:svg.DocumentElement.LocalName | Should -Be 'svg'
        $script:svg.SelectSingleNode('//s:title', $script:ns).InnerText | Should -Match '^See a sample'
    }

    It 'numbers one call per step' {
        $numbers = @($script:svg.SelectNodes('//s:g[@class="sn"]/s:text', $script:ns) | ForEach-Object InnerText)
        $numbers | Should -Be @('1', '2')
    }

    It 'badges each piece of data once, in order' {
        $badges = @($script:svg.SelectNodes('//s:g[@class="bd"]/s:text', $script:ns) | ForEach-Object InnerText)
        $badges | Should -Be @('D1', 'D2', 'D3')
    }

    It 'shows each function as a call' {
        $names = @($script:svg.SelectNodes('//s:text[@class="nm"]', $script:ns) | ForEach-Object InnerText)
        $names | Should -Contain 'Read-Thing()'
        $names | Should -Contain 'Write-Thing()'
    }

    It 'escapes text that is not XML' {
        $script:svgText | Should -Match '&lt;VM&gt;\\b\.json'
    }

    It 'follows the viewer''s light or dark theme' {
        $script:svgText | Should -Match 'prefers-color-scheme: dark'
    }

    It 'names a step''s caller on its own line, so the stereotype stays clear of the step number' {
        $stereotypes = @($script:svg.SelectNodes('//s:g[@class="bx-mod"]/s:text[@class="st"]', $script:ns) | ForEach-Object InnerText)
        $stereotypes | Should -Be @('«Settings»', '«Common»')
        $script:svgText | Should -Match '>called by Read-Thing</text>'
    }

    It 'grows taller with each step' {
        $longer = New-TestDiagram
        $longer.Steps += @{ Function = 'Remove-Thing'; Area = 'Common'; Note = 'and one more' }

        $height = { param($text) [double]([xml]$text).DocumentElement.height }

        (& $height (ConvertTo-DiagramSvg -Diagram $longer)) | Should -BeGreaterThan (& $height $script:svgText)
    }
}

Describe 'Get-CodeFunctionIndex' {
    It 'finds every function defined in the scripts under the paths' {
        Set-Content -Path (Join-Path -Path $TestDrive -ChildPath 'a.ps1') -Value "function Get-A { Get-B }`nfunction Get-B { }"

        $index = Get-CodeFunctionIndex -Path $TestDrive

        @($index.Keys | Sort-Object) | Should -Be @('Get-A', 'Get-B')
    }
}

Describe 'Get-DiagramCoverageGap' {
    BeforeAll {
        Set-Content -Path (Join-Path -Path $TestDrive -ChildPath 'code.ps1') -Value @'
function Invoke-Orchestrator {
    Write-LogEntry 'starting'
    Read-Thing
    & { Write-Thing }
    Remove-Thing
    Skip-Thing
    Get-ChildItem
}
function Read-Thing { }
function Write-Thing { }
function Remove-Thing { }
function Skip-Thing { }
function Write-LogEntry { }
'@
        $script:index = Get-CodeFunctionIndex -Path $TestDrive
    }

    It 'reports the functions the covered code calls that the diagram leaves out' {
        $diagram = New-TestDiagram
        $diagram.Covers = @('Invoke-Orchestrator')
        $diagram.Omits = @{ 'Skip-Thing' = 'not worth showing' }

        Get-DiagramCoverageGap -Diagram $diagram -FunctionIndex $script:index | Should -Be @('Invoke-Orchestrator calls Remove-Thing')
    }

    It 'ignores logging and commands that are not the code''s own' {
        $diagram = New-TestDiagram
        $diagram.Covers = @('Invoke-Orchestrator')
        $diagram.Omits = @{ 'Skip-Thing' = 'x'; 'Remove-Thing' = 'x' }

        @(Get-DiagramCoverageGap -Diagram $diagram -FunctionIndex $script:index).Count | Should -Be 0
    }

    It 'reports a covered function that does not exist' {
        $diagram = New-TestDiagram
        $diagram.Covers = @('Invoke-Gone')

        Get-DiagramCoverageGap -Diagram $diagram -FunctionIndex $script:index | Should -Be @('Invoke-Gone does not exist')
    }
}

Describe 'Get-DiagramUnknownFunction' {
    It 'lists the functions a diagram names that the code does not define' {
        $index = @{ 'Read-Thing' = $null; 'Write-Thing' = $null; 'Format-Thing' = $null; 'Get-Sample' = $null }

        Get-DiagramUnknownFunction -Diagram (New-TestDiagram) -FunctionIndex $index | Should -Be @('Test-Thing')
    }

    It 'does not look for a step marked External, such as a Hyper-V cmdlet or a script' {
        $diagram = New-TestDiagram
        $diagram.Steps[1].External = $true
        $index = @{ 'Read-Thing' = $null; 'Get-Sample' = $null; 'Format-Thing' = $null; 'Test-Thing' = $null }

        @(Get-DiagramUnknownFunction -Diagram $diagram -FunctionIndex $index).Count | Should -Be 0
    }

    It 'does not look for the command of a diagram marked External, such as a script' {
        $diagram = New-TestDiagram
        $diagram.External = $true
        $diagram.Command = './Install.ps1'
        $index = @{ 'Read-Thing' = $null; 'Write-Thing' = $null; 'Format-Thing' = $null; 'Test-Thing' = $null }

        @(Get-DiagramUnknownFunction -Diagram $diagram -FunctionIndex $index).Count | Should -Be 0
    }
}

Describe 'Test-DiagramSource' {
    It 'passes a complete source' {
        @(Test-DiagramSource -Diagram (New-TestDiagram)).Count | Should -Be 0
    }

    It 'names what a source is missing' {
        $diagram = New-TestDiagram
        $diagram.Remove('Summary')
        $diagram.Steps[0].Remove('Area')

        Test-DiagramSource -Diagram $diagram | Should -Be @('sample: no Summary', 'sample step 1: no Area')
    }
}

Describe 'Get-DiagramOverflow' {
    It 'passes text that fits its boxes' {
        @(Get-DiagramOverflow -Diagram (New-TestDiagram)).Count | Should -Be 0
    }

    It 'reports a name too long for its box' {
        $diagram = New-TestDiagram
        $diagram.Steps[0].Function = 'Get-AFunctionNameFarTooLongToFitInItsBox'

        Get-DiagramOverflow -Diagram $diagram | Should -Be @('sample step 1: "Get-AFunctionNameFarTooLongToFitInItsBox()" does not fit its box')
    }

    It 'reports a word too long to wrap' {
        $diagram = New-TestDiagram
        $diagram.Steps[0].Reads[0].Items = @('Shared\Config\AVeryLongFileNameThatCannotWrap.json')

        Get-DiagramOverflow -Diagram $diagram | Should -Be @('sample step 1: "Shared\Config\AVeryLongFileNameThatCannotWrap.json" does not fit its box')
    }
}

Describe 'Get-DiagramStaleFile' {
    It 'lists outputs that are missing or differ, ignoring line endings' {
        $output = [ordered]@{ 'same.md' = "a`nb`n"; 'crlf.md' = "a`nb`n"; 'changed.md' = "new`n"; 'missing.md' = "x`n" }
        Set-Content -Path (Join-Path $TestDrive 'same.md') -Value "a`nb`n" -NoNewline
        Set-Content -Path (Join-Path $TestDrive 'crlf.md') -Value "a`r`nb`r`n" -NoNewline
        Set-Content -Path (Join-Path $TestDrive 'changed.md') -Value "old`n" -NoNewline

        Get-DiagramStaleFile -Root $TestDrive -Output $output | Should -Be @('changed.md', 'missing.md')
    }
}

Describe 'The diagrams in docs\Diagrams.md' {
    BeforeAll {
        $script:set = Import-DiagramSet -Root $script:repoRoot
        $script:functions = Get-CodeFunctionIndex -Path @(
            (Join-Path -Path $script:repoRoot -ChildPath 'src')
            (Join-Path -Path $script:repoRoot -ChildPath 'build')
            (Join-Path -Path $script:repoRoot -ChildPath 'Invoke-AnalyzerAndTest.ps1')
            (Join-Path -Path $script:repoRoot -ChildPath 'New-ReleasePackage.ps1')
        )
    }

    It 'has a complete source for each' {
        $problems = @($script:set.Diagrams | ForEach-Object { Test-DiagramSource -Diagram $_ })
        $problems | Should -BeNullOrEmpty -Because ($problems -join '; ')
    }

    It 'fits every name and line in its box' {
        $overflow = @($script:set.Diagrams | ForEach-Object { Get-DiagramOverflow -Diagram $_ })
        $overflow | Should -BeNullOrEmpty -Because ($overflow -join '; ')
    }

    It 'names only functions the code defines' {
        $unknown = @(foreach ($diagram in $script:set.Diagrams) {
                Get-DiagramUnknownFunction -Diagram $diagram -FunctionIndex $script:functions | ForEach-Object { "$($diagram.Id): $_" }
            })
        $unknown | Should -BeNullOrEmpty -Because ($unknown -join '; ')
    }

    It 'shows every call the code it covers makes' {
        $gaps = @(foreach ($diagram in $script:set.Diagrams) {
                Get-DiagramCoverageGap -Diagram $diagram -FunctionIndex $script:functions | ForEach-Object { "$($diagram.Id): $_" }
            })
        $gaps | Should -BeNullOrEmpty -Because "a diagram must show each call, or say in Omits why not: $($gaps -join '; ')"
    }

    It 'matches its source: run ./Update-Diagram.ps1 after changing one' {
        $stale = @(Get-DiagramStaleFile -Root $script:repoRoot -Output (Get-DiagramOutput -Set $script:set))
        $stale | Should -BeNullOrEmpty -Because "these are out of date: $($stale -join ', ')"
    }
}
