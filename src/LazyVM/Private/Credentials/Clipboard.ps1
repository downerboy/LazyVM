# Clipboard.ps1 - Puts a secret on the clipboard for VMConnect's Type clipboard text (#32).
# Dot-sourced by LazyVM.psm1; not meant to be run on its own.

function Set-ClipboardSecret {
    <#
      Puts $Text on the clipboard, marked with Windows'
      ExcludeClipboardContentFromMonitorProcessing format, so it is left out
      of clipboard history and never synced to other devices. Throws, leaving
      the clipboard alone, when it cannot be marked: Set-Clipboard would put
      the secret in the history.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPlainTextForPassword', 'Text', Justification = 'The clipboard holds text.')]
    param([Parameter(Mandatory)][string]$Text)

    if ([Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
        throw 'The clipboard can only be set from a single-threaded PowerShell session. Start pwsh without -MTA and try again.'
    }
    Add-Type -AssemblyName System.Windows.Forms
    $data = [System.Windows.Forms.DataObject]::new()
    $data.SetText($Text, [System.Windows.Forms.TextDataFormat]::UnicodeText)
    # Any data in this format does it; a stream goes to the clipboard as it is.
    $data.SetData('ExcludeClipboardContentFromMonitorProcessing', [IO.MemoryStream]::new([byte[]](0, 0, 0, 0)))
    [System.Windows.Forms.Clipboard]::SetDataObject($data, $true)
}
