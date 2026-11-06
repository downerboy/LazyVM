# Encoding.Tests.ps1
# Settings, configuration, templates and schemas are UTF-8 without a byte
# order mark (#332): the files LazyVM ships, and the ones it writes, on the
# host and in the guest. Nothing here touches a VM.

BeforeAll {
    . (Join-Path -Path $PSScriptRoot -ChildPath 'TestHelpers.ps1')
    Import-LazyVMModule

    $module = 'LazyVM'
    $dataDir = Join-Path -Path $script:LazyVMModuleDir -ChildPath 'Data'
    $strictUtf8 = [Text.UTF8Encoding]::new($false, $true)

    function Test-ByteOrderMark {
        param([Parameter(Mandatory)][string]$Path)
        $bytes = [IO.File]::ReadAllBytes($Path)
        return ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
    }
}

Describe 'The JSON files LazyVM ships' {
    BeforeDiscovery {
        $root = Join-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -ChildPath 'src\LazyVM\Data'
        $shipped = @(Get-ChildItem -LiteralPath $root -Filter '*.json' -Recurse -File | ForEach-Object {
                @{ Name = $_.FullName.Substring($root.Length + 1); Path = $_.FullName }
            })
    }

    It 'ship at least the schemas, the built-in templates and the default tooling list' {
        $names = @(Get-ChildItem -LiteralPath $dataDir -Filter '*.json' -Recurse -File | ForEach-Object Name)

        $names | Should -Contain 'LazyVM.Settings.schema.json'
        $names | Should -Contain 'LazyVM.Template.schema.json'
        $names | Should -Contain 'Developer.json'
        $names | Should -Contain 'PlainWindows.json'
        $names | Should -Contain 'Tooling.Default.json'
    }

    It '<Name> is UTF-8 without a byte order mark' -ForEach $shipped {
        Test-ByteOrderMark -Path $Path | Should -BeFalse
        { $strictUtf8.GetString([IO.File]::ReadAllBytes($Path)) } | Should -Not -Throw
    }
}

Describe 'The files LazyVM writes on the host' {
    It 'Write-TextFileAtomic, which writes the settings, VM.json, the history and the templates, writes UTF-8 without a byte order mark' {
        $path = Join-Path -Path $TestDrive -ChildPath 'atomic.json'

        # A name that is not ASCII (an e with an acute accent), so the encoding shows.
        $text = "{ ""Name"": ""Caf$([char]0xE9)"" }"

        InModuleScope $module -Parameters @{ Path = $path; Text = $text } { param($Path, $Text) Write-TextFileAtomic -Path $Path -Text $Text }

        Test-ByteOrderMark -Path $path | Should -BeFalse
        $strictUtf8.GetString([IO.File]::ReadAllBytes($path)) | Should -Be $text
    }

    It 'the Config folder''s schemas and settings file are UTF-8 without a byte order mark' {
        $configDir = Join-Path -Path $TestDrive -ChildPath ([guid]::NewGuid().ToString('N'))

        InModuleScope $module -Parameters @{ ConfigDir = $configDir } { param($ConfigDir) Initialize-ConfigFolder -ConfigDir $ConfigDir }

        foreach ($name in 'LazyVM.Settings.schema.json', 'LazyVM.Template.schema.json', 'LazyVM.Settings.json') {
            Test-ByteOrderMark -Path (Join-Path -Path $configDir -ChildPath $name) | Should -BeFalse -Because $name
        }
    }
}

Describe 'The JSON files LazyVM writes in the guest' {
    It 'are written without a byte order mark, which Windows PowerShell''s Set-Content -Encoding UTF8 adds' {
        $files = @(Get-ChildItem -LiteralPath $script:LazyVMModuleDir -Filter '*.ps1' -Recurse -File)
        # Read by the guest task wrapper with Windows PowerShell's Get-Content, which needs the mark to read UTF-8.
        $allowed = @('"$base.args.json"')

        $found = @(foreach ($file in $files) {
                $ast = [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$null, [ref]$null)
                $commands = $ast.FindAll({
                        param($node)
                        $node -is [System.Management.Automation.Language.CommandAst] -and $node.GetCommandName() -in 'Set-Content', 'Add-Content', 'Out-File'
                    }, $true)
                foreach ($command in $commands) {
                    $text = $command.Extent.Text
                    if ($text -notmatch '\.json' -or $text -notmatch '(?i)-Encoding\s+utf8\b') { continue }
                    if (@($allowed | Where-Object { $text.Contains($_) }).Count -gt 0) { continue }
                    "$($file.Name):$($command.Extent.StartLineNumber) $text"
                }
            })

        $found | Should -BeNullOrEmpty
    }
}
