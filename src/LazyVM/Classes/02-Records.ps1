# 02-Records.ps1 - The records LazyVM keeps on disk, as types: tooling lists and captures.
# Loaded before the functions by LazyVM.psm1; not meant to be run on its own.
#
# They are in one file because PowerShell resolves the types a class uses
# when it reads the file, so a class cannot use one from another file.
#
# A record is read from JSON, built in memory, or written by hand in a test.
# FromObject accepts a dictionary or an object read from JSON alike, so
# everything after that works with one shape. ToJson writes the same JSON as
# earlier versions, so existing files keep working in both directions.

class RecordReader {
    # A field of a dictionary or an object, or $null when it has none.
    static [object] Field([object]$item, [string]$name) {
        if ($null -eq $item) { return $null }
        if ($item -is [System.Collections.IDictionary]) {
            if ($item.Contains($name)) { return $item[$name] }
            return $null
        }
        $property = $item.PSObject.Properties[$name]
        if ($property) { return $property.Value }
        return $null
    }

    # A field as a list of text, leaving out empty entries.
    static [string[]] Strings([object]$item, [string]$name) {
        $value = [RecordReader]::Field($item, $name)
        if ($null -eq $value) { return [string[]]@() }
        return [string[]]@(@($value) | Where-Object { $_ } | ForEach-Object { "$_" })
    }

    # A field as text, '' when it has none.
    static [string] Text([object]$item, [string]$name) {
        $value = [RecordReader]::Field($item, $name)
        if ($null -eq $value) { return '' }
        return "$value"
    }
}

class ToolingExtension {
    [string]$Id
    [string]$DisplayName
    [string]$Publisher
    [string]$MoreInfo

    # $null: not looked up yet; '': no Marketplace match; otherwise its
    # Marketplace item name (Publisher.Name). [object], because a [string]
    # property would turn $null into '' and lose the difference.
    [object]$MarketplaceItem

    static [string] LinkFor([string]$item) {
        return "https://marketplace.visualstudio.com/items?itemName=$item"
    }

    # Its Marketplace link, or $null when it has none.
    [string] Link() {
        if ($this.MarketplaceItem) { return [ToolingExtension]::LinkFor($this.MarketplaceItem) }
        return $null
    }

    # How it is compared: by Marketplace link when one is known, so the same
    # extension reinstalled for all users matches; by name and id otherwise.
    [string] Identity() {
        $link = $this.Link()
        if ($link) { return $link }
        return '{0} [{1}]' -f $this.DisplayName, $this.Id
    }

    static [ToolingExtension] FromObject([object]$item) {
        $extension = [ToolingExtension]::new()
        $extension.Id = [RecordReader]::Text($item, 'Id')
        $extension.DisplayName = [RecordReader]::Text($item, 'DisplayName')
        $extension.Publisher = [RecordReader]::Text($item, 'Publisher')
        $extension.MoreInfo = [RecordReader]::Text($item, 'MoreInfo')
        $marketplace = [RecordReader]::Field($item, 'MarketplaceItem')
        $extension.MarketplaceItem = if ($null -eq $marketplace) { $null } else { "$marketplace" }
        return $extension
    }

    [System.Collections.Specialized.OrderedDictionary] ToDictionary() {
        $dictionary = [ordered]@{ Id = $this.Id; DisplayName = $this.DisplayName; Publisher = $this.Publisher; MoreInfo = $this.MoreInfo }
        if ($null -ne $this.MarketplaceItem) { $dictionary['MarketplaceItem'] = $this.MarketplaceItem }
        return $dictionary
    }
}

class ToolingProduct {
    [string]$ProductId
    [string]$ChannelId
    [string]$DisplayName
    [string[]]$Components = @()
    # Instance-wide extensions, as Marketplace links.
    [string[]]$Extensions = @()
    # Per-user extensions from Manage Extensions.
    [ToolingExtension[]]$UserExtensions = @()
    [bool]$IncludeRecommended

    static [string] KeyFor([string]$productId, [string]$channelId) {
        return "$productId|$channelId"
    }

    # The same product on another channel is a different product.
    [string] Key() {
        return [ToolingProduct]::KeyFor($this.ProductId, $this.ChannelId)
    }

    # The edition, lower case: Microsoft.VisualStudio.Product.Community -> community.
    [string] Edition() {
        return ($this.ProductId -split '\.')[-1].ToLowerInvariant()
    }

    # Every extension's comparison identity, sorted and without duplicates.
    [string[]] ExtensionIdentities() {
        $identities = @($this.Extensions) + @($this.UserExtensions | ForEach-Object { $_.Identity() })
        return [string[]]@($identities | Where-Object { $_ } | Sort-Object -Unique)
    }

    # Marketplace links for every extension that has one, for the installer.
    [string[]] ExtensionLinks() {
        $links = @($this.Extensions) + @($this.UserExtensions | ForEach-Object { $_.Link() })
        return [string[]]@($links | Where-Object { $_ } | Sort-Object -Unique)
    }

