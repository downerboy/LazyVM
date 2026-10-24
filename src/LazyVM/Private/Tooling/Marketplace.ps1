# Marketplace.ps1 - Visual Studio Marketplace links for per-user extensions.
# Dot-sourced by LazyVM.psm1; not meant to be run on its own.

# ─────────────────────────────────────────────────────────────────────────────
#  MARKETPLACE LINKS FOR PER-USER EXTENSIONS
#
#  An extension installed from Manage Extensions is per-user, and the Visual
#  Studio Installer's export does not include it. Its manifest has its VSIX id
#  but no marketplace link, and the installer needs the link to reinstall it.
#  The link is found by searching the marketplace for the extension's name and
#  accepting only a result whose name AND publisher match the manifest's
#  exactly, so a similarly named extension is never installed in its place.
#
#  The answer, found or not, is kept in the tooling list and reused, so each
#  extension is looked up once. A failed lookup (no network) is retried on the
#  next run.
# ─────────────────────────────────────────────────────────────────────────────

function Resolve-MarketplaceItem {
    <#
      The marketplace item name (Publisher.Name) for an installed extension,
      '' when there is no match, $null when the lookup failed.

      The marketplace does not return extensions' VSIX ids, so a result is
      accepted only when both its display name and its publisher match the
      installed extension's manifest exactly (ignoring case), and only one
      result does. A near miss is reported as no match, never installed in
      the extension's place.
    #>
    param(
        [Parameter(Mandatory)][string]$DisplayName,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Publisher
    )

    $body = @{
        filters = @(@{
                criteria   = @(
                    @{ filterType = 8; value = 'Microsoft.VisualStudio.Ide' }
                    @{ filterType = 10; value = $DisplayName }
                )
                pageNumber = 1
                pageSize   = 25
            })
        # Versions, files, version properties, asset links, latest version only.
        flags   = 914
    } | ConvertTo-Json -Depth 6

    try {
        $response = Invoke-RestMethod -Method Post -TimeoutSec 30 `
            -Uri 'https://marketplace.visualstudio.com/_apis/public/gallery/extensionquery' `
            -ContentType 'application/json' -Headers @{ Accept = 'application/json;api-version=3.0-preview.1' } -Body $body
    }
    catch {
        Write-LogEntry "  marketplace lookup failed for '$DisplayName': $($_.Exception.Message)" 'WARN'
        return $null
    }

    # Not every result carries every field, so none is assumed.
    $candidates = @()
    foreach ($result in @([RecordReader]::Field($response, 'results'))) {
        foreach ($extension in @([RecordReader]::Field($result, 'extensions'))) {
            if (-not $extension) { continue }
            if ([RecordReader]::Text($extension, 'displayName').Trim() -ne $DisplayName.Trim()) { continue }

            $publisherInfo = [RecordReader]::Field($extension, 'publisher')
            $publisherName = [RecordReader]::Text($publisherInfo, 'publisherName')
            $publisherDisplay = [RecordReader]::Text($publisherInfo, 'displayName')
            if ($Publisher.Trim() -ne $publisherDisplay.Trim() -and $Publisher.Trim() -ne $publisherName.Trim()) { continue }

            $candidates += "$publisherName.$([RecordReader]::Text($extension, 'extensionName'))"
        }
    }

    $unique = @($candidates | Sort-Object -Unique)
    if ($unique.Count -eq 1) { return $unique[0] }
    return ''
}

function Add-MarketplaceItem {
    <# Gives each per-user extension in $Record its MarketplaceItem, reusing $Previous's answers. Updates $Record in place. #>
    param(
        [Parameter(Mandatory)][ToolingRecord]$Record,
        [AllowNull()][ToolingRecord]$Previous
    )

    $known = @{}
    if ($Previous) {
        foreach ($extension in @($Previous.Products | ForEach-Object { $_.UserExtensions })) {
            if ($extension -and $null -ne $extension.MarketplaceItem) { $known[$extension.Id] = "$($extension.MarketplaceItem)" }
        }
    }

    foreach ($extension in @($Record.Products | ForEach-Object { $_.UserExtensions })) {
        if (-not $extension) { continue }
        if ($known.ContainsKey($extension.Id)) {
            $extension.MarketplaceItem = $known[$extension.Id]
            continue
        }
        # A lookup that fails leaves this extension without a link for now;
        # it is tried again on the next run, and never stops one.
        try {
            $item = Resolve-MarketplaceItem -DisplayName $extension.DisplayName -Publisher $extension.Publisher
            if ($null -ne $item) { $extension.MarketplaceItem = $item }
        }
        catch {
            Write-LogEntry "  marketplace lookup failed for '$($extension.DisplayName)': $($_.Exception.Message)" 'WARN'
        }
    }
}
