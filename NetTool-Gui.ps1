<#
.SYNOPSIS
    Network Toolkit - technician GUI.

.DESCRIPTION
    Windows Forms front end for NetTool.Helpers.ps1. Point it at a target IP,
    hostname, or range and it walks the triage ladder, audits routes, reads the
    hosts file and ARP table, inventories the gateway, traces the path, and
    writes what it finds into a JSON inventory for later cross-matching.

    Read-only unless you use the Fix button, which confirms every action.

.NOTES
    Windows PowerShell 5.1. MUST run -STA; use Launch-NetTool.cmd.
    Designed for an interactive or ScreenConnect Backstage session. Under
    SYSTEM with no desktop there is nothing for it to draw on.
#>

[CmdletBinding()]
param(
    [string]$Target = '',
    [string]$Peer = '',
    [string]$Site = '',
    [switch]$NoHideConsole,
    [switch]$NoMaximize,
    [switch]$AllowFix
)

# $PSScriptRoot is empty inside param defaults when [CmdletBinding()] is used,
# so script-relative paths are resolved here in the body instead.
$scriptDir = $PSScriptRoot
if (-not $scriptDir) { $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $scriptDir) { $scriptDir = (Get-Location).Path }

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'

# --- WinForms first ---------------------------------------------------------
# Loaded BEFORE anything else that might need to report a problem. The error
# path below used to call MessageBox while these assemblies were still
# unloaded, so a missing helpers file produced "Unable to find type
# [System.Windows.Forms.MessageBox]" - the error handler failing instead of the
# error being reported.
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

function Show-NtStartupError {
    # Console AND dialog. On Server Core, or wherever WinForms will not load,
    # the console line is the only thing that will come out.
    #
    # Write-Error is TERMINATING here: $ErrorActionPreference is 'Stop' at this
    # point in the script, so the very first line used to abort the function
    # before the dialog it exists to show. A technician in Backstage, where the
    # console is not visible, saw the tool die silently. Write-Host cannot
    # terminate, so the dialog is now always reached.
    param([string]$Message)
    Write-Host ('[ERROR] ' + $Message) -ForegroundColor Red
    try {
        [System.Windows.Forms.MessageBox]::Show($Message, 'Network Toolkit', 'OK', 'Error') | Out-Null
    } catch {
        # WinForms unavailable. The console line above is then the only report,
        # which is exactly why it is written first and unconditionally.
    }
}

# --- Load the helpers, twice over ------------------------------------------
# Once into this session for the UI thread, and once kept as TEXT so each
# background runspace can rebuild the same definitions. Runspaces do not inherit
# the caller's function table.
$helpersPath = Join-Path $scriptDir 'NetTool.Helpers.ps1'
if (-not (Test-Path -LiteralPath $helpersPath)) {
    Show-NtStartupError ("NetTool.Helpers.ps1 was not found beside this script.`n`nExpected: {0}`n`nThis GUI needs NetTool.Helpers.ps1 in the same folder. Copy the whole toolkit folder, or use the single-file build (Build-NetToolSingleFile.ps1) if you only want one file to carry around." -f $helpersPath)
    exit 1
}
$script:HelpersText = Get-Content -LiteralPath $helpersPath -Raw
. $helpersPath
Set-NtProjectDir -Path $scriptDir