    [ToolingExtension] FindUserExtension([string]$id) {
        return @($this.UserExtensions | Where-Object { $_.Id -eq $id }) | Select-Object -First 1
    }

    static [ToolingProduct] FromObject([object]$item) {
        $product = [ToolingProduct]::new()
        $product.ProductId = [RecordReader]::Text($item, 'ProductId')
        $product.ChannelId = [RecordReader]::Text($item, 'ChannelId')
        $product.DisplayName = [RecordReader]::Text($item, 'DisplayName')
        $product.Components = [RecordReader]::Strings($item, 'Components')
        $product.Extensions = [RecordReader]::Strings($item, 'Extensions')
        $product.UserExtensions = [ToolingExtension[]]@(@([RecordReader]::Field($item, 'UserExtensions')) | Where-Object { $_ } | ForEach-Object { [ToolingExtension]::FromObject($_) })
        $product.IncludeRecommended = [bool][RecordReader]::Field($item, 'IncludeRecommended')
        return $product
    }

    [System.Collections.Specialized.OrderedDictionary] ToDictionary() {
        $dictionary = [ordered]@{
            ProductId      = $this.ProductId
            ChannelId      = $this.ChannelId
            DisplayName    = $this.DisplayName
            Components     = @($this.Components)
            Extensions     = @($this.Extensions)
            UserExtensions = @($this.UserExtensions | ForEach-Object { $_.ToDictionary() })
        }
        if ($this.IncludeRecommended) { $dictionary['IncludeRecommended'] = $true }
        return $dictionary
    }
}

class WingetPackage {
    [string]$Id
    [string]$Source

    static [WingetPackage] FromObject([object]$item) {
        $package = [WingetPackage]::new()
        $package.Id = [RecordReader]::Text($item, 'Id')
        $package.Source = [RecordReader]::Text($item, 'Source')
        return $package
    }

    [System.Collections.Specialized.OrderedDictionary] ToDictionary() {
        return [ordered]@{ Id = $this.Id; Source = $this.Source }
    }
}

class ToolingProgram {
    [string]$Name
    [string]$Publisher

    static [ToolingProgram] FromObject([object]$item) {
        $program = [ToolingProgram]::new()
        $program.Name = [RecordReader]::Text($item, 'Name')
        $program.Publisher = [RecordReader]::Text($item, 'Publisher')
        return $program
    }

    [System.Collections.Specialized.OrderedDictionary] ToDictionary() {
        return [ordered]@{ Name = $this.Name; Publisher = $this.Publisher }
    }
}

class AwaitingExtension {
    # The product it belongs to, as ToolingProduct.Key().
    [string]$ProductKey
    [string]$Id
    [string]$DisplayName
    [string]$Publisher

    static [AwaitingExtension] FromObject([object]$item) {
        $extension = [AwaitingExtension]::new()
        $extension.ProductKey = [RecordReader]::Text($item, 'ProductKey')
        $extension.Id = [RecordReader]::Text($item, 'Id')
        $extension.DisplayName = [RecordReader]::Text($item, 'DisplayName')
        $extension.Publisher = [RecordReader]::Text($item, 'Publisher')
        return $extension
    }

    [System.Collections.Specialized.OrderedDictionary] ToDictionary() {
        return [ordered]@{ ProductKey = $this.ProductKey; Id = $this.Id; DisplayName = $this.DisplayName; Publisher = $this.Publisher }
    }
}

class AwaitingReinstall {
    # Installed before a rebuild and not reinstalled automatically.
    [ToolingProgram[]]$Programs = @()
    [AwaitingExtension[]]$Extensions = @()

    [int] Count() {
        return @($this.Programs).Count + @($this.Extensions).Count
    }

    # Each item as one line, for comparing two lists.
    [string[]] Names() {
        $names = @($this.Programs | ForEach-Object { "program $($_.Name)" }) +
        @($this.Extensions | ForEach-Object { "extension $($_.DisplayName) [$($_.Id)]" })
        return [string[]]@($names | Where-Object { $_ })
    }

    static [AwaitingReinstall] FromObject([object]$item) {
        $awaiting = [AwaitingReinstall]::new()
        $awaiting.Programs = [ToolingProgram[]]@(@([RecordReader]::Field($item, 'Programs')) | Where-Object { $_ } | ForEach-Object { [ToolingProgram]::FromObject($_) })
        $awaiting.Extensions = [AwaitingExtension[]]@(@([RecordReader]::Field($item, 'Extensions')) | Where-Object { $_ } | ForEach-Object { [AwaitingExtension]::FromObject($_) })
        return $awaiting
    }

    [System.Collections.Specialized.OrderedDictionary] ToDictionary() {
        return [ordered]@{
            Programs   = @($this.Programs | ForEach-Object { $_.ToDictionary() })
            Extensions = @($this.Extensions | ForEach-Object { $_.ToDictionary() })
        }
    }
}

class ToolingRecord {
    static [int] $CurrentVersion = 1

