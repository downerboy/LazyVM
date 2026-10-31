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

Describe 'The guest locale settings' {
    It 'default to en-US with the keyboard following the locale' {
        $defaults = InModuleScope $module { Get-DefaultSetting }

        $defaults.GuestLocale | Should -Be 'en-US'
        $defaults.GuestInputLocale | Should -Be ''
    }
}
