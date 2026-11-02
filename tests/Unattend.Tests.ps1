# Unattend.Tests.ps1
# The answer file sets the guest's language, region and keyboard from the
# GuestLocale and GuestInputLocale settings (#31), not a hard-coded en-US.
# Nothing here needs Hyper-V or a guest.

BeforeAll {
    . (Join-Path -Path $PSScriptRoot -ChildPath 'TestHelpers.ps1')
    Import-LazyVMModule

    $module = 'LazyVM'

    function Get-TestInternational {
        <# The international settings of one pass of an answer file, as a hashtable of element name to value. #>
        param(
            [Parameter(Mandatory)][xml]$Xml,
            [Parameter(Mandatory)][string]$Pass
        )

        $ns = @{ u = 'urn:schemas-microsoft-com:unattend' }
        $component = (Select-Xml -Xml $Xml -Namespace $ns -XPath "/u:unattend/u:settings[@pass='$Pass']/u:component[starts-with(@name, 'Microsoft-Windows-International-Core')]").Node
        $values = @{}
        foreach ($name in 'InputLocale', 'SystemLocale', 'UILanguage', 'UserLocale') {
            $values[$name] = $component[$name].InnerText
        }
        return $values
    }

    function New-TestUnattendXml {
        param([hashtable]$Locale = @{})

        $arguments = @{
            UserName     = 'devadmin'
            ComputerName = 'ALPHA'
            TimeZone     = 'UTC'
            MarkerKey    = 'HKLM\SOFTWARE\LazyVM'
        }
        foreach ($key in $Locale.Keys) { $arguments[$key] = $Locale[$key] }
        return InModuleScope $module -Parameters @{ Arguments = $arguments } { param($Arguments) New-UnattendXml @Arguments -Password (New-RandomPassword) }
    }
}

Describe 'New-UnattendXml' {
    It 'sets the language and region of both passes from the locale' -ForEach @('windowsPE', 'oobeSystem') {
        $xml = New-TestUnattendXml -Locale @{ Locale = 'de-DE' }

        $values = Get-TestInternational -Xml $xml -Pass $_

        @($values.SystemLocale, $values.UILanguage, $values.UserLocale) | Should -Be @('de-DE', 'de-DE', 'de-DE')
    }

    It 'sets the Setup screens language from the locale' {
        $xml = [xml](New-TestUnattendXml -Locale @{ Locale = 'fr-FR' })

        $setupLanguage = $xml.unattend.settings | Where-Object { $_.pass -eq 'windowsPE' } |
            ForEach-Object { $_.component } | Where-Object { $_.name -eq 'Microsoft-Windows-International-Core-WinPE' } |
            ForEach-Object { $_.SetupUILanguage.UILanguage }

        $setupLanguage | Should -Be 'fr-FR'
    }

    It 'uses the locale for the keyboard when no input locale is given' -ForEach @('windowsPE', 'oobeSystem') {
        $xml = New-TestUnattendXml -Locale @{ Locale = 'en-GB' }

        (Get-TestInternational -Xml $xml -Pass $_).InputLocale | Should -Be 'en-GB'
    }

    It 'uses the input locale for the keyboard when one is given' -ForEach @('windowsPE', 'oobeSystem') {
        $xml = New-TestUnattendXml -Locale @{ Locale = 'en-US'; InputLocale = '0809:00000809' }

        $values = Get-TestInternational -Xml $xml -Pass $_

        $values.InputLocale | Should -Be '0809:00000809'
        $values.UserLocale | Should -Be 'en-US'
    }
}

Describe 'New-UnattendXml automatic sign-in (#278)' {
    BeforeAll {
        $xml = [xml](New-TestUnattendXml -Locale @{ Locale = 'en-US' })
        $ns = @{ u = 'urn:schemas-microsoft-com:unattend' }
        $shell = (Select-Xml -Xml $xml -Namespace $ns -XPath "/u:unattend/u:settings[@pass='oobeSystem']/u:component[@name='Microsoft-Windows-Shell-Setup']").Node
        $commands = @($shell.FirstLogonCommands.SynchronousCommand)
    }

    It 'signs the guest account in automatically' {
        $shell.AutoLogon.Enabled | Should -Be 'true'
        $shell.AutoLogon.Username | Should -Be 'devadmin'
    }

    It 'removes the logon count at the first sign-in, so automatic sign-in never runs out' {
        $removeCount = @($commands | Where-Object { $_.CommandLine -eq 'reg delete "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" /v AutoLogonCount /f' })

        $removeCount.Count | Should -Be 1
    }

    It 'removes the logon count before marking the guest provisioned' {
        $removeCount = $commands | Where-Object { $_.CommandLine -match 'AutoLogonCount' }
        $marker = $commands | Where-Object { $_.CommandLine -match 'Provisioned' }

        [int]$removeCount.Order | Should -BeLessThan ([int]$marker.Order)
    }

    It 'gives each first-logon command its own order' {
        $orders = @($commands | ForEach-Object { [int]$_.Order })

        @($orders | Select-Object -Unique).Count | Should -Be $orders.Count
    }
}

Describe 'The guest locale settings' {
    It 'default to en-US with the keyboard following the locale' {
        $defaults = InModuleScope $module { Get-DefaultSetting }

        $defaults.GuestLocale | Should -Be 'en-US'
        $defaults.GuestInputLocale | Should -Be ''
    }
}
