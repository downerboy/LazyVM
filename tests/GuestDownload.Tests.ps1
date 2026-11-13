# GuestDownload.Tests.ps1
# Downloads in the guest are tried again after a transient failure (#359).
# Right after the guest's network comes up a name can fail to resolve for a
# moment; one failed try must not fail the whole install. Invoke-WebRequest
# and the pause between tries are mocked, so nothing here touches a network.

BeforeAll {
    . (Join-Path -Path $PSScriptRoot -ChildPath 'TestHelpers.ps1')
    Import-LazyVMModule

    # The guest-side helpers, loaded here as they are into the guest.
    . (Join-Path -Path $script:LazyVMModuleDir -ChildPath 'Data\Guest.Helpers.ps1')
}

Describe 'Save-GuestDownload (#359)' {
    BeforeEach {
        $script:tries = 0
        $script:failures = 0
        Mock Start-Sleep { }
        Mock Invoke-WebRequest {
            $script:tries++
            if ($script:failures -gt 0) {
                $script:failures--
                throw [System.Net.WebException]::new("The remote name could not be resolved: 'aka.ms'")
            }
            [pscustomobject]@{ StatusCode = 200 }
        }
    }

    It 'downloads in one try when the network works' {
        $response = Save-GuestDownload -Uri 'https://aka.ms/vs/stable/vs_community.exe' -OutFile 'C:\Staging\vs.exe' -TimeoutSec 600

        $response.StatusCode | Should -Be 200
        $script:tries | Should -Be 1
        Should -Invoke Start-Sleep -Times 0 -Exactly
    }

    It 'tries again after a name that did not resolve, and returns the response of the try that worked' {
        $script:failures = 2

        $response = Save-GuestDownload -Uri 'https://aka.ms/vs/stable/vs_community.exe' -OutFile 'C:\Staging\vs.exe' -TimeoutSec 600

        $response.StatusCode | Should -Be 200
        $script:tries | Should -Be 3
        Should -Invoke Start-Sleep -Times 2 -Exactly
    }

    It 'gives up with the last error once every try has failed' {
        $script:failures = 100

        { Save-GuestDownload -Uri 'https://aka.ms/vs/stable/vs_community.exe' -OutFile 'C:\Staging\vs.exe' -TimeoutSec 600 } |
            Should -Throw -ExpectedMessage "*could not be resolved*"

        $script:tries | Should -Be $script:GuestDownloadAttempts
    }

    It 'does not try again when the server answered that the file is not there' {
        Mock Invoke-WebRequest {
            $script:tries++
            $notFound = [System.Net.Http.HttpResponseMessage]::new([System.Net.HttpStatusCode]::NotFound)
            throw [Microsoft.PowerShell.Commands.HttpResponseException]::new('Response status code does not indicate success: 404 (Not Found).', $notFound)
        }

        { Save-GuestDownload -Uri 'https://aka.ms/vs/stable/gone.exe' -OutFile 'C:\Staging\vs.exe' -TimeoutSec 600 } | Should -Throw

        $script:tries | Should -Be 1
    }

    It 'passes the address, file and timeout on to Invoke-WebRequest' {
        $null = Save-GuestDownload -Uri 'https://aka.ms/x.exe' -OutFile 'C:\Staging\x.exe' -TimeoutSec 77

        Should -Invoke Invoke-WebRequest -Times 1 -Exactly -ParameterFilter {
            $Uri -eq 'https://aka.ms/x.exe' -and $OutFile -eq 'C:\Staging\x.exe' -and $TimeoutSec -eq 77 -and $UseBasicParsing
        }
    }
}

Describe 'The guest downloads that retry (#359)' {
    It 'downloads the Visual Studio bootstrapper through Save-GuestDownload' {
        $source = Get-Content -LiteralPath (Join-Path $script:LazyVMModuleDir 'Private\Installation\VisualStudio.ps1') -Raw

        $source | Should -Match 'Save-GuestDownload -Uri \$url -OutFile \$bootstrapper'
        $source | Should -Not -Match 'Invoke-WebRequest'
    }

    It 'downloads official installers through Save-GuestDownload' {
        $source = Get-Content -LiteralPath (Join-Path $script:LazyVMModuleDir 'Private\Installation\OfficialInstaller.ps1') -Raw

        $source | Should -Match 'Save-GuestDownload -Uri \$url -OutFile \$download'
        $source | Should -Not -Match 'Invoke-WebRequest'
    }
}
