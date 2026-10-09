<#
.SYNOPSIS
    Generates a single self-contained NetTool-Standalone.ps1.

.DESCRIPTION
    Run this on your own workstation, not on a client. It splices
    NetTool.Helpers.ps1 and NetTool_HTML_Report.ps1 into NetTool-Gui.ps1 and
    writes one file to build\NetTool-Standalone.ps1 that needs nothing beside
    it - copy it to C:\temp on any machine and run it.

    That is the point: the toolkit is normally three files because there is
    exactly one copy of the diagnostic logic and the GUI is not it. That is the
    right structure to work in and the wrong thing to carry into a Backstage
    session, where you want to paste one file and go.

    The helpers are embedded as PLAIN TEXT in a here-string, not base64. The
    GUI rebuilds them inside every background runspace from that same text, so
    it has to be text either way - and a script that decodes a blob and
    executes it is the exact shape endpoint protection is built to object to.

.NOTES
    Windows PowerShell 5.1. Re-run after any change to the source files.
#>

[CmdletBinding()]
param(
    [string]$OutputPath = ''
)

$ErrorActionPreference = 'Stop'

$scriptDir = $PSScriptRoot
if (-not $scriptDir) { $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $scriptDir) { $scriptDir = (Get-Location).Path }

$guiPath     = Join-Path $scriptDir 'NetTool-Gui.ps1'
$helpersPath = Join-Path $scriptDir 'NetTool.Helpers.ps1'
$htmlPath    = Join-Path $scriptDir 'NetTool_HTML_Report.ps1'

foreach ($required in @($guiPath, $helpersPath, $htmlPath)) {
    if (-not (Test-Path -LiteralPath $required)) { throw ('Source not found: {0}' -f $required) }
}

if (-not $OutputPath) {
    $buildDir = Join-Path $scriptDir 'build'
    if (-not (Test-Path -LiteralPath $buildDir)) { New-Item -ItemType Directory -Path $buildDir -Force | Out-Null }
    $OutputPath = Join-Path $buildDir 'NetTool-Standalone.ps1'
}

$gui     = Get-Content -LiteralPath $guiPath -Raw
$helpers = Get-Content -LiteralPath $helpersPath -Raw
$html    = Get-Content -LiteralPath $htmlPath -Raw

# --- Safety check: a here-string ends at a line beginning with '@ -----------
# If the helpers ever grow such a line the embed would terminate early and the
# generated file would be silently truncated garbage. Fail the build instead.
foreach ($line in ($helpers -split "`r?`n")) {
    if ($line -match "^\s*'@") {
        throw "NetTool.Helpers.ps1 contains a line starting with '@, which would terminate the embedded here-string. Reword it before building."
    }
}

# --- Replace the GUI's file-loading block with the embedded source ----------
$loadStart = "`$helpersPath = Join-Path `$scriptDir 'NetTool.Helpers.ps1'"
$loadEnd   = 'Set-NtProjectDir -Path $scriptDir'
$startAt = $gui.IndexOf($loadStart)
if ($startAt -lt 0) { throw 'Could not find the helper-loading block in NetTool-Gui.ps1. Update the anchors in this builder.' }
$endAt = $gui.IndexOf($loadEnd, $startAt)
if ($endAt -lt 0) { throw 'Could not find the end of the helper-loading block in NetTool-Gui.ps1.' }
$endAt += $loadEnd.Length

