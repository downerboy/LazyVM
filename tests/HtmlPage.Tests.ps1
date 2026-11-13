# HtmlPage.Tests.ps1
# The shell every LazyVM web page is built in (#375): one place for the
# look and the copy-button script, so a page cannot lose its policy,
# language, title or single h1.

BeforeAll {
    . (Join-Path -Path $PSScriptRoot -ChildPath 'TestHelpers.ps1')
    Import-LazyVMModule
    $module = 'LazyVM'

    function Get-TestPage {
        param([string]$Title = 'A page', [string]$Subtitle = '', [string[]]$Body = @('<p>Hello</p>'), [switch]$WithCopyScript)
        InModuleScope $module -Parameters @{ Title = $Title; Subtitle = $Subtitle; Body = $Body; WithCopyScript = $WithCopyScript } {
            param($Title, $Subtitle, $Body, $WithCopyScript)
            New-HtmlPage -Title $Title -Subtitle $Subtitle -Body $Body -WithCopyScript:$WithCopyScript
        }
    }
}

Describe 'New-HtmlPage (#375)' {
    It 'is a page in English with a title, one h1 in a header bar and the body inside main' {
        $html = Get-TestPage -Title 'A page' -Subtitle 'Scanned today.' -Body @('<p>One</p>', '<p>Two</p>')

        $html | Should -BeLike '<!DOCTYPE html>*'
        $html | Should -BeLike '*<html lang="en">*'
        $html | Should -BeLike '*<meta charset="utf-8">*'
        $html | Should -BeLike '*<title>A page</title>*'
        ([regex]::Matches($html, '<h1>')).Count | Should -Be 1
        $html | Should -BeLike '*<header>*<h1>A page</h1>*<p class="subtitle">Scanned today.</p>*</header>*<main>*<p>One</p>*<p>Two</p>*</main>*'
    }

    It 'has no subtitle line when it has no subtitle' {
        (Get-TestPage) | Should -Not -Match 'class="subtitle"'
    }

    It 'has a light and a dark theme, and respects reduced motion and forced colours' {
        $html = Get-TestPage

        $html | Should -Match 'prefers-color-scheme: dark'
        $html | Should -Match 'prefers-reduced-motion'
        $html | Should -Match 'forced-colors: active'
    }

    It 'has one yellow button style with a visible focus outline' {
        $html = Get-TestPage

        $html | Should -Match '(?s)button \{[^}]*--lv-accent'
        $html | Should -Match 'button:focus-visible'
    }

    It 'loads nothing from anywhere: its policy allows only its own style and script' {
        $html = Get-TestPage

        $html | Should -BeLike "*<meta http-equiv=`"Content-Security-Policy`" content=`"default-src 'none'; style-src 'unsafe-inline'; script-src 'unsafe-inline'`">*"
        $html | Should -Match '<style>'
    }

    It 'writes the title as text, so a name from the VM is shown, never run' {
        $html = Get-TestPage -Title 'Findings for <b>&Alpha'

        $html | Should -BeLike '*<title>Findings for &lt;b&gt;&amp;Alpha</title>*'
        $html | Should -BeLike '*<h1>Findings for &lt;b&gt;&amp;Alpha</h1>*'
        $html | Should -Not -BeLike '*<b>*'
    }

    It 'adds the copy script only when asked, after the page content' {
        (Get-TestPage) | Should -Not -Match '<script>'

        $html = Get-TestPage -WithCopyScript

        $html | Should -Match '(?s)</main>.*<script>.*button\[data-copy\].*</script>'
    }

    It 'ends its lines with CRLF only, so it is written the same on every host' {
        $html = Get-TestPage -WithCopyScript

        $html | Should -Not -Match '(?<!\r)\n'
    }
}