# --- Hide our own console window -------------------------------------------
# Deliberately NOT done with -WindowStyle Hidden on the launcher: that hides the
# FORM as well as the console, and the failure looks like the tool never started.
if (-not $NoHideConsole) {
    try {
        Add-Type -Namespace NtWin -Name Native -MemberDefinition @'
[DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
[DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
'@ -ErrorAction Stop
        $consoleHandle = [NtWin.Native]::GetConsoleWindow()
        if ($consoleHandle -ne [IntPtr]::Zero) { [void][NtWin.Native]::ShowWindow($consoleHandle, 0) }
    } catch { }
}

# --- Palette ----------------------------------------------------------------
# Named deliberately verbosely. Single-letter names get clobbered by any
# "foreach ($x in ...)" later in the file, and the result still launches, which
# makes it a genuinely nasty bug to find.
$NtColorBg       = [System.Drawing.Color]::FromArgb(250, 250, 252)
$NtColorPanel    = [System.Drawing.Color]::FromArgb(255, 255, 255)
$NtColorText     = [System.Drawing.Color]::FromArgb(24, 26, 32)
$NtColorMuted    = [System.Drawing.Color]::FromArgb(96, 102, 116)
$NtColorOk       = [System.Drawing.Color]::FromArgb(18, 122, 62)
$NtColorWarn     = [System.Drawing.Color]::FromArgb(176, 104, 8)
$NtColorFail     = [System.Drawing.Color]::FromArgb(178, 34, 42)
$NtColorInfo     = [System.Drawing.Color]::FromArgb(64, 82, 128)
$NtColorOkBg     = [System.Drawing.Color]::FromArgb(232, 246, 237)
$NtColorWarnBg   = [System.Drawing.Color]::FromArgb(253, 244, 227)
$NtColorFailBg   = [System.Drawing.Color]::FromArgb(253, 235, 236)
$NtColorInfoBg   = [System.Drawing.Color]::FromArgb(238, 242, 250)

$NtFontUi    = New-Object System.Drawing.Font('Segoe UI', 9)
$NtFontBold  = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
$NtFontHead  = New-Object System.Drawing.Font('Segoe UI', 12, [System.Drawing.FontStyle]::Bold)
$NtFontMono  = New-Object System.Drawing.Font('Consolas', 9)

function Get-NtStatusColor {
    param([string]$Status)
    switch ($Status) {
        'ok'      { return $NtColorOk }
        'warn'    { return $NtColorWarn }
        'fail'    { return $NtColorFail }
        'skipped' { return $NtColorMuted }
        default   { return $NtColorInfo }
    }
}
function Get-NtSeverityColor {
    param([string]$Severity)
    switch ($Severity) {
        'critical' { return $NtColorFail }
        'high'     { return $NtColorFail }
        'medium'   { return $NtColorWarn }
        'low'      { return $NtColorInfo }
        default    { return $NtColorMuted }
    }
}

# --- Shared state between the UI thread and the worker ----------------------
$script:Sync = [hashtable]::Synchronized(@{
    Running  = $false
    Cancel   = $false
    Status   = 'Ready.'
    Progress = 0
    Result   = $null
    Error    = ''
    Kind     = ''
})
$script:Worker      = $null
$script:WorkerAsync = $null
$script:Report      = $null
# WHICH run the user is currently looking at. Export used to prefer
# $script:Report unconditionally, so running a triage and then a sweep and
# pressing Export gave you the TRIAGE - a file named for one investigation
# containing another, which is the kind of thing that reaches a vendor.
$script:LastRunKind = ''
$script:LastRunAt   = $null
$script:SweepResult = $null
$script:Inventory   = $null
$script:SnapshotA   = $null
$script:AbComparison = $null

# =============================================================================
# Form
# =============================================================================
$form = New-Object System.Windows.Forms.Form
$form.Text = 'Network Toolkit'
$form.Size = New-Object System.Drawing.Size(1180, 780)
$form.MinimumSize = New-Object System.Drawing.Size(820, 560)
$form.StartPosition = 'CenterScreen'
# NOTE: the window is maximised at the END of Add_Shown, not here. Anchors
# capture their margins at the moment they are assigned, so maximising first
# would have Add_Shown record the margins of an already-full-width form - and
# every panel would then keep a ~780px gap on its right forever, leaving the
# whole UI squeezed into the left third of the screen.
$form.BackColor = $NtColorBg
$form.Font = $NtFontUi

# ---- Input strip -----------------------------------------------------------
$panelTop = New-Object System.Windows.Forms.Panel
$panelTop.Location = New-Object System.Drawing.Point(12, 10)
$panelTop.Size = New-Object System.Drawing.Size(1140, 84)
$panelTop.BackColor = $NtColorPanel
$form.Controls.Add($panelTop)

function New-NtLabel {
    param([string]$Text, [int]$X, [int]$Y, [int]$Width = 70)
    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text = $Text
    $lbl.Location = New-Object System.Drawing.Point($X, $Y)
    $lbl.Size = New-Object System.Drawing.Size($Width, 18)
    $lbl.ForeColor = $NtColorMuted
    $lbl.Font = $NtFontUi
    return $lbl
}

$panelTop.Controls.Add((New-NtLabel -Text 'Target' -X 12 -Y 10))
$txtTarget = New-Object System.Windows.Forms.TextBox
$txtTarget.Location = New-Object System.Drawing.Point(12, 30)
$txtTarget.Size = New-Object System.Drawing.Size(170, 24)
$txtTarget.Font = $NtFontMono
$txtTarget.Text = $Target
$panelTop.Controls.Add($txtTarget)

$lblPeer = New-NtLabel -Text 'Neighbour (auto)' -X 190 -Y 10 -Width 130
$panelTop.Controls.Add($lblPeer)
$txtPeer = New-Object System.Windows.Forms.TextBox
$txtPeer.Location = New-Object System.Drawing.Point(190, 30)
$txtPeer.Size = New-Object System.Drawing.Size(130, 24)
$txtPeer.Font = $NtFontMono
$txtPeer.Text = $Peer
$panelTop.Controls.Add($txtPeer)

# Nobody could be expected to guess what "peer" meant from a text box - the
# first real user asked. The tool now finds one itself; the box is only for
# overriding its choice.
$NtTips = New-Object System.Windows.Forms.ToolTip
$NtTips.AutoPopDelay = 20000
$NtTips.InitialDelay = 400
$NtTips.ReshowDelay  = 200
$NtTips.ShowAlways   = $true

$peerTip = @'
Leave blank - the tool finds one automatically.

A neighbour is another machine on the target's network that answers. It is a
control test:
  neighbour answers, target does not  ->  the path is fine, the fault is that one device
  neither answers                     ->  the path itself is broken

Not needed when the target is on this PC's own subnet. When it is not, the
tool tries the site profile, then addresses the inventory has seen near the
target, then up to 16 likely addresses - and the Device tab says which it used.
Type an address here only to use a machine you KNOW should be working.
'@
$NtTips.SetToolTip($txtPeer, $peerTip)
$NtTips.SetToolTip($lblPeer, $peerTip)

$panelTop.Controls.Add((New-NtLabel -Text 'Ports' -X 328 -Y 10 -Width 120))
$txtPorts = New-Object System.Windows.Forms.TextBox
$txtPorts.Location = New-Object System.Drawing.Point(328, 30)
$txtPorts.Size = New-Object System.Drawing.Size(110, 24)
$txtPorts.Font = $NtFontMono
$txtPorts.Text = '443,445,3389,4433,4443,4444'
$panelTop.Controls.Add($txtPorts)

$panelTop.Controls.Add((New-NtLabel -Text 'Site profile' -X 446 -Y 10 -Width 130))
$cboProfile = New-Object System.Windows.Forms.ComboBox
$cboProfile.Location = New-Object System.Drawing.Point(446, 30)
$cboProfile.Size = New-Object System.Drawing.Size(140, 24)
$cboProfile.DropDownStyle = 'DropDownList'
$panelTop.Controls.Add($cboProfile)

$NtTips.SetToolTip($txtTarget, @'
The device to check: a NAME (RECEPTION-PC02), an IP address, or a MAC address
(aa-bb-cc-dd-ee-ff). The name is asked of DNS AND of the device itself, so a PC
that ignores ping - or one stuck on a 169.254 address - is still found.

For Sweep: a range (10.60.100.1-50) or a CIDR (10.60.100.0/24).

Use a real HOST address, not a network address. In a /24 an address ending .0
is the network itself and never answers - but that depends on the mask: in a
/23, 10.1.1.0 is a perfectly ordinary host.
'@)

$NtTips.SetToolTip($txtPorts, @'
TCP ports to test on the target. Comma separated; the box scrolls.

Use the port the application actually uses. If none of them answer, the tool
sweeps the common service ports anyway and tells you what the host IS serving.
'@)

$NtTips.SetToolTip($cboProfile, @'
A saved per-site file (profiles\*.json) holding the LAN subnets, the transport
next hop, known NAT translations, and the targets with their neighbours.

Selecting one fills in the target, peer and ports for you, and lets the
conclusions name the address a far-end server needs a return route for.
A profile matching this machine's subnet is selected automatically.
'@)

$btnTriage = New-Object System.Windows.Forms.Button
$btnTriage.Text = 'Check device'
$btnTriage.Location = New-Object System.Drawing.Point(830, 28)
$btnTriage.Size = New-Object System.Drawing.Size(100, 28)
$btnTriage.Font = $NtFontBold
$panelTop.Controls.Add($btnTriage)

$btnSweep = New-Object System.Windows.Forms.Button
$btnSweep.Text = 'Sweep'
$btnSweep.Location = New-Object System.Drawing.Point(936, 28)
$btnSweep.Size = New-Object System.Drawing.Size(66, 28)
$panelTop.Controls.Add($btnSweep)

$btnRoutes = New-Object System.Windows.Forms.Button
$btnRoutes.Text = 'Routes'
$btnRoutes.Location = New-Object System.Drawing.Point(1008, 28)
$btnRoutes.Size = New-Object System.Drawing.Size(66, 28)
$panelTop.Controls.Add($btnRoutes)

$btnCancel = New-Object System.Windows.Forms.Button
$btnCancel.Text = 'Cancel'
$btnCancel.Location = New-Object System.Drawing.Point(1080, 28)
$btnCancel.Size = New-Object System.Drawing.Size(52, 28)

function Set-NtButtonRow {
    # Pack the action buttons from the RIGHT EDGE outwards, measured at runtime.
    #
    # Fixed coordinates plus an anchor is not good enough here: at display
    # scaling above 100% WinForms widens each button, the extra width
    # accumulates left to right, and the last button ends up past the edge of
    # the panel where it cannot be clicked. Measuring from the right instead
    # means the rightmost button is always fully visible, at any DPI and any
    # window width. Re-run on every resize.
    $gap   = 6
    $right = $panelTop.ClientSize.Width - 8
    foreach ($button in @($btnCancel, $btnRoutes, $btnSweep, $btnTriage)) {
        $right -= $button.Width
        $button.Left = $right
        $right -= $gap
    }
}
$btnCancel.Enabled = $false
$panelTop.Controls.Add($btnCancel)

# ---- Verdict banner --------------------------------------------------------
$panelVerdict = New-Object System.Windows.Forms.Panel
$panelVerdict.Location = New-Object System.Drawing.Point(12, 100)
$panelVerdict.Size = New-Object System.Drawing.Size(1140, 52)
$panelVerdict.BackColor = $NtColorInfoBg
$form.Controls.Add($panelVerdict)

$lblVerdict = New-Object System.Windows.Forms.Label
$lblVerdict.Location = New-Object System.Drawing.Point(12, 6)
$lblVerdict.Size = New-Object System.Drawing.Size(1110, 22)
$lblVerdict.Font = $NtFontHead
$lblVerdict.ForeColor = $NtColorInfo
$lblVerdict.Text = 'Ready. Enter a device - name, IP or MAC - and press Check device.'
$panelVerdict.Controls.Add($lblVerdict)

$lblVerdictSub = New-Object System.Windows.Forms.Label
$lblVerdictSub.Location = New-Object System.Drawing.Point(12, 30)
$lblVerdictSub.Size = New-Object System.Drawing.Size(1110, 18)
$lblVerdictSub.ForeColor = $NtColorMuted
$lblVerdictSub.Text = 'Sweep takes a range or CIDR. The neighbour box can stay blank - one is found automatically.'
$panelVerdict.Controls.Add($lblVerdictSub)

# ---- Tabs ------------------------------------------------------------------
$tabs = New-Object System.Windows.Forms.TabControl
$tabs.Location = New-Object System.Drawing.Point(12, 160)
$tabs.Size = New-Object System.Drawing.Size(1140, 520)
$form.Controls.Add($tabs)

function New-NtTab {
    param([string]$Text)
    $page = New-Object System.Windows.Forms.TabPage
    $page.Text = $Text
    $page.BackColor = $NtColorPanel
    $page.Padding = New-Object System.Windows.Forms.Padding(8)
    return $page
}

function New-NtListView {
    param($Parent, $Columns)
    $lv = New-Object System.Windows.Forms.ListView
    $lv.View = 'Details'
    $lv.FullRowSelect = $true
    $lv.GridLines = $true
    $lv.HideSelection = $false
    $lv.Font = $NtFontUi
    # Dock, NOT an explicit size derived from $Parent.Width. A TabPage does not
    # have its final dimensions until the form has laid itself out, so sizing
    # from it here produces a control a couple of hundred pixels wide - and
    # Anchor then faithfully preserves those wrong dimensions on every resize.
    $lv.Dock = 'Fill'
    foreach ($col in $Columns) {
        [void]$lv.Columns.Add($col.Name, $col.Width)
    }
    $Parent.Controls.Add($lv)
    return $lv
}

# Device tab, first: is it there, what is it, what address does it really have,
# and who said so. The Triage tab behind it is the detail.
#
# The detail paragraph is a read-only multiline TextBox, not a RichTextBox:
# a RichTextBox renders blank in the headless DrawToBitmap test, so a layout
# built on one could not be verified without a desktop.
$tabDevice = New-NtTab -Text 'Device'
$tabs.TabPages.Add($tabDevice)

$panelDevCard = New-Object System.Windows.Forms.Panel
$panelDevCard.Location = New-Object System.Drawing.Point(8, 8)
$panelDevCard.Size = New-Object System.Drawing.Size(1108, 96)
$panelDevCard.BackColor = $NtColorInfoBg
$tabDevice.Controls.Add($panelDevCard)

$lblDevHead = New-Object System.Windows.Forms.Label
$lblDevHead.Location = New-Object System.Drawing.Point(12, 8)
$lblDevHead.Size = New-Object System.Drawing.Size(1080, 24)
$lblDevHead.Font = $NtFontHead
$lblDevHead.ForeColor = $NtColorInfo
$lblDevHead.Text = 'No device checked yet.'
$panelDevCard.Controls.Add($lblDevHead)

$txtDevDetail = New-Object System.Windows.Forms.TextBox
$txtDevDetail.Multiline = $true
$txtDevDetail.ReadOnly = $true
$txtDevDetail.WordWrap = $true
$txtDevDetail.BorderStyle = 'None'
$txtDevDetail.BackColor = $NtColorInfoBg
$txtDevDetail.ForeColor = $NtColorText
$txtDevDetail.Font = $NtFontUi
$txtDevDetail.Location = New-Object System.Drawing.Point(12, 38)
$txtDevDetail.Size = New-Object System.Drawing.Size(1080, 50)
$txtDevDetail.TabStop = $false
$txtDevDetail.Text = 'Type a name, IP address or MAC address in the Target box and press Check device. The device is asked for directly as well as looked up, so one that ignores ping - or has no DHCP lease - is still found.'
$panelDevCard.Controls.Add($txtDevDetail)

$lblDevFound = New-Object System.Windows.Forms.Label
$lblDevFound.Location = New-Object System.Drawing.Point(8, 112)
$lblDevFound.Size = New-Object System.Drawing.Size(600, 18)
$lblDevFound.Font = $NtFontBold
$lblDevFound.ForeColor = $NtColorMuted
$lblDevFound.Text = 'How it was found'
$tabDevice.Controls.Add($lblDevFound)

$lvDevAnswers = New-Object System.Windows.Forms.ListView
$lvDevAnswers.View = 'Details'; $lvDevAnswers.FullRowSelect = $true; $lvDevAnswers.GridLines = $true
$lvDevAnswers.Font = $NtFontUi
$lvDevAnswers.Location = New-Object System.Drawing.Point(8, 132)
$lvDevAnswers.Size = New-Object System.Drawing.Size(1108, 160)
[void]$lvDevAnswers.Columns.Add('Source', 220)
[void]$lvDevAnswers.Columns.Add('Answer', 130)
[void]$lvDevAnswers.Columns.Add('Name', 190)
[void]$lvDevAnswers.Columns.Add('Answered by', 175)
[void]$lvDevAnswers.Columns.Add('Interface', 110)
[void]$lvDevAnswers.Columns.Add('MAC', 130)
[void]$lvDevAnswers.Columns.Add('ms', 50)
$tabDevice.Controls.Add($lvDevAnswers)

$lblDevFacts = New-Object System.Windows.Forms.Label
$lblDevFacts.Location = New-Object System.Drawing.Point(8, 300)
$lblDevFacts.Size = New-Object System.Drawing.Size(600, 18)
$lblDevFacts.Font = $NtFontBold
$lblDevFacts.ForeColor = $NtColorMuted
$lblDevFacts.Text = 'The device'
$tabDevice.Controls.Add($lblDevFacts)

$lvDevFacts = New-Object System.Windows.Forms.ListView
$lvDevFacts.View = 'Details'; $lvDevFacts.FullRowSelect = $true; $lvDevFacts.GridLines = $true
$lvDevFacts.Font = $NtFontUi
$lvDevFacts.Location = New-Object System.Drawing.Point(8, 320)
$lvDevFacts.Size = New-Object System.Drawing.Size(1108, 160)
[void]$lvDevFacts.Columns.Add('Item', 160)
[void]$lvDevFacts.Columns.Add('Value', 380)
[void]$lvDevFacts.Columns.Add('Detail', 560)
$tabDevice.Controls.Add($lvDevFacts)

# Triage tab: the ladder on top, the findings underneath.
$tabTriage = New-NtTab -Text 'Triage'
$tabs.TabPages.Add($tabTriage)

$lvLadder = New-Object System.Windows.Forms.ListView
$lvLadder.View = 'Details'; $lvLadder.FullRowSelect = $true; $lvLadder.GridLines = $true
$lvLadder.Font = $NtFontUi
$lvLadder.Location = New-Object System.Drawing.Point(8, 8)
$lvLadder.Size = New-Object System.Drawing.Size(1108, 176)
[void]$lvLadder.Columns.Add('Rung', 50)
[void]$lvLadder.Columns.Add('Check', 250)
[void]$lvLadder.Columns.Add('Status', 70)
[void]$lvLadder.Columns.Add('Result', 600)
$tabTriage.Controls.Add($lvLadder)

$rtbFindings = New-Object System.Windows.Forms.RichTextBox
$rtbFindings.Location = New-Object System.Drawing.Point(8, 192)
$rtbFindings.Size = New-Object System.Drawing.Size(1108, 288)
$rtbFindings.ReadOnly = $true
$rtbFindings.BackColor = $NtColorPanel
$rtbFindings.Font = $NtFontUi
$rtbFindings.DetectUrls = $false
$tabTriage.Controls.Add($rtbFindings)

$tabRoutes = New-NtTab -Text 'Routes'
$tabs.TabPages.Add($tabRoutes)
$lvRoutes = New-NtListView -Parent $tabRoutes -Columns @(
    @{Name='Destination'; Width=130}, @{Name='Next hop'; Width=115}, @{Name='Interface'; Width=130},
    @{Name='Store'; Width=95}, @{Name='Binding'; Width=125}, @{Name='Metric'; Width=50},
    @{Name='Verdict'; Width=115}, @{Name='Detail'; Width=350}
)

# Interfaces: every IPv4 interface including the disconnected ones. The Endpoint
# summary shows only what is Up and addressed, which is the right summary and
# exactly the wrong thing to reason about a dormant route with.
$tabInterfaces = New-NtTab -Text 'Interfaces'
$tabs.TabPages.Add($tabInterfaces)

$panelIfTop = New-Object System.Windows.Forms.Panel
$panelIfTop.Location = New-Object System.Drawing.Point(8, 8)
$panelIfTop.Size = New-Object System.Drawing.Size(1100, 32)
$panelIfTop.BackColor = $NtColorPanel
$tabInterfaces.Controls.Add($panelIfTop)

$btnIfRefresh = New-Object System.Windows.Forms.Button
$btnIfRefresh.Text = 'Refresh'
$btnIfRefresh.Location = New-Object System.Drawing.Point(0, 2)
$btnIfRefresh.Size = New-Object System.Drawing.Size(90, 26)
$panelIfTop.Controls.Add($btnIfRefresh)

$lblIfSummary = New-Object System.Windows.Forms.Label
$lblIfSummary.Location = New-Object System.Drawing.Point(100, 8)
$lblIfSummary.Size = New-Object System.Drawing.Size(990, 20)
$lblIfSummary.ForeColor = $NtColorMuted
$panelIfTop.Controls.Add($lblIfSummary)

$lvInterfaces = New-Object System.Windows.Forms.ListView
$lvInterfaces.View = 'Details'; $lvInterfaces.FullRowSelect = $true; $lvInterfaces.GridLines = $true
$lvInterfaces.Font = $NtFontUi
$lvInterfaces.Location = New-Object System.Drawing.Point(8, 46)
$lvInterfaces.Size = New-Object System.Drawing.Size(1100, 430)
[void]$lvInterfaces.Columns.Add('Idx', 45)
[void]$lvInterfaces.Columns.Add('Interface', 175)
[void]$lvInterfaces.Columns.Add('Kind', 70)
[void]$lvInterfaces.Columns.Add('State', 95)
[void]$lvInterfaces.Columns.Add('Addresses', 170)
[void]$lvInterfaces.Columns.Add('Metric', 55)
[void]$lvInterfaces.Columns.Add('MTU', 55)
[void]$lvInterfaces.Columns.Add('DHCP', 60)
[void]$lvInterfaces.Columns.Add('DNS', 130)
[void]$lvInterfaces.Columns.Add('Description', 200)
$tabInterfaces.Controls.Add($lvInterfaces)

# Neighbour: the target-vs-neighbour differential - the same questions asked
# of both, side by side.
$tabPeer = New-NtTab -Text 'Neighbour'
$tabs.TabPages.Add($tabPeer)
$lvPeer = New-NtListView -Parent $tabPeer -Columns @(
    @{Name='Dimension'; Width=130}, @{Name='Status'; Width=55},
    @{Name='Target  |  Neighbour'; Width=340}, @{Name='What it means'; Width=430}
)

$tabPath = New-NtTab -Text 'Path'
$tabs.TabPages.Add($tabPath)
$lvPath = New-NtListView -Parent $tabPath -Columns @(
    @{Name='Hop'; Width=50}, @{Name='Address'; Width=135}, @{Name='Name'; Width=200},
    @{Name='Avg ms'; Width=65}, @{Name='TTL'; Width=55}, @{Name='Reading'; Width=460}
)

$tabNames = New-NtTab -Text 'Names and ARP'
$tabs.TabPages.Add($tabNames)
$lvNames = New-NtListView -Parent $tabNames -Columns @(
    @{Name='Area'; Width=75}, @{Name='Item'; Width=200}, @{Name='Status'; Width=60},
    @{Name='Value'; Width=250}, @{Name='Detail'; Width=380}
)

$tabGateway = New-NtTab -Text 'Gateway'
$tabs.TabPages.Add($tabGateway)
$lvGateway = New-NtListView -Parent $tabGateway -Columns @(
    @{Name='Check'; Width=190}, @{Name='Status'; Width=60}, @{Name='Result'; Width=300}, @{Name='Detail'; Width=420}
)

$tabSweep = New-NtTab -Text 'Sweep'
$tabs.TabPages.Add($tabSweep)
$lvSweep = New-NtListView -Parent $tabSweep -Columns @(
    @{Name='Address'; Width=120}, @{Name='Found by'; Width=70}, @{Name='Hostname'; Width=190},
    @{Name='MAC'; Width=130}, @{Name='Vendor'; Width=170}, @{Name='TTL'; Width=50},
    @{Name='Ports'; Width=130}, @{Name='Reading'; Width=200}
)

$tabInventory = New-NtTab -Text 'Inventory'
$tabs.TabPages.Add($tabInventory)
$lvInventory = New-NtListView -Parent $tabInventory -Columns @(
    @{Name='Kind'; Width=130}, @{Name='Severity'; Width=70}, @{Name='Key'; Width=140}, @{Name='Summary'; Width=700}
)

# VPN A/B: two captures with a state change in between. A single snapshot can
# never tell you whether a persistent route activates when a VPN comes up, or
# whether the source address the far end sees changes. This can.
$tabAb = New-NtTab -Text 'VPN A/B'
$tabs.TabPages.Add($tabAb)

$lblAb = New-Object System.Windows.Forms.Label
$lblAb.Location = New-Object System.Drawing.Point(8, 8)
$lblAb.Size = New-Object System.Drawing.Size(1100, 48)
$lblAb.ForeColor = $NtColorMuted
$lblAb.Text = "Capture A in the state you have now. Then change ONE thing - connect or disconnect the VPN - and capture B.`r`nThe comparison shows whether a persistent route became active, and whether the source address the far end sees changed."
$tabAb.Controls.Add($lblAb)

$btnCaptureA = New-Object System.Windows.Forms.Button
$btnCaptureA.Text = 'Capture A'
$btnCaptureA.Location = New-Object System.Drawing.Point(8, 60)
$btnCaptureA.Size = New-Object System.Drawing.Size(110, 28)
$tabAb.Controls.Add($btnCaptureA)

$btnCaptureB = New-Object System.Windows.Forms.Button
$btnCaptureB.Text = 'Capture B and compare'
$btnCaptureB.Location = New-Object System.Drawing.Point(126, 60)
$btnCaptureB.Size = New-Object System.Drawing.Size(160, 28)
$btnCaptureB.Enabled = $false
$tabAb.Controls.Add($btnCaptureB)

$lblAbState = New-Object System.Windows.Forms.Label
$lblAbState.Location = New-Object System.Drawing.Point(298, 66)
$lblAbState.Size = New-Object System.Drawing.Size(800, 20)
$lblAbState.ForeColor = $NtColorMuted
$lblAbState.Text = 'No snapshot captured yet.'
$tabAb.Controls.Add($lblAbState)

$lvAb = New-Object System.Windows.Forms.ListView
$lvAb.View = 'Details'; $lvAb.FullRowSelect = $true; $lvAb.GridLines = $true
$lvAb.Font = $NtFontUi
$lvAb.Location = New-Object System.Drawing.Point(8, 96)
$lvAb.Size = New-Object System.Drawing.Size(1100, 380)
[void]$lvAb.Columns.Add('Change', 260)
[void]$lvAb.Columns.Add('Status', 60)
[void]$lvAb.Columns.Add('Result', 300)
[void]$lvAb.Columns.Add('What it proves', 360)
$tabAb.Controls.Add($lvAb)

$tabEscalation = New-NtTab -Text 'Escalation'
$tabs.TabPages.Add($tabEscalation)
$txtEscalation = New-Object System.Windows.Forms.TextBox
$txtEscalation.Multiline = $true
$txtEscalation.ScrollBars = 'Vertical'
$txtEscalation.ReadOnly = $true
$txtEscalation.Font = $NtFontMono
$txtEscalation.Location = New-Object System.Drawing.Point(8, 8)
$txtEscalation.Size = New-Object System.Drawing.Size(1108, 440)
$txtEscalation.WordWrap = $false
$txtEscalation.ScrollBars = 'Both'
$tabEscalation.Controls.Add($txtEscalation)

$btnCopyEsc = New-Object System.Windows.Forms.Button
$btnCopyEsc.Text = 'Copy to clipboard'
$btnCopyEsc.Location = New-Object System.Drawing.Point(8, 454)
$btnCopyEsc.Size = New-Object System.Drawing.Size(150, 28)
$tabEscalation.Controls.Add($btnCopyEsc)

# ---- Bottom strip ----------------------------------------------------------
$panelBottom = New-Object System.Windows.Forms.Panel
$panelBottom.Location = New-Object System.Drawing.Point(12, 688)
$panelBottom.Size = New-Object System.Drawing.Size(1140, 44)
$panelBottom.BackColor = $NtColorBg
$form.Controls.Add($panelBottom)

$lblStatus = New-Object System.Windows.Forms.Label
$lblStatus.Location = New-Object System.Drawing.Point(0, 12)
$lblStatus.Size = New-Object System.Drawing.Size(430, 20)
$lblStatus.ForeColor = $NtColorMuted
$lblStatus.Text = 'Ready.'
$panelBottom.Controls.Add($lblStatus)

$progress = New-Object System.Windows.Forms.ProgressBar
$progress.Location = New-Object System.Drawing.Point(436, 12)
$progress.Size = New-Object System.Drawing.Size(150, 18)
$progress.Style = 'Continuous'
$panelBottom.Controls.Add($progress)

$btnSaveBaseline = New-Object System.Windows.Forms.Button
$btnSaveBaseline.Text = 'Save baseline'
$btnSaveBaseline.Location = New-Object System.Drawing.Point(600, 8)
$btnSaveBaseline.Size = New-Object System.Drawing.Size(110, 28)
$panelBottom.Controls.Add($btnSaveBaseline)

$btnCompareBaseline = New-Object System.Windows.Forms.Button
$btnCompareBaseline.Text = 'Compare baseline'
$btnCompareBaseline.Location = New-Object System.Drawing.Point(716, 8)
$btnCompareBaseline.Size = New-Object System.Drawing.Size(120, 28)
$panelBottom.Controls.Add($btnCompareBaseline)

$btnFix = New-Object System.Windows.Forms.Button
$btnFix.Text = 'Fix...'
$btnFix.Location = New-Object System.Drawing.Point(842, 8)
$btnFix.Size = New-Object System.Drawing.Size(70, 28)
$btnFix.Enabled = $false
$panelBottom.Controls.Add($btnFix)

$btnExportJson = New-Object System.Windows.Forms.Button
$btnExportJson.Text = 'Export JSON'
$btnExportJson.Location = New-Object System.Drawing.Point(918, 8)
$btnExportJson.Size = New-Object System.Drawing.Size(105, 28)
$panelBottom.Controls.Add($btnExportJson)

$btnExportHtml = New-Object System.Windows.Forms.Button
$btnExportHtml.Text = 'Export HTML'
$btnExportHtml.Location = New-Object System.Drawing.Point(1029, 8)
$btnExportHtml.Size = New-Object System.Drawing.Size(105, 28)
$panelBottom.Controls.Add($btnExportHtml)

# =============================================================================
# Worker plumbing
# =============================================================================
# Everything slow runs in a background runspace. The UI thread never blocks, so
# Cancel works and the window never greys out mid-scan.
#
# The two sides share exactly one object: a synchronized hashtable. The worker
# writes Status/Progress/Result into it; a WinForms timer on the UI thread reads
# them. No cross-thread control access, which is what usually kills these.

function Start-NtWork {
    param([string]$Kind, [scriptblock]$Body, $Arguments = @{})

    if ($script:Sync.Running) { return }

    $script:Sync.Running  = $true
    $script:Sync.Cancel   = $false
    $script:Sync.Status   = 'Starting...'
    $script:Sync.Progress = 0
    $script:Sync.Result   = $null
    $script:Sync.Error    = ''
    $script:Sync.Kind     = $Kind

    $runspace = [runspacefactory]::CreateRunspace()
    $runspace.ApartmentState = 'STA'
    $runspace.ThreadOptions  = 'ReuseThread'
    $runspace.Open()
    $runspace.SessionStateProxy.SetVariable('Sync', $script:Sync)
    $runspace.SessionStateProxy.SetVariable('HelpersText', $script:HelpersText)
    $runspace.SessionStateProxy.SetVariable('ProjectDir', $scriptDir)
    $runspace.SessionStateProxy.SetVariable('NtArgs', $Arguments)

    $wrapper = {
        param($Body)
        try {
            # Rebuild the helper functions inside this runspace from the text.
            . ([ScriptBlock]::Create($HelpersText))
            Set-NtProjectDir -Path $ProjectDir
            $Sync.Result = & ([ScriptBlock]::Create($Body)) $NtArgs $Sync
        } catch {
            $Sync.Error = ('{0}{1}{2}' -f $_.Exception.Message, [Environment]::NewLine, $_.ScriptStackTrace)
        } finally {
            $Sync.Running = $false
            $Sync.Progress = 100
        }
    }

    $ps = [PowerShell]::Create()
    $ps.Runspace = $runspace
    [void]$ps.AddScript($wrapper).AddArgument($Body.ToString())

    $script:Worker      = $ps
    $script:WorkerAsync = $ps.BeginInvoke()

    $btnTriage.Enabled = $false
    $btnSweep.Enabled  = $false
    $btnRoutes.Enabled = $false
    $btnSaveBaseline.Enabled = $false
    $btnCompareBaseline.Enabled = $false
    $btnCaptureA.Enabled = $false
    $btnCaptureB.Enabled = $false
    # Fix was NOT disabled during collection, so configuration could be
    # changed while it was being measured - producing a report describing a
    # machine that no longer exists, with no indication that had happened.
    $btnFix.Enabled = $false
    $btnCancel.Enabled = $true
    $timer.Start()
}

function Stop-NtWork {
    $timer.Stop()
    if ($script:Worker) {
        try { $script:Worker.EndInvoke($script:WorkerAsync) | Out-Null } catch {}
        try { $script:Worker.Runspace.Close() } catch {}
        try { $script:Worker.Dispose() } catch {}
        $script:Worker = $null
    }
    $btnTriage.Enabled = $true
    $btnSweep.Enabled  = $true
    $btnRoutes.Enabled = $true
    $btnSaveBaseline.Enabled = $true
    $btnCompareBaseline.Enabled = $true
    $btnCaptureA.Enabled = $true
    # B only makes sense once there is an A to compare against.
    $btnCaptureB.Enabled = ($null -ne $script:SnapshotA)
    $btnCancel.Enabled = $false
    $progress.Value = 0
}

function Set-NtVerdictBanner {
    param([string]$Level, [string]$Headline, [string]$Sub = '')
    $lblVerdict.Text = $Headline
    $lblVerdictSub.Text = $Sub
    switch ($Level) {
        'critical' { $panelVerdict.BackColor = $NtColorFailBg; $lblVerdict.ForeColor = $NtColorFail }
        'high'     { $panelVerdict.BackColor = $NtColorFailBg; $lblVerdict.ForeColor = $NtColorFail }
        'medium'   { $panelVerdict.BackColor = $NtColorWarnBg; $lblVerdict.ForeColor = $NtColorWarn }
        'low'      { $panelVerdict.BackColor = $NtColorInfoBg; $lblVerdict.ForeColor = $NtColorInfo }
        'ok'       { $panelVerdict.BackColor = $NtColorOkBg;   $lblVerdict.ForeColor = $NtColorOk }
        default    { $panelVerdict.BackColor = $NtColorInfoBg; $lblVerdict.ForeColor = $NtColorInfo }
    }
}

function Add-NtListRow {
    param($ListView, [string[]]$Values, [string]$Status = '', $Tag = $null)
    $item = New-Object System.Windows.Forms.ListViewItem($Values[0])
    for ($i = 1; $i -lt $Values.Count; $i++) {
        [void]$item.SubItems.Add([string]$Values[$i])
    }
    if ($Status) { $item.ForeColor = Get-NtStatusColor -Status $Status }
    if ($Tag) { $item.Tag = $Tag }
    [void]$ListView.Items.Add($item)
    return $item
}

function Write-NtFindings {
    param($Report)
    $rtbFindings.Clear()

    $append = {
        param([string]$Text, $Color, $Font)
        $rtbFindings.SelectionStart  = $rtbFindings.TextLength
        $rtbFindings.SelectionLength = 0
        $rtbFindings.SelectionColor  = $Color
        $rtbFindings.SelectionFont   = $Font
        $rtbFindings.AppendText($Text)
    }

    $findings = @($Report.findings)
    if ($findings.Count -eq 0) {
        & $append "No findings.`r`n" $NtColorMuted $NtFontUi
        return
    }

    foreach ($finding in $findings) {
        $sevColor = Get-NtSeverityColor -Severity $finding.severity
        & $append ("[{0}] " -f $finding.severity.ToUpper()) $sevColor $NtFontBold
        & $append ("{0}`r`n" -f $finding.title) $NtColorText $NtFontBold
        & $append ("    {0}`r`n" -f $finding.summary) $NtColorText $NtFontUi
        if ($finding.action) {
            & $append "    Action: " $NtColorMuted $NtFontBold
            & $append ("{0}`r`n" -f $finding.action) $NtColorText $NtFontUi
        }
        foreach ($cmd in @($finding.commands)) {
            & $append ("      {0}`r`n" -f $cmd) $NtColorInfo $NtFontMono
        }
        & $append ("    evidence: {0}   confidence: {1}`r`n`r`n" -f (@($finding.evidence) -join ', '), $finding.confidence) $NtColorMuted $NtFontUi
    }
}

function Show-NtInterfaces {
    param($Section)
    if (-not $Section -or -not $Section.data) { return }
    $lvInterfaces.Items.Clear()
    foreach ($ifc in @($Section.data.Interfaces)) {
        $addresses = (@(@($ifc.Addresses) | ForEach-Object { '{0}/{1}' -f $_.IPAddress, $_.PrefixLength }) -join ', ')
        $status = 'info'
        if ($ifc.ConnectionState -eq 'Connected') {
            $status = if ($addresses) { 'ok' } else { 'warn' }
        }
        [void](Add-NtListRow -ListView $lvInterfaces -Status $status -Values @(
            [string]$ifc.InterfaceIndex, [string]$ifc.InterfaceAlias, [string]$ifc.InterfaceKind,
            [string]$ifc.ConnectionState, $addresses, [string]$ifc.InterfaceMetric,
            $(if ($ifc.Mtu -gt 0) { [string]$ifc.Mtu } else { '' }), [string]$ifc.Dhcp,
            ((@($ifc.DnsServers)) -join ', '), [string]$ifc.InterfaceDescription
        ) -Tag $ifc)
    }
    $total = @($Section.data.Interfaces).Count
    $down  = @(@($Section.data.Interfaces) | Where-Object { $_.ConnectionState -ne 'Connected' }).Count
    $lblIfSummary.Text = ('{0} IPv4 interfaces, {1} not connected.{2}' -f $total, $down,
        $(if ($Section.data.MultiHomed) { ' MULTI-HOMED: more than one connected interface holds a routable address, so Windows is choosing between paths on metric.' } else { '' }))
}

function Get-NtDeviceCardColors {
    # Card background and headline colour for a device status level.
    param([string]$Level)
    switch ($Level) {
        'high'   { return @($NtColorFailBg, $NtColorFail) }
        'medium' { return @($NtColorWarnBg, $NtColorWarn) }
        'low'    { return @($NtColorWarnBg, $NtColorWarn) }
        'ok'     { return @($NtColorOkBg,   $NtColorOk) }
        default  { return @($NtColorInfoBg, $NtColorInfo) }
    }
}

function Show-NtDevice {
    param($Report)
    $lvDevAnswers.Items.Clear()
    $lvDevFacts.Items.Clear()
    $dev = $Report.device
    if (-not $dev) {
        $lblDevHead.Text = $(if ($Report.runState -eq 'cancelled') { 'Stopped before the device was identified.' } else { 'No device information in this report.' })
        $txtDevDetail.Text = ''
        $colors = Get-NtDeviceCardColors -Level 'info'
    } else {
        $lblDevHead.Text = [string]$dev.Headline
        $txtDevDetail.Text = [string]$dev.Detail
        $colors = Get-NtDeviceCardColors -Level ([string]$dev.Level)
    }
    $panelDevCard.BackColor = $colors[0]
    $txtDevDetail.BackColor = $colors[0]
    $lblDevHead.ForeColor = $colors[1]

    foreach ($a in @(Get-NtDeviceAnswerRows -Identity $Report.identity)) {
        $status = if ($a.Self) { 'ok' } elseif ($a.Kind -eq 'history') { 'skipped' } else { 'info' }
        [void](Add-NtListRow -ListView $lvDevAnswers -Status $status -Values @(
            [string]$a.Source, [string]$a.Answer, [string]$a.Name, [string]$a.AnsweredBy,
            [string]$a.Interface, [string]$a.Mac, $(if ($a.Ms -gt 0) { [string]$a.Ms } else { '' })
        ) -Tag $a)
    }
    if ($lvDevAnswers.Items.Count -eq 0 -and $Report.identity) {
        [void](Add-NtListRow -ListView $lvDevAnswers -Status 'fail' -Values @('(nothing answered)', '', '', '', '', '', ''))
    }
    $devSection = @(@($Report.sections) | Where-Object { $_.name -eq 'Device' } | Select-Object -First 1)
    if ($devSection.Count -gt 0) {
        foreach ($row in @($devSection[0].rows)) {
            if ($row.check -eq 'Status') { continue }
            [void](Add-NtListRow -ListView $lvDevFacts -Status $row.status -Values @(
                [string]$row.check, [string]$row.result, [string]$row.detail
            ) -Tag $row)
        }
    }
}

function Show-NtReport {
    param($Report)
    $script:Report = $Report
    $script:LastRunKind = 'triage'
    $script:LastRunAt   = Get-Date

    Show-NtDevice -Report $Report

    $lvLadder.Items.Clear()
    foreach ($rung in @($Report.ladder)) {
        [void](Add-NtListRow -ListView $lvLadder -Status $rung.status -Values @(
            [string]$rung.number, [string]$rung.name, [string]$rung.status, [string]$rung.result
        ) -Tag $rung)
    }

    Write-NtFindings -Report $Report

    # The banner answers the question that was asked - is the DEVICE there -
    # and the top finding goes underneath. A cancelled run, or one with no
    # device card, keeps the finding-based verdict.
    $verdict = $Report.verdict
    $sub = $verdict.firstFailure
    if (-not $sub) { $sub = ('{0} finding(s). Target {1}.' -f $verdict.findingCount, $Report.target) }
    if ($Report.device -and $Report.runState -ne 'cancelled') {
        $devSub = if ($verdict.headline -and $verdict.headline -ne 'No findings.') { ('Top finding: {0}' -f $verdict.headline) } else { $sub }
        Set-NtVerdictBanner -Level ([string]$Report.device.Level) -Headline ([string]$Report.device.Headline) -Sub $devSub
    } else {
        Set-NtVerdictBanner -Level $verdict.level -Headline $verdict.headline -Sub $sub
    }

    # Routes
    $lvRoutes.Items.Clear()
    $routeSection = @($Report.sections | Where-Object { $_.name -eq 'Route audit' } | Select-Object -First 1)
    if ($routeSection.Count -gt 0 -and $routeSection[0].data) {
        foreach ($route in @($routeSection[0].data.Routes)) {
            [void](Add-NtListRow -ListView $lvRoutes -Status $route.Status -Values @(
                [string]$route.DestinationPrefix, [string]$route.NextHop, [string]$route.InterfaceAlias,
                [string]$route.Store, [string]$route.BindingFlag, [string]$route.TotalMetric,
                [string]$route.Verdict, [string]$route.Detail
            ) -Tag $route)
        }
    }

    # Path
    $lvPath.Items.Clear()
    $pathSection = @($Report.sections | Where-Object { $_.name -eq 'Path' } | Select-Object -First 1)
    if ($pathSection.Count -gt 0 -and $pathSection[0].data) {
        foreach ($hop in @($pathSection[0].data.Hops)) {
            $reading = ''
            if ($hop.TtlReading) { $reading = [string]$hop.TtlReading.Detail } elseif ($hop.Note) { $reading = [string]$hop.Note }
            [void](Add-NtListRow -ListView $lvPath -Status $(if ($hop.Replies -gt 0) { 'ok' } else { 'info' }) -Values @(
                [string]$hop.Hop, $(if ($hop.Address) { [string]$hop.Address } else { '*' }), [string]$hop.Name,
                [string]$hop.AvgMs, $(if ($hop.ReplyTtl -gt 0) { [string]$hop.ReplyTtl } else { '' }), $reading
            ) -Tag $hop)
        }
    }

    # Names and ARP, merged into one view because they answer the same question:
    # is anything local sending this somewhere unexpected?
    $lvNames.Items.Clear()
    foreach ($sectionName in @('Name resolution', 'ARP and layer 2')) {
        $section = @($Report.sections | Where-Object { $_.name -eq $sectionName } | Select-Object -First 1)
        if ($section.Count -eq 0) { continue }
        $area = if ($sectionName -like 'Name*') { 'Names' } else { 'ARP' }
        foreach ($row in @($section[0].rows)) {
            [void](Add-NtListRow -ListView $lvNames -Status $row.status -Values @(
                $area, [string]$row.check, [string]$row.status, [string]$row.result, [string]$row.detail
            ) -Tag $row)
        }
    }

    # Gateway
    $lvGateway.Items.Clear()
    $gwSection = @($Report.sections | Where-Object { $_.name -eq 'Gateway' } | Select-Object -First 1)
    if ($gwSection.Count -gt 0) {
        foreach ($row in @($gwSection[0].rows)) {
            [void](Add-NtListRow -ListView $lvGateway -Status $row.status -Values @(
                [string]$row.check, [string]$row.status, [string]$row.result, [string]$row.detail
            ) -Tag $row)
        }
    }

    # Target vs peer
    $lvPeer.Items.Clear()
    $peerSection = @($Report.sections | Where-Object { $_.name -eq 'Target vs peer' } | Select-Object -First 1)
    if ($peerSection.Count -gt 0) {
        foreach ($row in @($peerSection[0].rows)) {
            [void](Add-NtListRow -ListView $lvPeer -Status $row.status -Values @(
                [string]$row.check, [string]$row.status, [string]$row.result, [string]$row.detail
            ) -Tag $row)
        }
    }

    # Interfaces, from the same context the report was built on.
    $endpointSection = @($Report.sections | Where-Object { $_.name -eq 'Interfaces' } | Select-Object -First 1)
    if ($endpointSection.Count -gt 0) { Show-NtInterfaces -Section $endpointSection[0] }

    # Escalation
    try { $txtEscalation.Text = (New-NtEscalationSummary -Report $Report) -replace "`r?`n", "`r`n" } catch { $txtEscalation.Text = '' }

    # STRICT. This was "-AllowFix OR any finding carries a command", which is
    # not a gate - most findings carry commands, so remediation was available
    # by default and the switch meant nothing. Diagnosis and remediation are
    # separate activities and the operator opts in to the second one.
    $btnFix.Enabled = ($AllowFix.IsPresent -and
                       (@($Report.findings | Where-Object { @($_.commands).Count -gt 0 }).Count -gt 0))
    if (-not $AllowFix.IsPresent) {
        $NtTips.SetToolTip($btnFix, 'Remediation is off. Re-launch with -AllowFix to enable it - diagnosis does not change this machine.')
    }
}

function Show-NtSweep {
    param($SweepSection, $Matches = @())
    $script:SweepResult = $SweepSection
    $script:LastRunKind = 'sweep'
    $script:LastRunAt   = Get-Date
    $lvSweep.Items.Clear()
    foreach ($host1 in @($SweepSection.data.Hosts)) {
        $reading = ''
        if ($host1.TtlReading) { $reading = [string]$host1.TtlReading.OsClass }
        [void](Add-NtListRow -ListView $lvSweep -Status 'ok' -Values @(
            [string]$host1.IP, [string]$host1.Discovery, [string]$host1.Hostname,
            (Format-NtMac ([string]$host1.Mac)), [string]$host1.Vendor,
            $(if ($host1.Ttl -gt 0) { [string]$host1.Ttl } else { '' }),
            ((@($host1.OpenPorts)) -join ','), $reading
        ) -Tag $host1)
    }

    $lvInventory.Items.Clear()
    foreach ($match in @($Matches)) {
        $key = ''
        if ($match.PSObject.Properties.Match('Mac').Count -and $match.Mac) { $key = [string]$match.Mac }
        elseif ($match.PSObject.Properties.Match('Ip').Count -and $match.Ip) { $key = [string]$match.Ip }
        $status = switch ([string]$match.Severity) { 'high' { 'fail' } 'medium' { 'warn' } default { 'info' } }
        [void](Add-NtListRow -ListView $lvInventory -Status $status -Values @(
            [string]$match.Kind, [string]$match.Severity, $key, [string]$match.Summary
        ) -Tag $match)
    }

    $alive = $SweepSection.data.Alive
    $probed = $SweepSection.data.Probed
    $level = if ($alive -gt 0) { 'ok' } else { 'medium' }
    Set-NtVerdictBanner -Level $level -Headline ('{0} of {1} addresses responded' -f $alive, $probed) -Sub (@($SweepSection.caveats) -join '  ')
    $tabs.SelectedTab = $tabSweep
}

# =============================================================================
# Timer - the only thing that touches controls while work is running
# =============================================================================
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 250
$timer.Add_Tick({
    $lblStatus.Text = [string]$script:Sync.Status
    $pct = [int]$script:Sync.Progress
    if ($pct -ge 0 -and $pct -le 100) { $progress.Value = $pct }

    if ($script:Sync.Running) { return }

    Stop-NtWork

    if ($script:Sync.Error) {
        Set-NtVerdictBanner -Level 'high' -Headline 'The run failed' -Sub ($script:Sync.Error -split "`n")[0]
        [System.Windows.Forms.MessageBox]::Show($script:Sync.Error, 'Network Toolkit', 'OK', 'Error') | Out-Null
        $lblStatus.Text = 'Failed.'
        return
    }

    $result = $script:Sync.Result
    if (-not $result) { $lblStatus.Text = 'Cancelled or no result.'; return }

    switch ($script:Sync.Kind) {
        'triage' {
            Show-NtReport -Report $result
            $tabs.SelectedTab = $tabDevice
            # "Triage complete." was printed unconditionally, including on a
            # run the user had stopped - so a partial report full of
            # not-yet-sent probes was presented as a finished assessment.
            if ($result.runState -eq 'cancelled') {
                $lblStatus.Text = 'STOPPED before finishing - partial evidence, no assessment.'
            } else {
                $lblStatus.Text = 'Check complete. The Triage tab has the full ladder and findings.'
            }
        }
        'sweep'  {
            Show-NtSweep -SweepSection $result.Sweep -Matches $result.Matches
            $sd = $result.Sweep.data
            if ($sd -and [int]$sd.NotTested -gt 0) {
                $lblStatus.Text = ('STOPPED after {0} of {1} addresses - the rest were not tested.' -f $sd.Probed, $sd.Requested)
            } else {
                $lblStatus.Text = 'Sweep complete.'
            }
        }
        'routes' {
            $lvRoutes.Items.Clear()
            foreach ($route in @($result.data.Routes)) {
                [void](Add-NtListRow -ListView $lvRoutes -Status $route.Status -Values @(
                    [string]$route.DestinationPrefix, [string]$route.NextHop, [string]$route.InterfaceAlias,
                    [string]$route.Store, [string]$route.BindingFlag, [string]$route.TotalMetric,
                    [string]$route.Verdict, [string]$route.Detail
                ) -Tag $route)
            }
            $bad = [int]$result.data.BadCount
            $level = if ($bad -gt 0) { 'high' } else { 'ok' }
            $headline = if ($bad -gt 0) { ('{0} route(s) point at an unreachable next hop' -f $bad) } else { 'No stale routes found' }
            Set-NtVerdictBanner -Level $level -Headline $headline -Sub ('{0} routes audited.' -f @($result.data.Routes).Count)
            $tabs.SelectedTab = $tabRoutes
            $lblStatus.Text = 'Route audit complete.'
        }
        'baseline' {
            $lvNames.Items.Clear()
            foreach ($row in @($result.rows)) {
                [void](Add-NtListRow -ListView $lvNames -Status $row.status -Values @(
                    'Baseline', [string]$row.check, [string]$row.status, [string]$row.result, [string]$row.detail
                ) -Tag $row)
            }
            # Honour the section STATE. This read .data unconditionally, and a
            # skipped section has none - so "no baseline has ever been saved"
            # produced $changed = 0 and the banner "No route changes since the
            # baseline", which is the most reassuring possible way to say
            # nothing was compared at all.
            if ($result.state -ne 'measured') {
                Set-NtVerdictBanner -Level 'medium' -Headline 'No comparison was made' -Sub $result.reason
                $tabs.SelectedTab = $tabNames
                $lblStatus.Text = 'Baseline comparison did not run.'
            } else {
                $changed = [int]$result.data.RoutesAdded + [int]$result.data.RoutesRemoved
                $sub = ('Baseline saved {0}.' -f $result.data.SavedUtc)
                # A cross-machine or cross-network comparison is reported as
                # such rather than as a clean result.
                if (@($result.caveats).Count -gt 0) { $sub = (@($result.caveats)[0]) }
                $lvl = if ($changed -gt 0) { 'medium' } elseif (@($result.caveats).Count -gt 0) { 'medium' } else { 'ok' }
                $head = if ($changed -gt 0) { ('{0} route change(s) since the baseline' -f $changed) } else { 'No route changes since the baseline' }
                Set-NtVerdictBanner -Level $lvl -Headline $head -Sub $sub
                $tabs.SelectedTab = $tabNames
                $lblStatus.Text = 'Baseline comparison complete.'
            }
        }
        'savebaseline' {
            # Ok was ignored, so a failed write still reported "Baseline
            # saved" - and the technician only found out weeks later, when
            # the comparison they were relying on had nothing to compare to.
            if ($result.Ok) {
                $lblStatus.Text = ('Baseline saved to {0}' -f $result.Path)
                Set-NtVerdictBanner -Level 'ok' -Headline 'Baseline saved' -Sub $result.Path
            } else {
                $lblStatus.Text = 'Baseline NOT saved.'
                Set-NtVerdictBanner -Level 'high' -Headline 'Baseline was NOT saved' -Sub $result.Reason
                [System.Windows.Forms.MessageBox]::Show($result.Reason, 'Network Toolkit', 'OK', 'Error') | Out-Null
            }
        }
        'snapa' {
            $script:SnapshotA = $result
            $btnCaptureB.Enabled = $true
            $lvAb.Items.Clear()
            $lblAbState.Text = ('Snapshot A captured {0} - {1} active route(s), {2} persistent, VPN suspected: {3}.' -f $result.capturedUtc, @($result.activeRoutes).Count, @($result.persistentRoutes).Count, $result.vpnSuspected)
            Set-NtVerdictBanner -Level 'ok' -Headline 'Snapshot A captured' -Sub 'Now change one thing - connect or disconnect the VPN - and capture B.'
            $tabs.SelectedTab = $tabAb
            $lblStatus.Text = 'Snapshot A captured.'
        }
        'snapb' {
            $script:AbComparison = $result
            $lvAb.Items.Clear()
            foreach ($row in @($result.rows)) {
                [void](Add-NtListRow -ListView $lvAb -Status $row.status -Values @(
                    [string]$row.check, [string]$row.status, [string]$row.result, [string]$row.detail
                ) -Tag $row)
            }
            $proved = @($result.data.Proofs).Count
            $lblAbState.Text = ('Compared {0} with {1}.' -f $result.data.Before.label, $result.data.After.label)
            Set-NtVerdictBanner -Level $(if ($proved -gt 0) { 'high' } else { 'ok' }) -Headline $(if ($proved -gt 0) { 'The state change altered this machine routing' } else { 'Nothing on this machine changed' }) -Sub ([string]$result.data.Verdict)
            $tabs.SelectedTab = $tabAb
            $lblStatus.Text = 'State comparison complete.'
        }
    }
})

# =============================================================================
# Actions
# =============================================================================

function Get-NtSelectedProfileName {
    if ($cboProfile.SelectedItem -and [string]$cboProfile.SelectedItem -ne '(none)') {
        return [string]$cboProfile.SelectedItem
    }
    return ''
}

function ConvertTo-NtPortArray {
    # Bad tokens were DROPPED SILENTLY. Type "443, 44e3, 80" and you were
    # tested on two ports while believing you asked for three - and if every
    # token was bad the caller fell back to a default list, so you were tested
    # on ports you never named at all. Rejected tokens are now reported.
    param([string]$Text, [ref]$Rejected)
    $out = [System.Collections.Generic.List[int]]::new()
    $bad = [System.Collections.Generic.List[string]]::new()
    foreach ($piece in @($Text -split '[,;\s]+' | Where-Object { $_ })) {
        $tok = $piece.Trim()
        $value = 0
        if ([int]::TryParse($tok, [ref]$value) -and $value -gt 0 -and $value -le 65535) {
            if (-not $out.Contains($value)) { $out.Add($value) }
        } else {
            $bad.Add($tok)
        }
    }
    if ($Rejected) { $Rejected.Value = [string[]]@($bad.ToArray()) }
    return [int[]]@($out)
}

function Get-NtPortsFromBox {
    # One place that reads the ports box, so both callers validate identically.
    # Returns $null when the input cannot be honoured, having already told the
    # user why - the caller must then abandon the run rather than substitute
    # something the technician did not ask for.
    param([string]$Text)
    $rejected = $null
    $ports = ConvertTo-NtPortArray -Text $Text -Rejected ([ref]$rejected)
    if (@($rejected).Count -gt 0) {
        $msg = ("These are not valid TCP ports and were not tested:`n`n  {0}`n`nA port must be a whole number from 1 to 65535." -f (@($rejected) -join ', '))
        if (@($ports).Count -eq 0) {
            [System.Windows.Forms.MessageBox]::Show(($msg + "`n`nNothing valid was left, so the run was not started."), 'Network Toolkit', 'OK', 'Warning') | Out-Null
            return $null
        }
        $ans = [System.Windows.Forms.MessageBox]::Show(
            ($msg + ("`n`nContinue with just: {0}?" -f (@($ports) -join ', '))), 'Network Toolkit', 'OKCancel', 'Warning')
        if ($ans -ne 'OK') { return $null }
    }
    return [int[]]@($ports)
}

$btnTriage.Add_Click({
    $target = $txtTarget.Text.Trim()
    if (-not $target) {
        [System.Windows.Forms.MessageBox]::Show('Enter a device first - a name, an IP address or a MAC address.', 'Network Toolkit', 'OK', 'Information') | Out-Null
        return
    }
    $ntPorts = Get-NtPortsFromBox -Text $txtPorts.Text
    if ($null -eq $ntPorts) { return }
    $arguments = @{
        Target      = $target
        Peer        = $txtPeer.Text.Trim()
        Ports       = $ntPorts
        ProfileName = (Get-NtSelectedProfileName)
    }
    Start-NtWork -Kind 'triage' -Arguments $arguments -Body {
        param($NtArgs, $Sync)
        $prof = $null
        if ($NtArgs.ProfileName) { $prof = Get-NtSiteProfile -Name $NtArgs.ProfileName }
        $report = Invoke-NtPathTriage -Target $NtArgs.Target -Peer $NtArgs.Peer -Ports $NtArgs.Ports -Profile $prof -Shared $Sync

        # Anything learned about the local segment goes into the inventory too,
        # so a triage run contributes to cross-matching without a separate sweep.
        # The device's own name against its MAC goes FIRST: that pairing is
        # what lets the next "check by name" find it in history when it is off.
        try {
            $observed = [System.Collections.Generic.List[object]]::new()
            foreach ($o in @(ConvertTo-NtInventoryObservations -Identity $report.identity)) { $observed.Add($o) }
            $arpSection = @($report.sections | Where-Object { $_.name -eq 'ARP and layer 2' } | Select-Object -First 1)
            if ($arpSection.Count -gt 0 -and $arpSection[0].data) {
                foreach ($e in @($arpSection[0].data.Entries)) {
                    $observed.Add([pscustomobject]@{
                        IP = $e.IPAddress; Mac = $e.Mac; Vendor = $e.Vendor
                        Hostname = ''; Ttl = 0; OpenPorts = @(); TtlReading = $null
                    })
                }
            }
            if ($observed.Count -gt 0) {
                $siteName = if ($prof) { [string]$prof.site } else { '' }
                [void](Update-NtInventory -Hosts @($observed.ToArray()) -Site $siteName -Source 'triage')
            }
        } catch {}

        return $report
    }
})

$btnSweep.Add_Click({
    $spec = $txtTarget.Text.Trim()
    if (-not $spec) {
        [System.Windows.Forms.MessageBox]::Show('Enter an address, range, or CIDR in the Target box.', 'Network Toolkit', 'OK', 'Information') | Out-Null
        return
    }
    $ntPorts = Get-NtPortsFromBox -Text $txtPorts.Text
    if ($null -eq $ntPorts) { return }
    $resolved = Resolve-NtTargetSpec -Spec $spec
    if (-not $resolved.Ok) {
        # If it expanded to nothing there is nothing to confirm - "Sweep
        # anyway?" on a refused range would start a run over zero addresses
        # and report it as a completed sweep that found no hosts.
        if (@($resolved.Addresses).Count -eq 0) {
            [System.Windows.Forms.MessageBox]::Show($resolved.Reason, 'Network Toolkit', 'OK', 'Warning') | Out-Null
            return
        }
        $answer = [System.Windows.Forms.MessageBox]::Show(
            ("{0}`r`n`r`nSweep the {1} addresses it did expand to?" -f $resolved.Reason, @($resolved.Addresses).Count),
            'Network Toolkit', 'YesNo', 'Warning')
        if ($answer -ne 'Yes') { return }
    }

    $arguments = @{
        Spec        = $spec
        Ports       = $ntPorts
        ProfileName = (Get-NtSelectedProfileName)
    }
    Start-NtWork -Kind 'sweep' -Arguments $arguments -Body {
        param($NtArgs, $Sync)
        $resolved = Resolve-NtTargetSpec -Spec $NtArgs.Spec -Force
        if (-not $resolved.Ok -and @($resolved.Addresses).Count -eq 0) {
            throw ('Target could not be expanded: {0}' -f $resolved.Reason)
        }
        $prof = $null
        if ($NtArgs.ProfileName) { $prof = Get-NtSiteProfile -Name $NtArgs.ProfileName }
        $siteName = if ($prof) { [string]$prof.site } else { '' }

        $sweep = Invoke-NtSweep -Addresses $resolved.Addresses -Ports $NtArgs.Ports -ScanPorts -ResolveNames -Shared $Sync

        $Sync.Status = 'Updating inventory...'
        $update = Update-NtInventory -Hosts $sweep.data.Hosts -Site $siteName -Source ('sweep {0}' -f $NtArgs.Spec)
        $matches = @()
        if ($update.Inventory) {
            $matches = @(Get-NtInventoryMatches -Inventory $update.Inventory -CurrentHosts $sweep.data.Hosts)
        }
        return [pscustomobject]@{ Sweep = $sweep; Matches = $matches; Written = $update.Written }
    }
})

$btnRoutes.Add_Click({
    Start-NtWork -Kind 'routes' -Arguments @{} -Body {
        param($NtArgs, $Sync)
        $Sync.Status = 'Auditing routes...'
        return (Get-NtRouteAudit)
    }
})

$btnSaveBaseline.Add_Click({
    $siteName = Get-NtSelectedProfileName
    if (-not $siteName) { $siteName = 'default' }
    $target = $txtTarget.Text.Trim()
    $answer = [System.Windows.Forms.MessageBox]::Show(
        ("Save a baseline for site '{0}'?`r`n`r`nThis snapshots the current route table{1}. Do it while things are known good - it is what lets you answer 'what changed' later." -f $siteName, $(if ($target) { " and the path to $target" } else { '' })),
        'Save baseline', 'YesNo', 'Question')
    if ($answer -ne 'Yes') { return }

    Start-NtWork -Kind 'savebaseline' -Arguments @{ Site = $siteName; Target = $target } -Body {
        param($NtArgs, $Sync)
        $Sync.Status = 'Saving baseline...'
        $traceTargets = @()
        if ($NtArgs.Target) { $traceTargets = @($NtArgs.Target) }
        return (Save-NtBaseline -Site $NtArgs.Site -TraceTargets $traceTargets -Shared $Sync)
    }
})

$btnCompareBaseline.Add_Click({
    $siteName = Get-NtSelectedProfileName
    if (-not $siteName) { $siteName = 'default' }
    Start-NtWork -Kind 'baseline' -Arguments @{ Site = $siteName; Target = $txtTarget.Text.Trim() } -Body {
        param($NtArgs, $Sync)
        $Sync.Status = 'Comparing against baseline...'
        $traceTargets = @()
        if ($NtArgs.Target) { $traceTargets = @($NtArgs.Target) }
        return (Compare-NtBaseline -Site $NtArgs.Site -TraceTargets $traceTargets -Shared $Sync)
    }
})

function Get-NtAbTargets {
    # Whatever the tech is actually investigating: the target box, the peer box,
    # and anything the site profile names. Resolving all of them in both states
    # is what makes a source-address change visible.
    $list = [System.Collections.Generic.List[string]]::new()
    foreach ($box in @($txtTarget.Text, $txtPeer.Text)) {
        $value = $box.Trim()
        if ($value -and $list -notcontains $value) { $list.Add($value) }
    }
    return [string[]]@($list)
}

$btnCaptureA.Add_Click({
    $targets = Get-NtAbTargets
    if (@($targets).Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show('Put at least one address in the Target box first - the comparison resolves the path to it in both states.', 'Network Toolkit', 'OK', 'Information') | Out-Null
        return
    }
    Start-NtWork -Kind 'snapa' -Arguments @{ Targets = $targets } -Body {
        param($NtArgs, $Sync)
        return (New-NtStateSnapshot -Targets $NtArgs.Targets -Label 'A (as found)' -Shared $Sync)
    }
})

$btnCaptureB.Add_Click({
    if (-not $script:SnapshotA) {
        [System.Windows.Forms.MessageBox]::Show('Capture A first.', 'Network Toolkit', 'OK', 'Information') | Out-Null
        return
    }
    Start-NtWork -Kind 'snapb' -Arguments @{ Targets = Get-NtAbTargets; Before = $script:SnapshotA } -Body {
        param($NtArgs, $Sync)
        $after = New-NtStateSnapshot -Targets $NtArgs.Targets -Label 'B (after change)' -Shared $Sync
        return (Compare-NtStateSnapshot -Before $NtArgs.Before -After $after)
    }
})

$btnIfRefresh.Add_Click({
    # Cheap enough to run straight on the UI thread now that the local context
    # no longer goes through Get-NetIPConfiguration.
    try {
        $lblStatus.Text = 'Reading interfaces...'
        Show-NtInterfaces -Section (Get-NtInterfaceInventory)
        $lblStatus.Text = 'Interfaces refreshed.'
    } catch {
        $lblStatus.Text = ('Interface read failed: {0}' -f $_.Exception.Message)
    }
})

$btnCancel.Add_Click({
    $script:Sync.Cancel = $true
    $script:Sync.Status = 'Cancelling...'
    $lblStatus.Text = 'Cancelling...'
})

$btnCopyEsc.Add_Click({
    if ($txtEscalation.Text) {
        [System.Windows.Forms.Clipboard]::SetText($txtEscalation.Text)
        $lblStatus.Text = 'Escalation summary copied to the clipboard.'
    }
})

$btnExportJson.Add_Click({
    if (-not $script:Report -and -not $script:SweepResult) {
        [System.Windows.Forms.MessageBox]::Show('Nothing to export yet. Run Check device or a sweep first.', 'Network Toolkit', 'OK', 'Information') | Out-Null
        return
    }
    # Export what is on screen - the LAST run - not whichever variable happens
    # to be populated. Falls back sensibly if only one kind has ever run.
    $kind = $script:LastRunKind
    if (-not $kind) { $kind = if ($script:Report) { 'triage' } else { 'sweep' } }
    if ($kind -eq 'triage' -and -not $script:Report) { $kind = 'sweep' }
    if ($kind -eq 'sweep'  -and -not $script:SweepResult) { $kind = 'triage' }
    $payload = if ($kind -eq 'triage') { $script:Report } else { $script:SweepResult }

    # Say what is being exported BEFORE writing it. A stale run exported under
    # a fresh timestamp is indistinguishable from a current one afterwards.
    $what = if ($kind -eq 'triage') { ('triage of {0}' -f $script:Report.target) } else { 'network sweep' }
    $capturedAt = if ($script:LastRunAt) { $script:LastRunAt.ToString('yyyy-MM-dd HH:mm:ss') } else { 'unknown time' }
    $confirm = [System.Windows.Forms.MessageBox]::Show(
        ("Export this run?`n`nType     : {0}`nSubject  : {1}`nCaptured : {2}`nSource PC: {3}" -f $kind, $what, $capturedAt, $env:COMPUTERNAME),
        'Network Toolkit', 'OKCancel', 'Information')
    if ($confirm -ne 'OK') { return }

    $subject = if ($kind -eq 'triage') { [string]$script:Report.target } else { 'sweep' }
    $dialog = New-Object System.Windows.Forms.SaveFileDialog
    $dialog.Filter = 'JSON (*.json)|*.json'
    $dialog.FileName = ('NetToolkit_{0}_{1}_{2}_{3}.json' -f `
        $kind, $env:COMPUTERNAME, ($subject -replace '[^\w\.\-]', '_'), (Get-Date -Format 'yyyyMMdd_HHmmss'))
    if ($dialog.ShowDialog() -ne 'OK') { return }
    if (Write-NtJsonFile -Path $dialog.FileName -Object $payload -Depth 12) {
        $lblStatus.Text = ('Exported the {0} run to {1}' -f $kind, $dialog.FileName)
    } else {
        [System.Windows.Forms.MessageBox]::Show('Could not write that file.', 'Network Toolkit', 'OK', 'Error') | Out-Null
    }
})

$btnExportHtml.Add_Click({
    if (-not $script:Report) {
        [System.Windows.Forms.MessageBox]::Show('Run Check device first - the HTML report renders a device check (triage) report.', 'Network Toolkit', 'OK', 'Information') | Out-Null
        return
    }
    # In the single-file build the renderer is already compiled in, so only go
    # looking for the file when the function is genuinely absent.
    $renderer = Join-Path $scriptDir 'NetTool_HTML_Report.ps1'
    $haveRenderer = [bool](Get-Command -Name ConvertTo-NtHtmlReport -ErrorAction SilentlyContinue)
    if (-not $haveRenderer -and -not (Test-Path -LiteralPath $renderer)) {
        [System.Windows.Forms.MessageBox]::Show(('NetTool_HTML_Report.ps1 was not found beside this script.' -f $renderer), 'Network Toolkit', 'OK', 'Error') | Out-Null
        return
    }
    $dialog = New-Object System.Windows.Forms.SaveFileDialog
    $dialog.Filter = 'HTML (*.html)|*.html'
    $dialog.FileName = ('NetToolkit_{0}_{1}.html' -f ($script:Report.target -replace '[^\w\.\-]', '_'), (Get-Date -Format 'yyyyMMdd_HHmmss'))
    if ($dialog.ShowDialog() -ne 'OK') { return }
    try {
        # -NoGui: we want ConvertTo-NtHtmlReport, not the renderer's own picker.
        if (-not $haveRenderer) { . $renderer -NoGui }
        $html = ConvertTo-NtHtmlReport -Report $script:Report
        Set-Content -LiteralPath $dialog.FileName -Value $html -Encoding UTF8
        $lblStatus.Text = ('Exported to {0}' -f $dialog.FileName)
        $answer = [System.Windows.Forms.MessageBox]::Show('Report written. Open it now?', 'Network Toolkit', 'YesNo', 'Information')
        if ($answer -eq 'Yes') { Start-Process $dialog.FileName }
    } catch {
        [System.Windows.Forms.MessageBox]::Show(('HTML export failed: {0}' -f $_.Exception.Message), 'Network Toolkit', 'OK', 'Error') | Out-Null
    }
})

$btnFix.Add_Click({
    # Everything here is opt-in, confirmed individually, and reported afterwards.
    # Nothing on this form modifies the machine except through this button.
    if (-not (Test-NtElevated)) {
        [System.Windows.Forms.MessageBox]::Show('Remediation needs administrator rights. Re-launch the toolkit elevated.', 'Network Toolkit', 'OK', 'Warning') | Out-Null
        return
    }

    # Tie the offered actions to the run that produced them. A report can sit
    # on screen while the machine moves on underneath it - a lease renews, a
    # VPN drops - and the evidence behind a fix goes stale silently.
    $runAge = $null
    if ($script:LastRunAt) { $runAge = ((Get-Date) - $script:LastRunAt).TotalMinutes }
    if ($null -ne $runAge -and $runAge -gt 10) {
        $ans = [System.Windows.Forms.MessageBox]::Show(
            ("These actions come from a run captured {0:N0} minutes ago, and the evidence behind them has not been re-checked since.`n`nRe-run the triage first?" -f $runAge),
            'Network Toolkit', 'YesNoCancel', 'Warning')
        if ($ans -eq 'Cancel') { return }
        if ($ans -eq 'Yes') { $btnTriage.PerformClick(); return }
    }

    $actions = [System.Collections.Generic.List[object]]::new()
    if ($script:Report) {
        $routeSection = @($script:Report.sections | Where-Object { $_.name -eq 'Route audit' } | Select-Object -First 1)
        if ($routeSection.Count -gt 0 -and $routeSection[0].data) {
            foreach ($route in @($routeSection[0].data.Routes | Where-Object { $_.Status -eq 'fail' -and $_.DeleteCommand })) {
                $actions.Add([pscustomobject]@{
                    Label = ('Delete stale route {0} via {1}' -f $route.DestinationPrefix, $route.NextHop)
                    Kind  = 'DeleteRoute'
                    Data  = $route
                })
            }
        }
        $nameSection = @($script:Report.sections | Where-Object { $_.name -eq 'Name resolution' } | Select-Object -First 1)
        if ($nameSection.Count -gt 0 -and $nameSection[0].data) {
            foreach ($entry in @($nameSection[0].data.TargetHits | Where-Object { -not $_.Commented })) {
                $actions.Add([pscustomobject]@{
                    Label = ('Comment out hosts line {0}: {1} -> {2}' -f $entry.LineNumber, ($entry.Names -join ' '), $entry.IPAddress)
                    Kind  = 'CommentHostsLine'
                    Data  = $entry
                })
            }
        }
    }
    $actions.Add([pscustomobject]@{ Label = 'Flush the DNS resolver cache'; Kind = 'FlushDns'; Data = $null })
    $actions.Add([pscustomobject]@{ Label = 'Flush the ARP neighbour cache'; Kind = 'FlushArp'; Data = $null })
    $actions.Add([pscustomobject]@{ Label = 'Reload the NetBIOS name cache'; Kind = 'FlushNetbios'; Data = $null })

    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = 'Remediation - each item is confirmed before it runs'
    $dlg.Size = New-Object System.Drawing.Size(760, 420)
    $dlg.StartPosition = 'CenterParent'
    $dlg.BackColor = $NtColorPanel
    $dlg.Font = $NtFontUi

    $lblInfo = New-Object System.Windows.Forms.Label
    $lblInfo.Text = 'Tick what you want to change. The hosts file is backed up before it is edited. Nothing else here is reversible automatically.'
    $lblInfo.Location = New-Object System.Drawing.Point(12, 10)
    $lblInfo.Size = New-Object System.Drawing.Size(720, 34)
    $lblInfo.ForeColor = $NtColorMuted
    $dlg.Controls.Add($lblInfo)

    $clb = New-Object System.Windows.Forms.CheckedListBox
    $clb.Location = New-Object System.Drawing.Point(12, 50)
    $clb.Size = New-Object System.Drawing.Size(720, 270)
    $clb.CheckOnClick = $true
    foreach ($action in $actions) { [void]$clb.Items.Add($action.Label) }
    $dlg.Controls.Add($clb)

    $btnRun = New-Object System.Windows.Forms.Button
    $btnRun.Text = 'Run selected'
    $btnRun.Location = New-Object System.Drawing.Point(520, 332)
    $btnRun.Size = New-Object System.Drawing.Size(100, 30)
    $btnRun.DialogResult = 'OK'
    $dlg.Controls.Add($btnRun)

    $btnClose = New-Object System.Windows.Forms.Button
    $btnClose.Text = 'Cancel'
    $btnClose.Location = New-Object System.Drawing.Point(628, 332)
    $btnClose.Size = New-Object System.Drawing.Size(100, 30)
    $btnClose.DialogResult = 'Cancel'
    $dlg.Controls.Add($btnClose)
    $dlg.AcceptButton = $btnRun
    $dlg.CancelButton = $btnClose

    if ($dlg.ShowDialog() -ne 'OK') { return }

    $log = [System.Collections.Generic.List[string]]::new()
    for ($i = 0; $i -lt $clb.Items.Count; $i++) {
        if (-not $clb.GetItemChecked($i)) { continue }
        $action = $actions[$i]
        $confirm = [System.Windows.Forms.MessageBox]::Show(
            ("About to: {0}`r`n`r`nProceed?" -f $action.Label), 'Confirm', 'YesNo', 'Warning')
        if ($confirm -ne 'Yes') { $log.Add(('SKIPPED  {0}' -f $action.Label)); continue }

        $outcome = $null
        switch ($action.Kind) {
            'DeleteRoute'      { $outcome = Invoke-NtRemediation -Action 'DeleteRoute' -Prefix $action.Data.DestinationPrefix -NextHop $action.Data.NextHop -Confirm }
            'CommentHostsLine' { $outcome = Invoke-NtRemediation -Action 'CommentHostsLine' -LineNumber $action.Data.LineNumber -Confirm }
            default            { $outcome = Invoke-NtRemediation -Action $action.Kind -Confirm }
        }
        if ($outcome.Ok) {
            $line = ('OK       {0}' -f $action.Label)
            if ($outcome.Backup) { $line += (' (backup: {0})' -f $outcome.Backup) }
            $log.Add($line)
        } else {
            $log.Add(('FAILED   {0} - {1}' -f $action.Label, $outcome.Message))
        }
    }

    if ($log.Count -gt 0) {
        [System.Windows.Forms.MessageBox]::Show(($log -join [Environment]::NewLine), 'Remediation results', 'OK', 'Information') | Out-Null
        $lblStatus.Text = 'Remediation finished. Re-run the triage to confirm the change.'
    }
})

# =============================================================================
# Source indicator
# =============================================================================
# The address this machine is currently sourcing traffic from, in the title bar.
# It is the fact the whole inter-site case turned on, it changes silently when a
# VPN connects, and in a remote session there is otherwise nothing on screen to
# tell you which network you are actually on.
#
# Its own timer, always running, independent of the worker timer - which only
# runs during a job. One route lookup, measured at 37 ms, every 5 seconds.
$script:KindMap = $null
$script:LastTitle = ''

function Update-NtTitle {
    try {
        if (-not $script:KindMap) { $script:KindMap = Get-NtInterfaceKindMap }
        # Look up the route to the TARGET being worked on, not to 1.1.1.1.
        # A split tunnel or a second NIC can send those two destinations by
        # completely different paths, so the title was describing a route the
        # technician was not testing. Falls back to 1.1.1.1 only when there is
        # no usable target yet.
        $probe = '1.1.1.1'
        try {
            $t = ([string]$txtTarget.Text).Trim()
            if ($t -and (Test-NtIsIPv4 $t)) { $probe = $t }
        } catch { }
        $src = Get-NtCurrentSource -Probe $probe -InterfaceMap $script:KindMap

        # An index we have not seen means an adapter appeared (a VPN coming up
        # is the case that matters); rebuild the map once and re-read.
        if ($src.Ok -and -not $src.Kind -or ($src.Ok -and $src.InterfaceIndex -gt 0 -and -not $script:KindMap.ContainsKey($src.InterfaceIndex))) {
            $script:KindMap = Get-NtInterfaceKindMap
            $src = Get-NtCurrentSource -InterfaceMap $script:KindMap
        }

        # Name the destination the label is about. It is a route LOOKUP, not
        # evidence that anything was sent there.
        $title = ('{0} -> {1} - NetTool' -f $src.Label, $src.Probe)
        if ($title -ne $script:LastTitle) {
            $form.Text = $title
            $script:LastTitle = $title
        }
    } catch {
        # Never let the indicator take the form down.
        if ($script:LastTitle -ne 'Network Toolkit') {
            $form.Text = 'Network Toolkit'
            $script:LastTitle = 'Network Toolkit'
        }
    }
}

$titleTimer = New-Object System.Windows.Forms.Timer
$titleTimer.Interval = 5000
$titleTimer.Add_Tick({ Update-NtTitle })

# =============================================================================
# Startup
# =============================================================================

# Anchors are set in Add_Shown, NOT at construction time. Setting Anchor before
# the form has laid itself out makes controls inflate to odd sizes on the first
# resize, and the tool still launches, so it looks like a rendering glitch
# rather than a bug.
$form.Add_Shown({
    # An UNSELECTED tab page may not have laid out yet, and anchors set on its
    # controls would then record phantom margins. Device is the first page now,
    # so Triage - which used to be - is one of them. Lay every page out first.
    $firstPage = $tabs.SelectedTab
    foreach ($page in @($tabs.TabPages)) { $tabs.SelectedTab = $page; $page.PerformLayout() }
    $tabs.SelectedTab = $firstPage

    $panelTop.Anchor    = 'Top,Left,Right'
    $panelVerdict.Anchor= 'Top,Left,Right'
    $tabs.Anchor        = 'Top,Left,Right,Bottom'
    $panelBottom.Anchor = 'Bottom,Left,Right'

    $lblVerdict.Anchor    = 'Top,Left,Right'
    $lblVerdictSub.Anchor = 'Top,Left,Right'

    $panelDevCard.Anchor = 'Top,Left,Right'
    $lblDevHead.Anchor   = 'Top,Left,Right'
    $txtDevDetail.Anchor = 'Top,Left,Right'
    $lvDevAnswers.Anchor = 'Top,Left,Right'
    $lvDevFacts.Anchor   = 'Top,Left,Right,Bottom'

    $lvLadder.Anchor    = 'Top,Left,Right'
    $rtbFindings.Anchor = 'Top,Left,Right,Bottom'
    # The tab list views are Dock = Fill and must NOT be anchored - setting
    # Anchor clears Dock and reintroduces the sizing bug it was there to avoid.
    $txtEscalation.Anchor = 'Top,Left,Right,Bottom'
    $btnCopyEsc.Anchor    = 'Bottom,Left'

    $lblAb.Anchor      = 'Top,Left,Right'
    $lblAbState.Anchor = 'Top,Left,Right'
    $lvAb.Anchor       = 'Top,Left,Right,Bottom'

    # $lvPeer is Dock = Fill and must stay out of this list - assigning Anchor
    # clears Dock and brings back the sizing bug.
    $panelIfTop.Anchor   = 'Top,Left,Right'
    $lblIfSummary.Anchor = 'Top,Left,Right'
    $lvInterfaces.Anchor = 'Top,Left,Right,Bottom'

    # Deliberately NOT anchored: Set-NtButtonRow owns their position, and an
    # anchor would move them a second time on top of that.
    Set-NtButtonRow
    foreach ($button in @($btnSaveBaseline, $btnCompareBaseline, $btnFix, $btnExportJson, $btnExportHtml)) { $button.Anchor = 'Bottom,Right' }
    $lblStatus.Anchor = 'Bottom,Left'
    $progress.Anchor  = 'Bottom,Left'

    $txtTarget.Focus()

    # Show the source straight away rather than after the first 5 s tick, and
    # fill the Interfaces tab so it is useful before any triage has been run.
    Update-NtTitle
    $titleTimer.Start()
    try { Show-NtInterfaces -Section (Get-NtInterfaceInventory) } catch { }

    # LAST, and only now that every anchor above has recorded its margins
    # against the normal 1180-wide form. Maximising fires Add_Resize, which
    # re-runs Set-NtButtonRow against the new width.
    if (-not $NoMaximize) { $form.WindowState = 'Maximized' }
})

# Keep the button row hard against the right edge through every resize,
# maximise and restore.
$form.Add_Resize({ try { Set-NtButtonRow } catch { } })

$form.Add_FormClosing({
    $script:Sync.Cancel = $true
    try { $timer.Stop() } catch {}
    try { $titleTimer.Stop() } catch {}
    if ($script:Worker) {
        try { $script:Worker.Stop() } catch {}
        try { $script:Worker.Dispose() } catch {}
    }
})

# Populate the site profile list, and pre-select whichever profile matches the
# subnet this machine is currently on.

# What the profile last wrote into each box. Anything the technician typed
# themselves must survive a profile change - overwriting explicit input is how
# a run ends up testing a destination nobody asked for.
$script:ProfileFilled = @{ Target = ''; Peer = ''; Ports = '' }

function Set-NtProfileFields {
    # Fill the input boxes from a profile, WITHOUT clobbering anything the
    # operator typed. A box is safe to overwrite only if it is empty or still
    # holds exactly what a profile put there.
    param($Profile, [switch]$Announce)
    if (-not $Profile) { return }
    $kept = [System.Collections.Generic.List[string]]::new()
    $first = @($Profile.targets | Select-Object -First 1)
    if (@($Profile.targets).Count -gt 1) {
        $kept.Add(('the profile defines {0} targets; the first is shown' -f @($Profile.targets).Count))
    }
    if ($first.Count -gt 0) {
        $t = $first[0]
        $pairs = @(
            @{ Box = $txtTarget; Key = 'Target'; Value = [string]$t.ip;    Label = 'target' }
            @{ Box = $txtPeer;   Key = 'Peer';   Value = [string]$t.peer;  Label = 'peer' }
            @{ Box = $txtPorts;  Key = 'Ports';  Value = $(if ($t.ports) { (@($t.ports) -join ',') } else { '' }); Label = 'ports' }
        )
        foreach ($pair in $pairs) {
            if (-not $pair.Value) { continue }
            $cur = [string]$pair.Box.Text
            if ($cur -and $cur -ne $script:ProfileFilled[$pair.Key]) {
                $kept.Add(('your {0} "{1}" was kept' -f $pair.Label, $cur))
                continue
            }
            $pair.Box.Text = $pair.Value
            $script:ProfileFilled[$pair.Key] = $pair.Value
        }
    }

    # Validate, and say so. Test-NtSiteProfile existed and was never called,
    # so a malformed subnet or a target with no ip went unreported.
    $v = Test-NtSiteProfile -Profile $Profile
    $bits = [System.Collections.Generic.List[string]]::new()
    if (@($v.Problems).Count -gt 0) { $bits.Add(('PROBLEMS: ' + (@($v.Problems) -join ' '))) }
    # Values the profile itself flags as assumptions rather than facts.
    $unconf = @(Get-NtProfileCaveats -Profile $Profile | Where-Object { $_.Unconfirmed })
    if ($unconf.Count -gt 0) {
        $bits.Add(('{0} value(s) in this profile are marked UNCONFIRMED: {1}' -f $unconf.Count, ((@($unconf | ForEach-Object { $_.Field })) -join ', ')))
    }
    if (@($v.Warnings).Count -gt 0) { $bits.Add((@($v.Warnings) -join ' ')) }
    if ($kept.Count -gt 0) { $bits.Add(('Kept your input: ' + ($kept -join '; '))) }

    if ($Announce) {
        $head = ('Site profile "{0}" loaded.' -f $Profile.site)
        if (@($v.Problems).Count -gt 0) { $head = ('Site profile "{0}" has problems.' -f $Profile.site) }
        $lblVerdictSub.Text = ($head + ' ' + ($bits -join ' '))
    }
}

try {
    [void]$cboProfile.Items.Add('(none)')
    $profiles = @(Get-NtSiteProfileList)
    foreach ($prof in $profiles) { [void]$cboProfile.Items.Add([string]$prof.site) }
    $cboProfile.SelectedIndex = 0

    # Selecting a profile after startup did NOTHING - there was no
    # SelectedIndexChanged handler at all, so the dropdown looked functional
    # and only ever applied whatever matched at launch.
    $cboProfile.Add_SelectedIndexChanged({
        try {
            $name = [string]$cboProfile.SelectedItem
            if (-not $name -or $name -eq '(none)') {
                $lblVerdictSub.Text = 'No site profile selected - every value must be entered by hand.'
                return
            }
            $sel = Get-NtSiteProfile -Name $name
            if (-not $sel) {
                $lblVerdictSub.Text = ('Site profile "{0}" could not be loaded.' -f $name)
                return
            }
            Set-NtProfileFields -Profile $sel -Announce
        } catch {
            $lblVerdictSub.Text = ('Could not apply that profile: {0}' -f $_.Exception.Message)
        }
    })

    $auto = $null
    if ($Site) { $auto = Get-NtSiteProfile -Name $Site } else { $auto = Get-NtSiteProfile }
    if ($auto) {
        $idx = $cboProfile.Items.IndexOf([string]$auto.site)
        if ($idx -ge 0) { $cboProfile.SelectedIndex = $idx }   # fires the handler above
        $lblVerdictSub.Text = ('Site profile "{0}" matched this machine automatically. {1}' -f $auto.site, $lblVerdictSub.Text)
    }
} catch { }

if (-not (Test-NtElevated)) {
    $lblStatus.Text = 'Ready (not elevated - route and ARP remediation are unavailable).'
}

# Warm the networking CIM modules BEFORE the window appears.
#
# The first Get-NetIPInterface / Get-NetAdapter in a process pays about four
# seconds of module autoloading; every call after it costs a quarter of a
# second. Add_Shown reads the interfaces and the current source, so without this
# the form would appear and then freeze solid for those four seconds, which
# reads as a broken tool. Paying it here instead means the window is responsive
# the moment it is drawn.
try { $null = Get-NtLocalContext } catch { }

[void]$form.ShowDialog()
$form.Dispose()