$embed = @"
# --- Helpers, embedded by Build-NetToolSingleFile.ps1 -----------------------
# Kept as text because each background runspace rebuilds the functions from it;
# runspaces do not inherit the caller's function table.
`$script:HelpersText = @'
$helpers
'@
. ([ScriptBlock]::Create(`$script:HelpersText))
Set-NtProjectDir -Path `$scriptDir
"@

$bundle = $gui.Substring(0, $startAt) + $embed + $gui.Substring($endAt)

# --- Inline the HTML renderer's functions ----------------------------------
# Its own param block and its "run directly against a JSON file" tail are both
# dropped: the first would collide with the GUI's param block, the second is a
# command-line entry point that makes no sense inside a GUI.
$htmlStart = $html.IndexOf('function ConvertTo-NtHtmlEncoded')
if ($htmlStart -lt 0) { throw 'Could not find the first function in NetTool_HTML_Report.ps1.' }
$htmlTail = $html.IndexOf('# Run directly against an exported JSON report.')
if ($htmlTail -lt 0) { $htmlTail = $html.Length }
$htmlBody = $html.Substring($htmlStart, $htmlTail - $htmlStart).TrimEnd()

$rendererBlock = @"

# --- HTML report renderer, embedded by Build-NetToolSingleFile.ps1 ----------
$htmlBody

"@

# Insert the renderer immediately after the embedded helpers so the GUI's
# Export HTML finds ConvertTo-NtHtmlReport already defined.
$anchor = 'Set-NtProjectDir -Path $scriptDir'
$anchorAt = $bundle.IndexOf($anchor)
$insertAt = $anchorAt + $anchor.Length
$bundle = $bundle.Substring(0, $insertAt) + "`r`n" + $rendererBlock + $bundle.Substring($insertAt)

# --- Header -----------------------------------------------------------------
$stamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
$header = @"
# ===========================================================================
#  NetTool-Standalone.ps1 - GENERATED FILE, DO NOT EDIT
#
#  Built $stamp from NetTool-Gui.ps1, NetTool.Helpers.ps1 and
#  NetTool_HTML_Report.ps1 by Build-NetToolSingleFile.ps1.
#
#  Edit the sources and re-run the builder. Anything changed here is lost on
#  the next build, and the three-file version remains the one under test.
#
#  Self-contained: copy this single file anywhere and run it.
#    powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File NetTool-Standalone.ps1
#
#  -STA matters. WinForms is unreliable without it, and the failure is
#  intermittent rather than obvious.
# ===========================================================================

"@

$final = $header + $bundle

# BUILD TEMPORARILY, VALIDATE, THEN PROMOTE.
#
# This used to overwrite the output and validate afterwards, so a build that
# failed its own gate still replaced the working artefact with a broken one -
# and the failure was only visible to whoever read the console. A technician
# who copied the file got the broken copy.
#
# UTF-8 WITH BOM. Windows PowerShell 5.1 misparses a BOM-less file the moment
# it contains a non-ASCII byte, and the failure looks like a syntax error in an
# unrelated place.
$tempPath = $OutputPath + '.building'
[IO.File]::WriteAllText($tempPath, $final, (New-Object System.Text.UTF8Encoding($true)))

# --- Verify what was produced, BEFORE it becomes the artefact ---------------
$buildFailed = $null
$parseErrors = $null
$null = [System.Management.Automation.Language.Parser]::ParseFile($tempPath, [ref]$null, [ref]$parseErrors)
if ($parseErrors) {
    $buildFailed = ('Generated file does not parse: line {0}: {1}' -f $parseErrors[0].Extent.StartLineNumber, $parseErrors[0].Message)
}

# The helpers are re-created from text inside every background runspace, so
# anything executing at top level would run once per worker.
if (-not $buildFailed) {
    $hErr = $null
    $hAst = [System.Management.Automation.Language.Parser]::ParseFile($helpersPath, [ref]$null, [ref]$hErr)
    if ($hErr) {
        $buildFailed = ('NetTool.Helpers.ps1 does not parse: line {0}: {1}' -f $hErr[0].Extent.StartLineNumber, $hErr[0].Message)
    } else {
        $impure = @($hAst.EndBlock.Statements | Where-Object { $_ -isnot [System.Management.Automation.Language.FunctionDefinitionAst] })
        if ($impure.Count -gt 0) {
            $buildFailed = ('NetTool.Helpers.ps1 is not pure - line {0} executes at load, and would run once per background runspace.' -f $impure[0].Extent.StartLineNumber)
        }
    }
}

# The whole point of the embed: it must be the CURRENT helper text, byte for
# byte. A prefix check would pass while a mid-file fix silently failed to ship.
if (-not $buildFailed) {
    $built = Get-Content -LiteralPath $tempPath -Raw
    $anchor = "`$script:HelpersText = @'"
    $ai = $built.IndexOf($anchor)
    if ($ai -lt 0) {
        $buildFailed = 'The embedded helper region is missing from the generated file.'
    } else {
        $bs = $built.IndexOf("`n", $ai) + 1
        $ce = $built.IndexOf("`n'@", $bs)
        $emb = $built.Substring($bs, $ce - $bs)
        $srcN = ($helpers -replace "`r`n", "`n").TrimEnd("`n")
        $embN = ($emb -replace "`r`n", "`n").TrimEnd("`n")
        if ($srcN -cne $embN) {
            $buildFailed = ('The embedded helpers do not match the source ({0} vs {1} chars).' -f $srcN.Length, $embN.Length)
        }
    }
}

if ($buildFailed) {
    Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
    Write-Output ('[FAIL] {0}' -f $buildFailed)
    Write-Output '[FAIL] The previous build was left untouched rather than replaced with a broken one.'
    exit 1
}

Move-Item -LiteralPath $tempPath -Destination $OutputPath -Force

$sizeKb = [math]::Round((Get-Item -LiteralPath $OutputPath).Length / 1KB)
$lines  = @(Get-Content -LiteralPath $OutputPath).Count
Write-Output ('[OK] {0}' -f $OutputPath)
Write-Output ('     {0} lines, {1} KB, parses clean under PowerShell {2}' -f $lines, $sizeKb, $PSVersionTable.PSVersion)
Write-Output ''
Write-Output 'Run it with:'
Write-Output ('  powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File "{0}"' -f (Split-Path -Leaf $OutputPath))
