# AwaitingReinstall.ps1 - Items that must be reinstalled by hand after a rebuild.
# Dot-sourced by LazyVM.psm1; not meant to be run on its own.
#
# A rebuild cannot reinstall programs that have no winget package, or
# per-user extensions with no Marketplace link. It lists them in the tooling
# list under AwaitingReinstall. The daily run keeps them recorded while they
# are missing, so they are not taken as uninstalled, and reminds you of them;
# each one leaves the list once it is installed again. To drop one you no
# longer want, delete it from Tooling.AwaitingReinstall in VM.json.

function Merge-AwaitingReinstall {
    <#
      Carries $Previous's AwaitingReinstall items into $Record: each one still
      missing is put back (so it is not seen as removed) and stays awaiting;
      each one installed again is dropped from the list. Updates $Record.
    #>
    param(
        [Parameter(Mandatory)][ToolingRecord]$Record,
        [AllowNull()][ToolingRecord]$Previous
    )

    $awaiting = [AwaitingReinstall]::new()
    if ($Previous) {
        $present = @($Record.Programs | ForEach-Object { $_.Name })
        $awaiting.Programs = [ToolingProgram[]]@($Previous.Awaiting().Programs | Where-Object { $_ -and $present -notcontains $_.Name })
        $awaiting.Extensions = [AwaitingExtension[]]@($Previous.Awaiting().Extensions | Where-Object {
                $_ -and -not ($Record.FindProduct($_.ProductKey) -and $Record.FindProduct($_.ProductKey).FindUserExtension($_.Id))
            })
    }

    if ($awaiting.Programs.Count -gt 0) {
        $Record.Programs = [ToolingProgram[]]@(@($Record.Programs) + @($awaiting.Programs) | Sort-Object Name)
    }
    foreach ($item in $awaiting.Extensions) {
        $product = $Record.FindProduct($item.ProductKey)
        if (-not $product) { continue }
        $extension = [ToolingExtension]::new()
        $extension.Id = $item.Id
        $extension.DisplayName = $item.DisplayName
        $extension.Publisher = $item.Publisher
        $extension.MoreInfo = ''
        $extension.MarketplaceItem = ''
        $product.UserExtensions = [ToolingExtension[]]@(@($product.UserExtensions) + $extension | Sort-Object Id)
    }

    $Record.AwaitingReinstall = $awaiting
    if ($awaiting.Count() -gt 0) {
        Write-LogList -Heading "$($awaiting.Count()) item(s) from before the last rebuild still need installing by hand:" -Level WARN `
            -Items (@($awaiting.Programs | ForEach-Object { "program: $($_.Name)" }) + @($awaiting.Extensions | ForEach-Object { "extension: $($_.DisplayName)" }))
    }
}
