#Requires -Version 7.6
<#
.SYNOPSIS
Redraws docs\Diagrams.md and its SVGs from their sources.

.DESCRIPTION
Each flow diagram is drawn from one source, docs\diagrams\source\<id>.psd1:
the command, each call in order, and the data each reads and writes. Its SVG
and its numbered list in docs\Diagrams.md are both made from that source.

When a command's calls change, change its source and run this. The tests
fail while a diagram names a function that does not exist, leaves out a
call the code it Covers makes, or is not redrawn from its source.

.EXAMPLE
./Update-Diagram.ps1

.EXAMPLE
./Update-Diagram.ps1 -WhatIf
#>
[CmdletBinding(SupportsShouldProcess)]
param()

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

. (Join-Path -Path $PSScriptRoot -ChildPath 'build/Diagrams.ps1')

Update-Diagram -Root $PSScriptRoot -WhatIf:$WhatIfPreference
