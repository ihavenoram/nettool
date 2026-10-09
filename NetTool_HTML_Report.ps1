<#
.SYNOPSIS
    Renders a Network Toolkit report to a single self-contained HTML file.

.DESCRIPTION
    Render only. It measures nothing and changes nothing - dot-source it and
    call ConvertTo-NtHtmlReport, or run it directly against an exported JSON
    report. Keeping rendering separate from measurement is what stops the GUI
    and the report ever disagreeing about a finding.

    The output has no external references at all: no CDN, no web fonts, no
    images. It opens from a file share, from an email attachment, or from a
    ticket, on a machine with no internet.

.EXAMPLE
    .\NetTool_HTML_Report.ps1 -JsonPath .\NetToolkit_report.json -OutputPath .\report.html
#>

[CmdletBinding()]
param(
    [string]$JsonPath = '',
    [string]$OutputPath = '',
    [switch]$Open,
    # Suppress the picker window. Set automatically when this file is
    # dot-sourced; also available explicitly for any caller that wants the
    # functions and nothing else.
    [switch]$NoGui
)

function ConvertTo-NtHtmlEncoded {
    param([string]$Text)
    if ($null -eq $Text) { return '' }
    $out = [string]$Text
    $out = $out -replace '&', '&amp;'
    $out = $out -replace '<', '&lt;'
    $out = $out -replace '>', '&gt;'
    $out = $out -replace '"', '&quot;'
    return $out
}