    [int]$Version = [ToolingRecord]::CurrentVersion
    [string]$RecordedAt
    [string]$Description
    [ToolingProduct[]]$Products = @()
    [WingetPackage[]]$WingetPackages = @()
    [ToolingProgram[]]$Programs = @()
    # $null when the list has never had any.
    [AwaitingReinstall]$AwaitingReinstall

    [ToolingProduct] FindProduct([string]$key) {
        return @($this.Products | Where-Object { $_.Key() -eq $key }) | Select-Object -First 1
    }

    # The items awaiting reinstall, never $null.
    [AwaitingReinstall] Awaiting() {
        if ($this.AwaitingReinstall) { return $this.AwaitingReinstall }
        return [AwaitingReinstall]::new()
    }

    static [ToolingRecord] FromObject([object]$item) {
        $fileVersion = [RecordReader]::Field($item, 'Version')
        if ($null -ne $fileVersion -and [int]$fileVersion -gt [ToolingRecord]::CurrentVersion) {
            throw "This tooling list is version $fileVersion, newer than this LazyVM understands ($([ToolingRecord]::CurrentVersion)). Update LazyVM."
        }

        $record = [ToolingRecord]::new()
        $record.RecordedAt = [RecordReader]::Text($item, 'RecordedAt')
        $record.Description = [RecordReader]::Text($item, 'Description')
        $record.Products = [ToolingProduct[]]@(@([RecordReader]::Field($item, 'Products')) | Where-Object { $_ } | ForEach-Object { [ToolingProduct]::FromObject($_) })
        $record.WingetPackages = [WingetPackage[]]@(@([RecordReader]::Field($item, 'WingetPackages')) | Where-Object { $_ } | ForEach-Object { [WingetPackage]::FromObject($_) })
        $record.Programs = [ToolingProgram[]]@(@([RecordReader]::Field($item, 'Programs')) | Where-Object { $_ } | ForEach-Object { [ToolingProgram]::FromObject($_) })
        $awaiting = [RecordReader]::Field($item, 'AwaitingReinstall')
        if ($null -ne $awaiting) { $record.AwaitingReinstall = [AwaitingReinstall]::FromObject($awaiting) }
        return $record
    }

    static [ToolingRecord] FromJson([string]$json) {
        return [ToolingRecord]::FromObject(($json | ConvertFrom-Json))
    }

    [string] ToJson() {
        $document = [ordered]@{ Version = $this.Version; RecordedAt = $this.RecordedAt }
        if ($this.Description) { $document['Description'] = $this.Description }
        $document['Products'] = @($this.Products | ForEach-Object { $_.ToDictionary() })
        $document['WingetPackages'] = @($this.WingetPackages | ForEach-Object { $_.ToDictionary() })
        $document['Programs'] = @($this.Programs | ForEach-Object { $_.ToDictionary() })
        if ($this.AwaitingReinstall) { $document['AwaitingReinstall'] = $this.AwaitingReinstall.ToDictionary() }
        return ConvertTo-Json -InputObject $document -Depth 10
    }
}

# ── Captures ─────────────────────────────────────────────────────────────────
#
# Each capture area (VisualStudio, Sql, Windows, Projects, AppSettings) keeps
# the object its capture step returned: its restore step is the only reader.

class CaptureManifest {
    static [int] $CurrentVersion = 2

    [int]$Version = [CaptureManifest]::CurrentVersion
    [string]$CapturedAt
    [string]$CapturedFrom
    [string]$Stamp
    [object]$Guest
    [object]$VisualStudio
    [object]$Sql
    [object]$Windows
    [object]$Projects
    [object]$AppSettings
    [string[]]$Warnings = @()
    [string]$Summary
    [string[]]$Databases = @()

    static [CaptureManifest] FromObject([object]$item) {
        $fileVersion = [RecordReader]::Field($item, 'Version')
        if ($null -eq $fileVersion -or [int]$fileVersion -ne [CaptureManifest]::CurrentVersion) {
            throw "This capture is version $fileVersion; this LazyVM restores version $([CaptureManifest]::CurrentVersion). Capture the VM again with Save-LazyVMState."
        }

        $manifest = [CaptureManifest]::new()
        foreach ($name in 'CapturedAt', 'CapturedFrom', 'Stamp', 'Summary') {
            $manifest.$name = [RecordReader]::Text($item, $name)
        }
        foreach ($name in 'Guest', 'VisualStudio', 'Sql', 'Windows', 'Projects', 'AppSettings') {
            $manifest.$name = [RecordReader]::Field($item, $name)
        }
        $manifest.Warnings = [RecordReader]::Strings($item, 'Warnings')
        $manifest.Databases = [RecordReader]::Strings($item, 'Databases')
        return $manifest
    }

    static [CaptureManifest] FromJson([string]$json) {
        return [CaptureManifest]::FromObject(($json | ConvertFrom-Json))
    }

    [string] ToJson() {
        $document = [ordered]@{}
        foreach ($property in $this.PSObject.Properties) { $document[$property.Name] = $property.Value }
        return ConvertTo-Json -InputObject $document -Depth 8
    }
}