function Get-NtReportCss {
    @'
:root{
  --bg:#f6f7f9; --panel:#ffffff; --ink:#181a20; --muted:#606674; --line:#e3e6ec;
  --ok:#127a3e; --okbg:#e8f6ed; --warn:#a8630a; --warnbg:#fdf4e3;
  --fail:#b2222a; --failbg:#fdebec; --info:#405280; --infobg:#eef2fa;
}
*{box-sizing:border-box}
body{margin:0;padding:24px;background:var(--bg);color:var(--ink);
  font:14px/1.5 "Segoe UI",system-ui,-apple-system,sans-serif}
.wrap{max-width:1180px;margin:0 auto}
h1{font-size:22px;margin:0 0 4px}
h2{font-size:16px;margin:28px 0 10px;padding-bottom:6px;border-bottom:2px solid var(--line)}
h3{font-size:13px;margin:18px 0 6px;color:var(--muted);text-transform:uppercase;letter-spacing:.04em}
.sub{color:var(--muted);margin:0 0 18px}
.card{background:var(--panel);border:1px solid var(--line);border-radius:8px;padding:16px;margin-bottom:14px}
.verdict{border-left:6px solid var(--info);background:var(--infobg)}
.verdict.critical,.verdict.high{border-left-color:var(--fail);background:var(--failbg)}
.verdict.medium{border-left-color:var(--warn);background:var(--warnbg)}
.verdict.ok,.verdict.info{border-left-color:var(--ok);background:var(--okbg)}
.verdict h1{font-size:19px}
.meta{display:flex;flex-wrap:wrap;gap:8px 28px;color:var(--muted);font-size:13px;margin-top:8px}
.meta b{color:var(--ink);font-weight:600}
table{width:100%;border-collapse:collapse;font-size:13px}
th{text-align:left;padding:8px 10px;background:#f0f2f6;border-bottom:1px solid var(--line);
  font-weight:600;white-space:nowrap}
td{padding:7px 10px;border-bottom:1px solid var(--line);vertical-align:top}
tr:last-child td{border-bottom:0}
.tablewrap{overflow-x:auto}
.pill{display:inline-block;padding:1px 8px;border-radius:10px;font-size:11px;font-weight:700;
  text-transform:uppercase;letter-spacing:.03em;white-space:nowrap}
.pill.ok{background:var(--okbg);color:var(--ok)}
.pill.warn{background:var(--warnbg);color:var(--warn)}
.pill.fail,.pill.critical,.pill.high{background:var(--failbg);color:var(--fail)}
.pill.medium{background:var(--warnbg);color:var(--warn)}
.pill.info,.pill.low,.pill.skipped{background:var(--infobg);color:var(--info)}
.finding{border-left:4px solid var(--line);padding:10px 14px;margin-bottom:12px;background:var(--panel)}
.finding.critical,.finding.high{border-left-color:var(--fail)}
.finding.medium{border-left-color:var(--warn)}
.finding.low,.finding.info{border-left-color:var(--info)}
.finding .ttl{font-weight:600;margin:0 0 4px}
.finding .act{margin-top:6px}
.finding .act b{color:var(--muted)}
.mono,pre{font-family:Consolas,"Cascadia Mono",monospace;font-size:12.5px}
pre{background:#f4f5f8;border:1px solid var(--line);border-radius:6px;padding:12px;
  overflow-x:auto;white-space:pre;margin:8px 0 0}
.cmd{background:#f4f5f8;border:1px solid var(--line);border-radius:4px;padding:4px 8px;
  margin:3px 0;font-family:Consolas,monospace;font-size:12.5px;overflow-x:auto}
.caveat{color:var(--muted);font-size:12.5px;margin-top:8px;padding-left:14px;border-left:3px solid var(--line)}
.method{color:var(--muted);font-size:12.5px;margin:0 0 10px}
.empty{color:var(--muted);font-style:italic}
footer{color:var(--muted);font-size:12px;margin-top:28px;text-align:center}
@media print{body{background:#fff;padding:0}.card{break-inside:avoid}}
'@
}

function ConvertTo-NtPill {
    param([string]$Value)
    $cls = ($Value -replace '[^a-z]', '').ToLower()
    if (-not $cls) { $cls = 'info' }
    ('<span class="pill {0}">{1}</span>' -f $cls, (ConvertTo-NtHtmlEncoded $Value))
}

function ConvertTo-NtHtmlReport {
    param($Report)

    $sb = [System.Text.StringBuilder]::new()
    $w = { param([string]$Text) [void]$sb.AppendLine($Text) }

    $verdict = $Report.verdict
    $level = if ($verdict) { [string]$verdict.level } else { 'info' }

    & $w '<!doctype html><html lang="en"><head><meta charset="utf-8">'
    & $w ('<title>Network Toolkit - {0}</title>' -f (ConvertTo-NtHtmlEncoded $Report.target))
    & $w '<meta name="viewport" content="width=device-width,initial-scale=1">'
    & $w ('<style>{0}</style>' -f (Get-NtReportCss))
    & $w '</head><body><div class="wrap">'

    # ---- Verdict ----------------------------------------------------------
    # A device check leads with the device's status, as the GUI does - "is it
    # there" is the question that was asked - and the top finding follows.
    # Older reports, and cancelled runs, have no device card and keep the
    # finding-based verdict.
    $dev = $null
    if ($Report.PSObject.Properties['device'] -and $Report.device -and [string]$Report.runState -ne 'cancelled') { $dev = $Report.device }
    if ($dev) {
        $level = switch ([string]$dev.Level) { 'high' { 'high' } 'medium' { 'medium' } 'low' { 'medium' } 'ok' { 'ok' } default { 'info' } }
    }
    & $w ('<div class="card verdict {0}">' -f $level)
    if ($dev) {
        & $w ('<h1>{0}</h1>' -f (ConvertTo-NtHtmlEncoded ([string]$dev.Headline)))
        & $w ('<p class="sub">{0}</p>' -f (ConvertTo-NtHtmlEncoded ([string]$dev.Detail)))
        if ($verdict -and $verdict.headline -and $verdict.headline -ne 'No findings.') {
            & $w ('<p class="sub">Top finding: {0}</p>' -f (ConvertTo-NtHtmlEncoded $verdict.headline))
        }
    } else {
        & $w ('<h1>{0}</h1>' -f (ConvertTo-NtHtmlEncoded $(if ($verdict) { $verdict.headline } else { 'Network Toolkit report' })))
    }
    if ($verdict -and $verdict.firstFailure) {
        & $w ('<p class="sub">First failure: {0}</p>' -f (ConvertTo-NtHtmlEncoded $verdict.firstFailure))
    }
    & $w '<div class="meta">'
    & $w ('<span><b>Target</b> {0}</span>' -f (ConvertTo-NtHtmlEncoded $Report.target))
    if ($Report.peer) {
        $nbHow = ''
        if ($Report.PSObject.Properties['neighbour'] -and $Report.neighbour -and [string]$Report.neighbour.How -in @('inventory', 'probe')) { $nbHow = ' (found automatically)' }
        & $w ('<span><b>Neighbour</b> {0}{1}</span>' -f (ConvertTo-NtHtmlEncoded $Report.peer), $nbHow)
    }
    if ($Report.site) { & $w ('<span><b>Site</b> {0}</span>' -f (ConvertTo-NtHtmlEncoded $Report.site)) }
    & $w ('<span><b>Tested from</b> {0}</span>' -f (ConvertTo-NtHtmlEncoded $Report.computerName))
    & $w ('<span><b>When</b> {0}</span>' -f (ConvertTo-NtHtmlEncoded $Report.generatedUtc))
    & $w ('<span><b>Elevated</b> {0}</span>' -f $(if ($Report.elevated) { 'yes' } else { 'no' }))
    & $w '</div></div>'

    # ---- Findings ---------------------------------------------------------
    & $w '<h2>Conclusions</h2>'
    $findings = @($Report.findings)
    if ($findings.Count -eq 0) {
        & $w '<div class="card"><p class="empty">No findings were produced.</p></div>'
    } else {
        & $w '<div class="card">'
        foreach ($finding in $findings) {
            & $w ('<div class="finding {0}">' -f ([string]$finding.severity))
            & $w ('<p class="ttl">{0} {1}</p>' -f (ConvertTo-NtPill $finding.severity), (ConvertTo-NtHtmlEncoded $finding.title))
            & $w ('<div>{0}</div>' -f (ConvertTo-NtHtmlEncoded $finding.summary))
            if ($finding.action) {
                & $w ('<div class="act"><b>Action:</b> {0}</div>' -f (ConvertTo-NtHtmlEncoded $finding.action))
            }
            foreach ($cmd in @($finding.commands)) {
                & $w ('<div class="cmd">{0}</div>' -f (ConvertTo-NtHtmlEncoded $cmd))
            }
            & $w ('<div class="caveat">Evidence: {0} &middot; Confidence: {1}</div>' -f (ConvertTo-NtHtmlEncoded ((@($finding.evidence)) -join ', ')), (ConvertTo-NtHtmlEncoded $finding.confidence))
            & $w '</div>'
        }
        & $w '</div>'
    }

    # ---- Ladder -----------------------------------------------------------
    $ladder = @($Report.ladder)
    if ($ladder.Count -gt 0) {
        & $w '<h2>Triage ladder</h2><div class="card"><div class="tablewrap"><table>'
        & $w '<tr><th>Rung</th><th>Check</th><th>Status</th><th>Result</th><th>Notes</th></tr>'
        foreach ($rung in $ladder) {
            & $w ('<tr><td>{0}</td><td>{1}</td><td>{2}</td><td>{3}</td><td>{4}</td></tr>' -f `
                $rung.number,
                (ConvertTo-NtHtmlEncoded $rung.name),
                (ConvertTo-NtPill $rung.status),
                (ConvertTo-NtHtmlEncoded $rung.result),
                (ConvertTo-NtHtmlEncoded $rung.detail))
        }
        & $w '</table></div></div>'
    }

    # ---- Sections ---------------------------------------------------------
    foreach ($section in @($Report.sections)) {
        & $w ('<h2>{0}</h2>' -f (ConvertTo-NtHtmlEncoded $section.name))
        & $w '<div class="card">'
        if ($section.state -ne 'measured') {
            & $w ('<p>{0} {1}</p>' -f (ConvertTo-NtPill $section.state), (ConvertTo-NtHtmlEncoded $section.reason))
        }
        if ($section.method) {
            & $w ('<p class="method">Method: {0}</p>' -f (ConvertTo-NtHtmlEncoded $section.method))
        }
        $rows = @($section.rows)
        if ($rows.Count -gt 0) {
            & $w '<div class="tablewrap"><table><tr><th>Check</th><th>Status</th><th>Result</th><th>Detail</th></tr>'
            foreach ($row in $rows) {
                & $w ('<tr><td>{0}</td><td>{1}</td><td>{2}</td><td>{3}</td></tr>' -f `
                    (ConvertTo-NtHtmlEncoded $row.check),
                    (ConvertTo-NtPill $row.status),
                    (ConvertTo-NtHtmlEncoded $row.result),
                    (ConvertTo-NtHtmlEncoded $row.detail))
            }
            & $w '</table></div>'
        } elseif ($section.state -eq 'measured') {
            & $w '<p class="empty">Nothing to report.</p>'
        }
        foreach ($caveat in @($section.caveats)) {
            & $w ('<p class="caveat">{0}</p>' -f (ConvertTo-NtHtmlEncoded $caveat))
        }
        & $w '</div>'
    }

    # ---- Escalation -------------------------------------------------------
    $escalation = ''
    if (Get-Command -Name New-NtEscalationSummary -ErrorAction SilentlyContinue) {
        try { $escalation = New-NtEscalationSummary -Report $Report } catch { $escalation = '' }
    }
    if ($escalation) {
        & $w '<h2>Escalation summary</h2><div class="card">'
        & $w '<p class="method">Paste-ready. Leads with what is proven working, so it pre-empts the reflexive "must be your network".</p>'
        & $w ('<pre>{0}</pre>' -f (ConvertTo-NtHtmlEncoded $escalation))
        & $w '</div>'
    }

    & $w ('<footer>Generated by NetToolkit {0} on {1}. Read-only diagnostic - nothing in this report changed the machine.</footer>' -f `
        (ConvertTo-NtHtmlEncoded $Report.version), (ConvertTo-NtHtmlEncoded $Report.generatedUtc))
    & $w '</div></body></html>'

    return $sb.ToString()
}

# Run directly against an exported JSON report.
if ($JsonPath) {
    $scriptDir = $PSScriptRoot
    if (-not $scriptDir) { $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path }
    $helpers = Join-Path $scriptDir 'NetTool.Helpers.ps1'
    if (Test-Path -LiteralPath $helpers) { . $helpers }

    if (-not (Test-Path -LiteralPath $JsonPath)) { throw ('Report not found: {0}' -f $JsonPath) }
    # PS 5.1: assign first, then wrap. @(... | ConvertFrom-Json) collapses arrays.
    $raw = Get-Content -LiteralPath $JsonPath -Raw
    $report = $raw | ConvertFrom-Json

    if (-not $OutputPath) { $OutputPath = [IO.Path]::ChangeExtension($JsonPath, '.html') }
    $html = ConvertTo-NtHtmlReport -Report $report
    Set-Content -LiteralPath $OutputPath -Value $html -Encoding UTF8
    Write-Output ('[OK] Wrote {0}' -f $OutputPath)
    if ($Open) { Start-Process $OutputPath }
    return
}

# =============================================================================
# No arguments: show the picker
# =============================================================================
# Run with -JsonPath and this file stays exactly as headless as it was. Run it
# with nothing and you get a window to pick a saved report from, which is the
# workflow that actually happens: export the JSON on site, render and read it
# back at the desk.
#
# Skipped when the file is DOT-SOURCED. NetTool-Gui.ps1 loads this script to get
# ConvertTo-NtHtmlReport for its own Export HTML button, and a file picker
# appearing out of nowhere at that moment would be a nasty surprise.
if ($NoGui) { return }
if ($MyInvocation.InvocationName -eq '.') { return }

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

if ([Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
    Write-Warning 'Not running in a single-threaded apartment. Re-launch with -STA if the window misbehaves.'
}

$reportScriptDir = $PSScriptRoot
if (-not $reportScriptDir) { $reportScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $reportScriptDir) { $reportScriptDir = (Get-Location).Path }
$reportHelpers = Join-Path $reportScriptDir 'NetTool.Helpers.ps1'
if (Test-Path -LiteralPath $reportHelpers) { . $reportHelpers }

$RpColorBg    = [System.Drawing.Color]::FromArgb(250, 250, 252)
$RpColorPanel = [System.Drawing.Color]::FromArgb(255, 255, 255)
$RpColorMuted = [System.Drawing.Color]::FromArgb(96, 102, 116)
$RpColorOk    = [System.Drawing.Color]::FromArgb(18, 122, 62)
$RpColorFail  = [System.Drawing.Color]::FromArgb(178, 34, 42)
$RpFontUi     = New-Object System.Drawing.Font('Segoe UI', 9)
$RpFontBold   = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
$RpFontMono   = New-Object System.Drawing.Font('Consolas', 9)

$script:LoadedReport = $null

$rpForm = New-Object System.Windows.Forms.Form
$rpForm.Text = 'Network Toolkit - HTML report'
$rpForm.Size = New-Object System.Drawing.Size(680, 400)
$rpForm.MinimumSize = New-Object System.Drawing.Size(560, 360)
$rpForm.StartPosition = 'CenterScreen'
$rpForm.BackColor = $RpColorBg
$rpForm.Font = $RpFontUi
$rpForm.AllowDrop = $true

function New-RpLabel {
    param([string]$Text, [int]$X, [int]$Y, [int]$Width, $Colour = $null, $Font = $null)
    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text = $Text
    $lbl.Location = New-Object System.Drawing.Point($X, $Y)
    $lbl.Size = New-Object System.Drawing.Size($Width, 18)
    $lbl.ForeColor = $(if ($Colour) { $Colour } else { $RpColorMuted })
    $lbl.Font = $(if ($Font) { $Font } else { $RpFontUi })
    return $lbl
}

$rpForm.Controls.Add((New-RpLabel -Text 'Report JSON (exported from the toolkit)' -X 14 -Y 12 -Width 400))
$txtJson = New-Object System.Windows.Forms.TextBox
$txtJson.Location = New-Object System.Drawing.Point(14, 32)
$txtJson.Size = New-Object System.Drawing.Size(540, 24)
$txtJson.Font = $RpFontMono
$rpForm.Controls.Add($txtJson)

$btnBrowseJson = New-Object System.Windows.Forms.Button
$btnBrowseJson.Text = 'Browse'
$btnBrowseJson.Location = New-Object System.Drawing.Point(562, 30)
$btnBrowseJson.Size = New-Object System.Drawing.Size(90, 27)
$rpForm.Controls.Add($btnBrowseJson)

$rpForm.Controls.Add((New-RpLabel -Text 'Output HTML' -X 14 -Y 66 -Width 300))
$txtHtml = New-Object System.Windows.Forms.TextBox
$txtHtml.Location = New-Object System.Drawing.Point(14, 86)
$txtHtml.Size = New-Object System.Drawing.Size(540, 24)
$txtHtml.Font = $RpFontMono
$rpForm.Controls.Add($txtHtml)

$btnBrowseHtml = New-Object System.Windows.Forms.Button
$btnBrowseHtml.Text = 'Save as'
$btnBrowseHtml.Location = New-Object System.Drawing.Point(562, 84)
$btnBrowseHtml.Size = New-Object System.Drawing.Size(90, 27)
$rpForm.Controls.Add($btnBrowseHtml)

# What did I just load? Rendering the wrong capture and not noticing is the
# easiest mistake to make here, so the file is summarised before it is rendered.
$panelSummary = New-Object System.Windows.Forms.Panel
$panelSummary.Location = New-Object System.Drawing.Point(14, 122)
$panelSummary.Size = New-Object System.Drawing.Size(638, 150)
$panelSummary.BackColor = $RpColorPanel
$panelSummary.BorderStyle = 'FixedSingle'
$rpForm.Controls.Add($panelSummary)

$lblSummaryHead = New-RpLabel -Text 'No report loaded' -X 12 -Y 10 -Width 610 -Colour $RpColorMuted -Font $RpFontBold
$panelSummary.Controls.Add($lblSummaryHead)

$lblSummaryBody = New-Object System.Windows.Forms.Label
$lblSummaryBody.Location = New-Object System.Drawing.Point(12, 34)
$lblSummaryBody.Size = New-Object System.Drawing.Size(610, 104)
$lblSummaryBody.ForeColor = $RpColorMuted
$lblSummaryBody.Text = "Pick a NetToolkit JSON export, or drag one onto this window." + [Environment]::NewLine + [Environment]::NewLine + "The GUI's Export JSON button writes these; so does Export HTML's companion."
$panelSummary.Controls.Add($lblSummaryBody)

$chkOpen = New-Object System.Windows.Forms.CheckBox
$chkOpen.Text = 'Open the report when it is written'
$chkOpen.Location = New-Object System.Drawing.Point(14, 284)
$chkOpen.Size = New-Object System.Drawing.Size(260, 24)
$chkOpen.Checked = $true
$rpForm.Controls.Add($chkOpen)

$btnRender = New-Object System.Windows.Forms.Button
$btnRender.Text = 'Render HTML'
$btnRender.Location = New-Object System.Drawing.Point(452, 281)
$btnRender.Size = New-Object System.Drawing.Size(110, 30)
$btnRender.Font = $RpFontBold
$btnRender.Enabled = $false
$rpForm.Controls.Add($btnRender)

$btnClose = New-Object System.Windows.Forms.Button
$btnClose.Text = 'Close'
$btnClose.Location = New-Object System.Drawing.Point(570, 281)
$btnClose.Size = New-Object System.Drawing.Size(82, 30)
$rpForm.Controls.Add($btnClose)

$lblRpStatus = New-RpLabel -Text 'Ready.' -X 14 -Y 322 -Width 638
$rpForm.Controls.Add($lblRpStatus)

function Import-RpReport {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        $lblRpStatus.ForeColor = $RpColorFail
        $lblRpStatus.Text = 'That file does not exist.'
        return
    }
    try {
        # PS 5.1: assign, then use. Wrapping ConvertFrom-Json in @() collapses arrays.
        $raw = Get-Content -LiteralPath $Path -Raw
        $obj = $raw | ConvertFrom-Json
    } catch {
        $script:LoadedReport = $null
        $btnRender.Enabled = $false
        $lblSummaryHead.ForeColor = $RpColorFail
        $lblSummaryHead.Text = 'Not valid JSON'
        $lblSummaryBody.Text = $_.Exception.Message
        return
    }

    $schema = ''
    try { $schema = [string]$obj.schema } catch {}
    if ($schema -ne 'nettoolkit-report/1') {
        # A sweep export or an inventory file will not render - say so plainly
        # rather than producing an empty page.
        $script:LoadedReport = $null
        $btnRender.Enabled = $false
        $lblSummaryHead.ForeColor = $RpColorFail
        $lblSummaryHead.Text = 'Not a triage report'
        $lblSummaryBody.Text = ("This file's schema is '{0}'." -f $(if ($schema) { $schema } else { 'unknown' })) +
            [Environment]::NewLine + [Environment]::NewLine +
            'The HTML report renders a TRIAGE report (schema nettoolkit-report/1), which is what Export JSON writes after Check device. Sweep results and the IP/MAC inventory are different shapes and are not rendered here.'
        return
    }

    $script:LoadedReport = $obj
    $btnRender.Enabled = $true

    $level = ''; $headline = ''
    try { $level = [string]$obj.verdict.level; $headline = [string]$obj.verdict.headline } catch {}
    $lblSummaryHead.ForeColor = $(if ($level -in @('critical','high')) { $RpColorFail } elseif ($level) { $RpColorOk } else { $RpColorMuted })
    $lblSummaryHead.Text = $(if ($headline) { ('[{0}] {1}' -f $level.ToUpper(), $headline) } else { 'Report loaded' })

    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add(('Target      : {0}' -f $obj.target))
    if ($obj.peer) { $lines.Add(('Peer        : {0}' -f $obj.peer)) }
    if ($obj.site) { $lines.Add(('Site        : {0}' -f $obj.site)) }
    $lines.Add(('Tested from : {0}' -f $obj.computerName))
    $lines.Add(('Generated   : {0}' -f $obj.generatedUtc))
    $lines.Add(('Contents    : {0} sections, {1} findings' -f @($obj.sections).Count, @($obj.findings).Count))
    $lblSummaryBody.Text = ($lines -join [Environment]::NewLine)

    if (-not $txtHtml.Text) { $txtHtml.Text = [IO.Path]::ChangeExtension($Path, '.html') }
    $lblRpStatus.ForeColor = $RpColorMuted
    $lblRpStatus.Text = 'Report loaded. Choose an output path and render.'
}

$btnBrowseJson.Add_Click({
    $dialog = New-Object System.Windows.Forms.OpenFileDialog
    $dialog.Filter = 'NetToolkit JSON (*.json)|*.json|All files (*.*)|*.*'
    $dialog.Title = 'Pick an exported report'
    if ($txtJson.Text -and (Test-Path -LiteralPath (Split-Path -Parent $txtJson.Text))) {
        $dialog.InitialDirectory = Split-Path -Parent $txtJson.Text
    }
    if ($dialog.ShowDialog() -ne 'OK') { return }
    $txtJson.Text = $dialog.FileName
    $txtHtml.Text = ''
    Import-RpReport -Path $dialog.FileName
})

$btnBrowseHtml.Add_Click({
    $dialog = New-Object System.Windows.Forms.SaveFileDialog
    $dialog.Filter = 'HTML (*.html)|*.html'
    if ($txtHtml.Text) { $dialog.FileName = Split-Path -Leaf $txtHtml.Text }
    if ($dialog.ShowDialog() -eq 'OK') { $txtHtml.Text = $dialog.FileName }
})

# Typing or pasting a path counts as picking one.
$txtJson.Add_Leave({
    $typed = $txtJson.Text.Trim('"').Trim()
    if ($typed -and $typed -ne $script:LastLoaded) {
        $script:LastLoaded = $typed
        Import-RpReport -Path $typed
    }
})

# Drag a .json onto the window.
$rpForm.Add_DragEnter({
    param($sender, $eventArgs)
    if ($eventArgs.Data.GetDataPresent([System.Windows.Forms.DataFormats]::FileDrop)) {
        $eventArgs.Effect = [System.Windows.Forms.DragDropEffects]::Copy
    }
})
$rpForm.Add_DragDrop({
    param($sender, $eventArgs)
    $dropped = @($eventArgs.Data.GetData([System.Windows.Forms.DataFormats]::FileDrop))
    if ($dropped.Count -eq 0) { return }
    $txtJson.Text = [string]$dropped[0]
    $txtHtml.Text = ''
    Import-RpReport -Path ([string]$dropped[0])
})

$btnRender.Add_Click({
    if (-not $script:LoadedReport) { return }
    $target = $txtHtml.Text.Trim()
    if (-not $target) {
        $target = [IO.Path]::ChangeExtension($txtJson.Text.Trim(), '.html')
        $txtHtml.Text = $target
    }
    try {
        $lblRpStatus.ForeColor = $RpColorMuted
        $lblRpStatus.Text = 'Rendering...'
        $rpForm.Refresh()
        $rendered = ConvertTo-NtHtmlReport -Report $script:LoadedReport
        Set-Content -LiteralPath $target -Value $rendered -Encoding UTF8
        $sizeKb = [math]::Round((Get-Item -LiteralPath $target).Length / 1KB, 1)
        $lblRpStatus.ForeColor = $RpColorOk
        $lblRpStatus.Text = ('Wrote {0} ({1} KB).' -f $target, $sizeKb)
        if ($chkOpen.Checked) { Start-Process $target }
    } catch {
        $lblRpStatus.ForeColor = $RpColorFail
        $lblRpStatus.Text = ('Render failed: {0}' -f $_.Exception.Message)
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Network Toolkit', 'OK', 'Error') | Out-Null
    }
})

$btnClose.Add_Click({ $rpForm.Close() })

# Anchors in Shown, never at construction: a control anchored before the form
# has laid itself out keeps the wrong margins for the rest of its life.
$rpForm.Add_Shown({
    $txtJson.Anchor       = 'Top,Left,Right'
    $txtHtml.Anchor       = 'Top,Left,Right'
    $btnBrowseJson.Anchor = 'Top,Right'
    $btnBrowseHtml.Anchor = 'Top,Right'
    $panelSummary.Anchor  = 'Top,Left,Right,Bottom'
    $lblSummaryHead.Anchor= 'Top,Left,Right'
    $lblSummaryBody.Anchor= 'Top,Left,Right,Bottom'
    $chkOpen.Anchor       = 'Bottom,Left'
    $btnRender.Anchor     = 'Bottom,Right'
    $btnClose.Anchor      = 'Bottom,Right'
    $lblRpStatus.Anchor   = 'Bottom,Left,Right'
    $txtJson.Focus()
})

[void]$rpForm.ShowDialog()
$rpForm.Dispose()
