# NetTool 1.0.1 - https://ihavenoram.com - https://github.com/ihavenoram/nettool
# MIT licence, (c) 2026 ihavenoram.com. If you publish something built on this, please credit ihavenoram.com.
<#
.SYNOPSIS
    All-in-one network troubleshooting toolkit - shared logic.

.DESCRIPTION
    Function definitions ONLY. Dot-source this file; it must have no side
    effects at load, because it is also loaded as TEXT and rebuilt inside every
    background runspace the GUI starts. One definition serves the UI thread and
    all workers.

    Built from the notes of a real inter-site case. Section references in the
    comments below ("runbook 4.5") point at those notes, which are not published.

.NOTES
    Windows PowerShell 5.1. ASCII only - a non-ASCII character in a BOM-less
    file changes how 5.1 parses the rest of the script.

    Everything here is READ-ONLY except Invoke-NtRemediation, which refuses to
    act unless explicitly asked.
#>

function Get-NtVersion { '1.0.0' }

# =============================================================================
# 1. Report primitives
# =============================================================================
# The report is data, not text. Every surface (GUI, HTML, JSON) renders the
# same objects, so a finding cannot appear in one and not another.

function ConvertTo-NtIso8601 {
    param([datetime]$Value = (Get-Date))
    $Value.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
}

function New-NtRow {
    # One line of evidence. Status drives the colour; Detail carries the "why".
    param(
        [string]$Group,
        [string]$Check,
        [string]$Result,
        [ValidateSet('ok','warn','fail','info')][string]$Status = 'info',
        [string]$Detail = '',
        $Data = $null
    )
    [pscustomobject]@{
        group  = $Group
        check  = $Check
        result = $Result
        status = $Status
        detail = $Detail
        data   = $Data
    }
}

function New-NtSection {
    # A section that did not run must say WHY. A section reading "unsupported"
    # with no reason is worse than no section: the reader cannot tell a
    # limitation of the tool from a finding about the network.
    param(
        [string]$Name,
        [ValidateSet('measured','failed','skipped','unsupported','refused')]
        [string]$State = 'measured',
        [string]$Reason = '',
        [string]$Method = '',
        [string[]]$Caveats = @(),
        $Rows = @(),
        $Data = $null,
        [datetime]$StartedUtc = [datetime]::MinValue,
        [double]$DurationSec = 0
    )
    if ($State -ne 'measured' -and [string]::IsNullOrWhiteSpace($Reason)) {
        $Reason = 'No reason recorded - that is a bug in this tool, not a finding about the network.'
    }
    $started = $null
    if ($StartedUtc -ne [datetime]::MinValue) { $started = ConvertTo-NtIso8601 $StartedUtc }
    [pscustomobject]@{
        name        = $Name
        state       = $State
        reason      = $(if ([string]::IsNullOrWhiteSpace($Reason)) { $null } else { $Reason })
        method      = $Method
        caveats     = [object[]]$Caveats
        rows        = [object[]]$Rows
        data        = $Data
        startedUtc  = $started
        durationSec = [math]::Round($DurationSec, 2)
    }
}

function New-NtFinding {
    # A CONCLUSION, as opposed to an observation. Evidence is the list of row
    # checks that support it, so the reader can audit the reasoning instead of
    # taking the verdict on faith.
    param(
        [string]$Title,
        [ValidateSet('critical','high','medium','low','info')][string]$Severity = 'info',
        [ValidateSet('confirmed','probable','possible')][string]$Confidence = 'probable',
        [string]$Summary,
        [string[]]$Evidence = @(),
        # WHAT THIS CONCLUSION RESTS ON.
        #
        # -Evidence is a list of section NAMES: a pointer for a human, useful
        # for navigation and nothing else. It cannot express "this conclusion
        # requires the selected route to be the same for both hosts", so
        # nothing stopped a branch asserting exactly that while the four
        # measurements proving it sat computed-but-unread 300 lines away.
        #
        #   -Basis       measurements that were taken and support this.
        #   -Assumptions things taken as true WITHOUT measuring them. Every
        #                entry here is a way this conclusion can be wrong, and
        #                it is rendered as such rather than hidden.
        [string[]]$Basis = @(),
        [string[]]$Assumptions = @(),
        [string]$Action = '',
        [string[]]$Commands = @()
    )
    [pscustomobject]@{
        title       = $Title
        severity    = $Severity
        confidence  = $Confidence
        summary     = $Summary
        evidence    = [object[]]$Evidence
        basis       = [object[]]$Basis
        assumptions = [object[]]$Assumptions
        action      = $Action
        commands    = [object[]]$Commands
    }
}

function Get-NtNeighbourConfidence {
    # What does a neighbour-cache entry actually PROVE?
    #
    # Microsoft distinguishes these states for a reason, and this tool
    # collected the state and then ignored it: any entry at all was read as
    # "answers ARP, so it is powered on and connected". An Unreachable entry
    # says the opposite, and a Stale one says only that the host answered at
    # some point in the past - possibly before the fault started.
    #
    #   Reachable  - confirmed within the reachable time. Proof of life.
    #   Permanent  - a static entry. Proves someone configured it, nothing more.
    #   Stale      - was reachable once; not confirmed recently.
    #   Delay/Probe- resolution in progress; not yet confirmed.
    #   Unreachable- resolution was attempted and FAILED.
    param([string]$State)
    $out = [pscustomobject]@{ State = $State; ProvesLife = $false; Status = 'info'; Detail = '' }
    switch -Regex ([string]$State) {
        '^Reachable$' {
            $out.ProvesLife = $true; $out.Status = 'ok'
            $out.Detail = 'Confirmed reachable at layer 2 within the neighbour reachable time, so the host is powered on and on this VLAN even if it ignores ICMP.'
        }
        '^Permanent$' {
            $out.Status = 'info'
            $out.Detail = 'A STATIC neighbour entry. It was configured, not learned, so it proves someone added it - not that the host is present.'
        }
        '^(Stale|Delay|Probe)$' {
            $out.Status = 'info'
            $out.Detail = ('State is {0}: this host answered at some point, but the entry has not been confirmed recently. It is evidence the address was in use, not evidence it is alive now - and on an intermittent fault that distinction is the whole question.' -f $State)
        }
        '^Unreachable$' {
            $out.Status = 'warn'
            $out.Detail = 'State is Unreachable: Windows attempted to resolve this address and FAILED. An entry exists, but it records a failure, not a presence.'
        }
        default {
            $out.Detail = ('Neighbour state {0} is not one this tool interprets; treat the entry as unconfirmed.' -f $State)
        }
    }
    return $out
}

function Test-NtSameNetwork {
    # Are two addresses in the same network? Three answers, not two.
    #
    # The old test compared the first three octets as STRINGS, which is a /24
    # assumption dressed as a fact: it accepts two hosts in different /25s and
    # rejects two hosts in the same /23. It is also silent about the
    # assumption on the path that matters - a MATCH was reported as plain
    # 'ok' with no mention that /24 had been assumed.
    #
    # Returns Same = $true / $false / $null, where $null means "the mask is
    # not known, so this cannot be answered". Unknown must stay unknown: it is
    # the difference between a control test and a guess.
    param(
        [string]$AddressA,
        [string]$AddressB,
        [string]$Cidr = ''      # e.g. 10.50.40.0/23. Empty = mask unknown.
    )
    $out = [pscustomobject]@{ Same = $null; Basis = ''; Assumed = $false }
    if ([string]::IsNullOrWhiteSpace($AddressA) -or [string]::IsNullOrWhiteSpace($AddressB)) {
        $out.Basis = 'One of the two addresses is missing.'
        return $out
    }
    if ($AddressA -eq $AddressB) {
        $out.Same = $true
        $out.Basis = 'Both names resolve to the same address - this is not a comparison, it is the same host twice.'
        return $out
    }
    if ($Cidr -match '^(\d+\.\d+\.\d+\.\d+)/(\d+)$') {
        $net = $matches[1]; $len = [int]$matches[2]
        $a = ConvertTo-NtUInt32 $AddressA
        $b = ConvertTo-NtUInt32 $AddressB
        $n = ConvertTo-NtUInt32 $net
        if ($null -ne $a -and $null -ne $b -and $null -ne $n -and $len -ge 0 -and $len -le 32) {
            $mask = if ($len -eq 0) { [uint32]0 } else { [uint32]([uint32]::MaxValue -shl (32 - $len)) }
            $inA = (($a -band $mask) -eq ($n -band $mask))
            $inB = (($b -band $mask) -eq ($n -band $mask))
            $out.Same = ($inA -and $inB)
            $out.Basis = ('Membership tested against the stated destination network {0}.' -f $Cidr)
            return $out
        }
    }
    $out.Basis = 'No destination network was given, and the remote mask cannot be seen from here. Whether these two addresses share a subnet is UNKNOWN - they may be in different /25s, or in the same /23.'
    return $out
}

function Get-NtPeerComparability {
    # Were the target and the peer actually asked the same question, over the
    # same path, from the same source?
    #
    # "Same subnet, same transport, same rules" was asserted by the conclusion
    # engine without ever being tested. All four facts are measured - they are
    # in DiffSection.data as RouteSame / NextHopSame / SourceSame /
    # InterfaceSame - and simply were not read. This reads them and reports
    # which hold, so a conclusion can require them instead of assuming them.
    param($Evidence)
    $out = [pscustomobject]@{
        Comparable  = $false      # every dimension matched
        Checked     = $false      # a comparison was possible at all
        Basis       = @()         # dimensions measured AND matching
        Differences = @()         # dimensions measured and NOT matching
        Assumptions = @()         # dimensions that could not be measured
    }
    $dd = $null
    if ($Evidence -and $Evidence.DiffSection -and $Evidence.DiffSection.data) { $dd = $Evidence.DiffSection.data }
    if (-not $dd) {
        $out.Assumptions = @(
            'The target and the peer were assumed to take the same route, next hop, source address and interface. No side-by-side comparison was produced, so none of that was checked.'
        )
        return $out
    }
    $out.Checked = $true
    $basis = [System.Collections.Generic.List[string]]::new()
    $diffs = [System.Collections.Generic.List[string]]::new()
    $dims = @(
        @{ K = 'RouteSame';     Same = 'Windows selects the same route for both hosts.';        Diff = 'Windows selects a DIFFERENT route for each host.' }
        @{ K = 'NextHopSame';   Same = 'Both hosts leave via the same next hop.';               Diff = 'The two hosts leave via DIFFERENT next hops.' }
        @{ K = 'SourceSame';    Same = 'Both are sourced from the same local address.';         Diff = 'They are sourced from DIFFERENT local addresses, so the far end sees a different client for each.' }
        @{ K = 'InterfaceSame'; Same = 'Both leave by the same interface.';                     Diff = 'They leave by DIFFERENT interfaces.' }
    )
    foreach ($d in $dims) {
        if ($null -eq $dd.($d.K)) { $out.Assumptions += ('{0} could not be compared.' -f $d.K); continue }
        if ($dd.($d.K)) { $basis.Add($d.Same) } else { $diffs.Add($d.Diff) }
    }
    $out.Basis = [object[]]$basis.ToArray()
    $out.Differences = [object[]]$diffs.ToArray()
    $out.Comparable = ($diffs.Count -eq 0 -and $basis.Count -eq 4)
    # Matching local routes still do not rule out per-DESTINATION local policy.
    if ($out.Comparable) {
        $out.Assumptions = @(
            'Identical local routing does not rule out a local firewall or security policy scoped to one destination address rather than to a subnet.',
            'Both hosts are assumed to offer the service that was probed. A host that simply does not run it is indistinguishable here from one that is blocked.'
        )
    }
    return $out
}

function Get-NtStats {
    # Min/mean/max/median over a set of samples. Returns zeroes for an empty
    # set rather than throwing, because "no replies" is a normal result here.
    param([double[]]$Values = @())
    $vals = @($Values)
    if ($vals.Count -eq 0) {
        return [pscustomobject]@{ N = 0; Min = 0.0; Mean = 0.0; Max = 0.0; Median = 0.0 }
    }
    $sorted = @($vals | Sort-Object)
    $mid = [int][math]::Floor($sorted.Count / 2)
    $median = if ($sorted.Count % 2 -eq 1) { $sorted[$mid] } else { ($sorted[$mid - 1] + $sorted[$mid]) / 2 }
    [pscustomobject]@{
        N      = $sorted.Count
        Min    = [double]($sorted[0])
        Mean   = [double](($vals | Measure-Object -Average).Average)
        Max    = [double]($sorted[$sorted.Count - 1])
        Median = [double]$median
    }
}

function Test-NtElevated {
    try {
        $id = [Security.Principal.WindowsIdentity]::GetCurrent()
        (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole(
            [Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch { $false }
}

# =============================================================================
# 2. Address maths
# =============================================================================
# Needed constantly below (is this next hop on-link? is this range routed?) and
# there is no built-in that answers it, so it lives here once.

function ConvertTo-NtUInt32 {
    param([string]$IPAddress)
    try {
        $bytes = ([System.Net.IPAddress]::Parse($IPAddress)).GetAddressBytes()
        if ($bytes.Length -ne 4) { return $null }
        # GetAddressBytes returns network order; BitConverter reads host order.
        [Array]::Reverse($bytes)
        return [System.BitConverter]::ToUInt32($bytes, 0)
    } catch { return $null }
}

function ConvertFrom-NtUInt32 {
    param([uint32]$Value)
    $bytes = [System.BitConverter]::GetBytes($Value)
    [Array]::Reverse($bytes)
    (New-Object System.Net.IPAddress(,$bytes)).ToString()
}

function Test-NtIpInPrefix {
    # Is $IPAddress inside $Prefix (CIDR, e.g. 192.168.10.0/24)?
    param([string]$IPAddress, [string]$Prefix)
    if (-not $IPAddress -or -not $Prefix) { return $false }
    $parts = $Prefix -split '/'
    if ($parts.Count -ne 2) { return $false }
    $len = 0
    if (-not [int]::TryParse($parts[1], [ref]$len)) { return $false }
    if ($len -lt 0 -or $len -gt 32) { return $false }
    $net = ConvertTo-NtUInt32 $parts[0]
    $ip  = ConvertTo-NtUInt32 $IPAddress
    if ($null -eq $net -or $null -eq $ip) { return $false }
    if ($len -eq 0) { return $true }
    $mask = [uint32]([uint32]::MaxValue -shl (32 - $len))
    return (($ip -band $mask) -eq ($net -band $mask))
}

function Test-NtIsIPv4 {
    param([string]$Value)
    if (-not $Value) { return $false }
    $parsed = [ref]([System.Net.IPAddress]::None)
    if (-not [System.Net.IPAddress]::TryParse($Value, $parsed)) { return $false }
    return ($parsed.Value.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork)
}

# =============================================================================
# 3. Local context - what this machine thinks its network is
# =============================================================================
# Runbook Trap 2: get the config dump BEFORE building a model. Every theory
# about wired-vs-wireless in the original case died to a single ipconfig /all.

function Get-NtDefaultRoutes {
    # Every 0.0.0.0/0 route, best first.
    #
    # "The active adapter" is not "the first Up adapter". Windows chooses by
    # RouteMetric PLUS the interface metric, so both are summed here rather than
    # sorting on RouteMetric alone. More than one default route is exactly the
    # condition that makes any "it works now" result uninterpretable.
    param()
    $out = [System.Collections.Generic.List[object]]::new()
    try { $routes = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction Stop }
    catch { return @() }

    foreach ($r in $routes) {
        $ifMetric = 0
        try {
            $ifx = Get-NetIPInterface -InterfaceIndex $r.InterfaceIndex -AddressFamily IPv4 -ErrorAction Stop |
                   Select-Object -First 1
            if ($ifx) { $ifMetric = [int]$ifx.InterfaceMetric }
        } catch {}
        $out.Add([pscustomobject]@{
            InterfaceIndex  = [int]$r.InterfaceIndex
            InterfaceAlias  = [string]$r.InterfaceAlias
            NextHop         = [string]$r.NextHop
            RouteMetric     = [int]$r.RouteMetric
            InterfaceMetric = $ifMetric
            TotalMetric     = ([int]$r.RouteMetric + $ifMetric)
        })
    }
    return @($out | Sort-Object TotalMetric, RouteMetric)
}

function Get-NtVpnIndicators {
    # Runbook Trap 4: while a client VPN is connected the endpoint has a second
    # path to the destination, so ANY "it works now" result is uninterpretable.
    # This is not a nice-to-have warning - it decides whether the rest of the
    # report can be believed, so callers downgrade every conclusion when it fires.
    param()
    $out = [pscustomobject]@{
        # Suspected is now VPN/OVERLAY ONLY. It used to be set by
        # ($adapters -or $routes.Count -gt 1), so a laptop with Ethernet and
        # Wi-Fi both up - two default routes, no VPN anywhere - raised a
        # high/confirmed "an alternate path is live" banner that dominated
        # every real finding beneath it. Both of the supplied printer captures
        # show exactly that: two defaults via one gateway, VPN adapter list
        # empty.
        Suspected        = $false   # a VPN or overlay adapter is UP
        MultipleDefaults = $false   # more than one default route exists
        DefaultsShareNextHop = $false
        Routes    = @()
        Adapters  = @()
        Detail    = ''
    }
    $routes = @(Get-NtDefaultRoutes)
    $out.Routes = [object[]]$routes

    $susp = [System.Collections.Generic.List[string]]::new()
    $pattern = Get-NtVpnAdapterPattern
    try {
        foreach ($a in @(Get-NetAdapter -ErrorAction Stop | Where-Object { $_.Status -eq 'Up' })) {
            $desc = ('{0} {1}' -f $a.Name, $a.InterfaceDescription)
            if ($desc -match $pattern) {
                $susp.Add(('{0} ({1})' -f $a.Name, $a.InterfaceDescription))
            }
        }
    } catch {}
    $out.Adapters = [object[]]$susp

    $out.Suspected = ($susp.Count -gt 0)
    $out.MultipleDefaults = ($routes.Count -gt 1)
    if ($routes.Count -gt 1) {
        # Two defaults via the SAME next hop is a dual-homed machine reaching
        # one gateway two ways - ordinary, and not a second path anywhere.
        # Two defaults via DIFFERENT next hops genuinely are two paths.
        $hops = @(@($routes | ForEach-Object { [string]$_.NextHop }) | Sort-Object -Unique)
        $out.DefaultsShareNextHop = ($hops.Count -le 1)
    }

    $parts = [System.Collections.Generic.List[string]]::new()
    if ($routes.Count -gt 1) {
        if ($out.DefaultsShareNextHop) {
            $parts.Add(('There are {0} default routes, but they all point at the same next hop ({1}), so this machine is dual-homed to ONE gateway rather than having two paths off-site. Windows will use "{2}" (total metric {3}).' -f `
                $routes.Count, [string]$routes[0].NextHop, $routes[0].InterfaceAlias, $routes[0].TotalMetric))
        } else {
            $parts.Add(('There are {0} default routes via DIFFERENT next hops. Windows will send off-subnet traffic via "{1}" (total metric {2}), but a second way off this machine exists and may carry some traffic.' -f `
                $routes.Count, $routes[0].InterfaceAlias, $routes[0].TotalMetric))
        }
    }
    if ($susp.Count -gt 0) {
        $parts.Add(('VPN or overlay adapters are UP: {0}. With a second path live, a successful test proves nothing about the path you are trying to fix.' -f ($susp -join '; ')))
    }
    if ($parts.Count -eq 0) {
        $parts.Add('One default route and no VPN or overlay adapters up, so the path measured here is the real one.')
    }
    # An unrecognised split-tunnel VPN adds no default route and may not match
    # the adapter pattern either, so absence of evidence is not evidence here.
    if (-not $out.Suspected) {
        $parts.Add('Note that a split-tunnel VPN need not add a default route, and an unrecognised client may not be named here at all - this check can miss one.')
    }
    $out.Detail = ($parts -join ' ')
    return $out
}

function Get-NtVpnAdapterPattern {
    # One definition, used by the VPN warning, the link classifier, and the
    # route binding analysis. They must never disagree about what a VPN is.
    # \b-anchored on the short and generic tokens. Unanchored, 'vpn' matches
    # inside ordinary product names, 'pulse' matches "Pulseway" and "Impulse",
    # and 'tunnel' matches almost any virtual adapter description - each one
    # producing a false "an alternate path is live" that outranks the real
    # finding. Used by the VPN warning, the link classifier and the route
    # binding analysis, which must never disagree about what a VPN is.
    '(?i)\bvpn|zerotier|tailscale|wireguard|openvpn|anyconnect|globalprotect|forticlient|\bpulse\b|sonicwall|tap-windows|nordlynx|expressvpn|\bmeraki\b|velocloud|zscaler|netextender|softether|wintun|\btunnel\b'
}

function Get-NtLinkKind {
    # Short tag for what KIND of link an interface is: WiFi, LAN, VPN, WWAN,
    # Virtual, Loopback, Other.
    #
    # Order matters. A VPN adapter almost always presents itself as Ethernet
    # (InterfaceType 6), so classifying on the hardware type first would file
    # every tunnel under LAN. Hyper-V and VMware switches do the same, which is
    # why Virtual is tested before LAN too - on this developer machine
    # "vEthernet (Default Switch)" is InterfaceType 6 with MediaType 802.3 and
    # is emphatically not a LAN connection.
    param(
        [string]$Alias = '',
        [string]$Description = '',
        [int]$InterfaceType = 0,
        [string]$PhysicalMediaType = ''
    )
    $text = ('{0} {1}' -f $Alias, $Description)

    if ($InterfaceType -eq 24) { return 'Loopback' }
    if ($text -match '(?i)loopback') { return 'Loopback' }
    if ($text -match (Get-NtVpnAdapterPattern)) { return 'VPN' }
    if ($InterfaceType -eq 71 -or $PhysicalMediaType -match '(?i)802\.11|native wifi') { return 'WiFi' }
    if ($InterfaceType -eq 243 -or $InterfaceType -eq 244 -or $PhysicalMediaType -match '(?i)wwan|wireless wan') { return 'WWAN' }
    if ($text -match '(?i)vethernet|hyper-v|virtualbox|vmware|npcap|loopback adapter|virtual adapter|docker') { return 'Virtual' }
    # Bluetooth PAN reports InterfaceType 6 like any Ethernet adapter, but
    # calling it LAN would put it beside a real wired connection in the report.
    if ($PhysicalMediaType -match '(?i)bluetooth' -or $text -match '(?i)bluetooth') { return 'Other' }
    if ($InterfaceType -eq 6) { return 'LAN' }
    return 'Other'
}

function Get-NtLocalContext {
    # Adapters, addresses, connected subnets, gateways, DNS, DHCP, domain.
    # ConnectedPrefixes is the load-bearing output: the route auditor uses it to
    # decide whether a static route's next hop is reachable at all.
    #
    # Built from four cheap cmdlets rather than Get-NetIPConfiguration, which
    # measured 2.3 s alone and over 6 s as this function used it (it re-queries
    # per adapter). The replacements total well under 100 ms and, importantly,
    # Get-NetIPInterface enumerates EVERY IPv4 interface - including
    # disconnected ones and loopback, which Get-NetIPConfiguration omits and
    # which are exactly what the interface inventory and the route binding
    # analysis need.
    #
    # Adapters keeps its original meaning (interfaces holding an IPv4 address)
    # so every existing caller behaves identically; AllInterfaces is the new,
    # complete list.
    param()

    $prefixes = [System.Collections.Generic.List[string]]::new()
    $gateways = [System.Collections.Generic.List[string]]::new()
    $dns      = [System.Collections.Generic.List[string]]::new()

    # --- index-keyed lookups, one cmdlet call each -------------------------
    $ifByIndex = @{}
    try {
        foreach ($ifx in @(Get-NetIPInterface -AddressFamily IPv4 -ErrorAction Stop)) {
            $ifByIndex[[int]$ifx.InterfaceIndex] = $ifx
        }
    } catch {}

    $adByIndex = @{}
    try {
        foreach ($ad in @(Get-NetAdapter -ErrorAction Stop)) {
            $adByIndex[[int]$ad.InterfaceIndex] = $ad
        }
    } catch {}

    $addrByIndex = @{}
    try {
        foreach ($addr in @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction Stop)) {
            $idx = [int]$addr.InterfaceIndex
            if (-not $addrByIndex.ContainsKey($idx)) {
                $addrByIndex[$idx] = [System.Collections.Generic.List[object]]::new()
            }
            $addrByIndex[$idx].Add($addr)
        }
    } catch {}

    $dnsByIndex = @{}
    try {
        foreach ($entry in @(Get-DnsClientServerAddress -AddressFamily IPv4 -ErrorAction Stop)) {
            $dnsByIndex[[int]$entry.InterfaceIndex] = @($entry.ServerAddresses | Where-Object { Test-NtIsIPv4 $_ })
        }
    } catch {}

    $defaults = @(Get-NtDefaultRoutes)
    $gwByIndex = @{}
    foreach ($route in $defaults) {
        $idx = [int]$route.InterfaceIndex
        if (-not $gwByIndex.ContainsKey($idx)) { $gwByIndex[$idx] = [string]$route.NextHop }
        if ($route.NextHop -and $route.NextHop -ne '0.0.0.0' -and $gateways -notcontains $route.NextHop) {
            $gateways.Add([string]$route.NextHop)
        }
    }

    # --- build one record per interface ------------------------------------
    $all = [System.Collections.Generic.List[object]]::new()
    foreach ($idx in @($ifByIndex.Keys)) {
        $ifx = $ifByIndex[$idx]
        $ad  = $(if ($adByIndex.ContainsKey($idx)) { $adByIndex[$idx] } else { $null })

        $alias = [string]$ifx.InterfaceAlias
        $desc  = ''
        $mac   = ''
        $speed = ''
        $ifType = 0
        $media  = ''
        $status = [string]$ifx.ConnectionState   # Connected / Disconnected
        if ($ad) {
            $desc   = [string]$ad.InterfaceDescription
            $mac    = [string]$ad.MacAddress
            $speed  = [string]$ad.LinkSpeed
            $status = [string]$ad.Status          # Up / Disconnected / Disabled
            try { $ifType = [int]$ad.InterfaceType } catch {}
            try { $media  = [string]$ad.PhysicalMediaType } catch {}
        }
        if (-not $desc) { $desc = $alias }

        $ips = [System.Collections.Generic.List[object]]::new()
        foreach ($addr in @($addrByIndex[$idx])) {
            if (-not $addr) { continue }
            $ip = [string]$addr.IPAddress
            if (-not (Test-NtIsIPv4 $ip)) { continue }
            $plen = 24
            try { $plen = [int]$addr.PrefixLength } catch {}

            $ipInt = ConvertTo-NtUInt32 $ip
            $prefix = ''
            if ($null -ne $ipInt -and $plen -ge 0 -and $plen -le 32) {
                $mask = if ($plen -eq 0) { [uint32]0 } else { [uint32]([uint32]::MaxValue -shl (32 - $plen)) }
                $prefix = ('{0}/{1}' -f (ConvertFrom-NtUInt32 ($ipInt -band $mask)), $plen)
            }
            $ips.Add([pscustomobject]@{ IPAddress = $ip; PrefixLength = $plen; Prefix = $prefix })
        }

        $ifDns = @()
        if ($dnsByIndex.ContainsKey($idx)) { $ifDns = @($dnsByIndex[$idx]) }

        $kind = Get-NtLinkKind -Alias $alias -Description $desc -InterfaceType $ifType -PhysicalMediaType $media

        $record = [pscustomobject]@{
            InterfaceIndex       = [int]$idx
            InterfaceAlias       = $alias
            InterfaceDescription = $desc
            Status               = $status
            ConnectionState      = [string]$ifx.ConnectionState
            InterfaceKind        = $kind
            # True only for a real NIC. Get-NetIPInterface also enumerates
            # loopback and hidden pseudo-interfaces (WAN miniports, the
            # "Local Area Connection* n" entries); those must not be treated as
            # network adapters or their addresses counted as on-link, which is
            # how Get-NetIPConfiguration behaved before this rewrite.
            HasAdapter           = ($null -ne $ad)
            MacAddress           = $mac
            LinkSpeed            = $speed
            InterfaceMetric      = $(try { [int]$ifx.InterfaceMetric } catch { 0 })
            Mtu                  = $(try { [int]$ifx.NlMtu } catch { 0 })
            Dhcp                 = [string]$ifx.Dhcp
            Addresses            = [object[]]@($ips)
            DefaultGateway       = $(if ($gwByIndex.ContainsKey($idx)) { $gwByIndex[$idx] } else { '' })
            DnsServers           = [object[]]$ifDns
        }
        $all.Add($record)

        # Only real adapters holding an address contribute prefixes and DNS.
        # Loopback is never a path to anything, and letting 127.0.0.0/8 into
        # ConnectedPrefixes would make the route auditor call a 127.x next hop
        # "on-link".
        if (@($ips).Count -gt 0 -and $record.HasAdapter -and $kind -ne 'Loopback') {
            foreach ($entry in @($ips)) {
                if ($entry.Prefix -and $prefixes -notcontains $entry.Prefix) { $prefixes.Add($entry.Prefix) }
            }
            foreach ($server in $ifDns) { if ($dns -notcontains $server) { $dns.Add([string]$server) } }
        }
    }

    # Adapters keeps its pre-rewrite meaning: real NICs holding an IPv4 address.
    $adapters = @(@($all) | Where-Object { @($_.Addresses).Count -gt 0 -and $_.HasAdapter -and $_.InterfaceKind -ne 'Loopback' })

    $domain = ''; $joined = $false
    try {
        $cs = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
        $domain = [string]$cs.Domain
        $joined = [bool]$cs.PartOfDomain
    } catch {}

    $dhcpServer = ''
    try {
        $nic = Get-CimInstance -ClassName Win32_NetworkAdapterConfiguration -Filter 'IPEnabled = True' -ErrorAction Stop |
               Where-Object { $_.DHCPEnabled -and $_.DHCPServer } |
               Select-Object -First 1
        if ($nic) { $dhcpServer = [string]$nic.DHCPServer }
    } catch {}

    [pscustomobject]@{
        ComputerName      = $env:COMPUTERNAME
        UserName          = $env:USERNAME
        CollectedUtc      = ConvertTo-NtIso8601 (Get-Date)
        Elevated          = (Test-NtElevated)
        Adapters          = [object[]]@($adapters)
        AllInterfaces     = [object[]]@($all | Sort-Object InterfaceIndex)
        ConnectedPrefixes = [object[]]@($prefixes)
        Gateways          = [object[]]@($gateways)
        DnsServers        = [object[]]@($dns)
        DhcpServer        = $dhcpServer
        Domain            = $domain
        DomainJoined      = $joined
        DefaultRoutes     = [object[]]$defaults
    }
}
function Get-NtPrimaryGateway {
    # The gateway off-subnet traffic will actually use, not merely the first found.
    param($Context = $null)
    if (-not $Context) { $Context = Get-NtLocalContext }
    foreach ($r in @($Context.DefaultRoutes)) {
        if ($r.NextHop -and $r.NextHop -ne '0.0.0.0') { return [string]$r.NextHop }
    }
    $gws = @($Context.Gateways)
    if ($gws.Count -gt 0) { return [string]$gws[0] }
    return ''
}

# =============================================================================
# 4. Route audit - runbook Fault A
# =============================================================================
# The original case had endpoints carrying:
#
#     10.60.100.0/24  via 10.50.8.1
#     10.50.8.0/24     via 172.24.7.102
#
# 172.24.7.102 is a MAIN SITE address, reachable only while the user's client
# VPN is up. So the chain was never viable from the new building's LAN, which is
# precisely why the symptom read as "it only works on VPN".
#
# Two properties of that fault matter for the code below:
#   1. It is a CHAIN. Checking 10.50.8.1 alone says "not on-link" and stops;
#      the useful answer is "its next hop resolves through another static route
#      which is itself unreachable".
#   2. Persistent routes survive rebuilds and rarely get documented, so the
#      PersistentStore is read separately rather than inferred from the live table.

function Test-NtCimEmptyResult {
    # Did this CIM error mean "nothing matched" rather than "the query
    # failed"?
    #
    # Get-NetRoute -PolicyStore PersistentStore THROWS when there are no
    # persistent routes, which is the normal state of a machine with no static
    # routes. Treating that as a collection failure would report "the route
    # store could not be read" on a perfectly healthy PC - the same class of
    # mistake as treating an untested endpoint as a failed one, in the
    # opposite direction.
    param($ErrorRecord)
    if (-not $ErrorRecord) { return $false }
    try {
        if ([string]$ErrorRecord.CategoryInfo.Category -eq 'ObjectNotFound') { return $true }
    } catch { }
    return [bool]([string]$ErrorRecord.Exception.Message -match '(?i)No MSFT_\w+ objects found')
}

function Get-NtRouteKey {
    # The identity of a route.
    #
    # This used to be prefix + next hop, which is not unique: Ethernet and
    # Wi-Fi routinely hold IDENTICAL default routes via the same gateway, and
    # a VPN can add a third. Two different routes therefore collided on one
    # key, and the Store column - the distinction the entire audit turns on -
    # was decided by whichever one happened to be looked up. A PersistentOnly
    # route could read as Active because a DIFFERENT interface carried the
    # same prefix and gateway.
    #
    # Address family is included so a v6 route can never alias a v4 one when
    # this is extended.
    param($Route, [string]$Family = 'IPv4')
    $ifIx = 0
    try { $ifIx = [int]$Route.InterfaceIndex } catch { }
    return ('{0}|{1}|{2}|{3}' -f $Family, [string]$Route.DestinationPrefix, [string]$Route.NextHop, $ifIx)
}

function Get-NtRouteTable {
    # Live table and persistent table, kept apart on purpose. A route present in
    # both is normal; a route present ONLY in the persistent store is one that
    # failed to install (usually because its interface is gone).
    param()
    $active = [System.Collections.Generic.List[object]]::new()
    $persist = [System.Collections.Generic.List[object]]::new()
    # A provider failure used to leave both lists empty, which downstream reads
    # as "this machine has no routes" - a confident statement about the network
    # produced by a failure to ask the question.
    $errors = [System.Collections.Generic.List[string]]::new()
    $okActive = $false
    $okPersist = $false

    $mk = {
        param($r, $store)
        $alias = ''
        try { $alias = [string]$r.InterfaceAlias } catch {}
        [pscustomobject]@{
            DestinationPrefix = [string]$r.DestinationPrefix
            NextHop           = [string]$r.NextHop
            InterfaceIndex    = [int]$r.InterfaceIndex
            InterfaceAlias    = $alias
            RouteMetric       = [int]$r.RouteMetric
            Protocol          = [string]$r.Protocol
            Store             = $store
        }
    }

    try {
        foreach ($r in @(Get-NetRoute -AddressFamily IPv4 -PolicyStore ActiveStore -ErrorAction Stop)) {
            $active.Add((& $mk $r 'Active'))
        }
        $okActive = $true
    } catch {
        # An EMPTY store is not a failure. Get-NetRoute throws ObjectNotFound
        # when nothing matches, which on a machine with no static routes is
        # the ordinary case - so "there are none" and "the query failed"
        # arrive as the same exception and must be told apart here.
        if (Test-NtCimEmptyResult -ErrorRecord $_) { $okActive = $true }
        else { $errors.Add(('The ACTIVE route table could not be read: {0}' -f $_.Exception.Message)) }
    }

    try {
        foreach ($r in @(Get-NetRoute -AddressFamily IPv4 -PolicyStore PersistentStore -ErrorAction Stop)) {
            $persist.Add((& $mk $r 'Persistent'))
        }
        $okPersist = $true
    } catch {
        if (Test-NtCimEmptyResult -ErrorRecord $_) { $okPersist = $true }
        else { $errors.Add(('The PERSISTENT route store could not be read: {0}' -f $_.Exception.Message)) }
    }

    [pscustomobject]@{
        Active     = [object[]]@($active)
        Persistent = [object[]]@($persist)
        # Ok distinguishes "there are no routes" from "the question failed".
        Ok         = ($okActive -and $okPersist)
        Errors     = [object[]]@($errors.ToArray())
    }
}

function Get-NtInterfaceStateMap {
    # InterfaceIndex -> everything the route auditor needs to know about the
    # interface a route is bound to, including interfaces that are DOWN. A
    # persistent route pointing at a disconnected VPN adapter has to be
    # distinguishable from one pointing at an index that no longer exists.
    #
    # Built from Get-NtLocalContext so there is one definition of what an
    # interface is; pass -Context when you already have one to avoid re-reading.
    param($Context = $null)
    if (-not $Context) { $Context = Get-NtLocalContext }

    $map = @{}
    foreach ($ifc in @($Context.AllInterfaces)) {
        $idx = [int]$ifc.InterfaceIndex
        $prefixes = [System.Collections.Generic.List[string]]::new()
        $addresses = [System.Collections.Generic.List[string]]::new()
        foreach ($entry in @($ifc.Addresses)) {
            if ($entry.IPAddress) { $addresses.Add([string]$entry.IPAddress) }
            if ($entry.Prefix -and $prefixes -notcontains $entry.Prefix) { $prefixes.Add([string]$entry.Prefix) }
        }
        $map[$idx] = [pscustomobject]@{
            InterfaceIndex = $idx
            InterfaceAlias = [string]$ifc.InterfaceAlias
            Description    = [string]$ifc.InterfaceDescription
            Kind           = [string]$ifc.InterfaceKind
            Status         = [string]$ifc.ConnectionState
            Metric         = [int]$ifc.InterfaceMetric
            Mtu            = [int]$ifc.Mtu
            HasAdapter     = [bool]$ifc.HasAdapter
            Prefixes       = $prefixes
            Addresses      = $addresses
        }
    }
    return $map
}

function Get-NtInterfaceInventory {
    # Every IPv4 interface, connected or not.
    #
    # The Endpoint view deliberately shows only adapters that are Up and hold an
    # address. That is the right summary and the wrong thing to reason about a
    # dormant route with: the disconnected VPN adapter a route is bound to is
    # precisely the object you need on screen, and it is the one the summary
    # hides.
    param($Context = $null)
    if (-not $Context) { $Context = Get-NtLocalContext }

    $rows = [System.Collections.Generic.List[object]]::new()
    $connectedWithAddress = 0

    foreach ($ifc in @($Context.AllInterfaces | Sort-Object InterfaceIndex)) {
        $addresses = @(@($ifc.Addresses) | ForEach-Object { '{0}/{1}' -f $_.IPAddress, $_.PrefixLength })
        $isConnected = ($ifc.ConnectionState -eq 'Connected')
        $hasAddress  = (@($ifc.Addresses).Count -gt 0)
        $isApipa     = (@(@($ifc.Addresses) | Where-Object { Test-NtIpInPrefix -IPAddress ([string]$_.IPAddress) -Prefix '169.254.0.0/16' }).Count -gt 0)

        # Virtual switches and loopback are not alternative paths off this
        # machine, so they must not inflate the multi-homed warning - otherwise
        # every workstation with Hyper-V installed looks dual-homed.
        if ($isConnected -and $hasAddress -and -not $isApipa -and
            $ifc.InterfaceKind -notin @('Loopback', 'Virtual')) { $connectedWithAddress++ }

        $status = 'info'
        $detail = ''
        if ($isConnected -and $isApipa) {
            $status = 'warn'
            $detail = 'Automatic private address (169.254.x). The interface is connected but DHCP did not answer, so it has no usable configuration.'
        } elseif ($isConnected -and -not $hasAddress) {
            $status = 'warn'
            $detail = 'Connected but holds no IPv4 address.'
        } elseif ($isConnected) {
            $status = 'ok'
            $detail = ('Connected, metric {0}, MTU {1}.' -f $ifc.InterfaceMetric, $ifc.Mtu)
        } else {
            $detail = 'Not connected. Routes bound to this interface are not installed, and will install if it comes up.'
        }
        if (-not $ifc.HasAdapter -and $ifc.InterfaceKind -ne 'Loopback') {
            $detail += ' No physical adapter behind this index - a hidden or pseudo interface.'
        }
        if ($ifc.Mtu -gt 0 -and $ifc.Mtu -lt 1500) {
            $detail += (' MTU is {0}, below the usual 1500. Large packets may be dropped where small ones and ping pass.' -f $ifc.Mtu)
            if ($status -eq 'ok') { $status = 'warn' }
        }

        $rows.Add((New-NtRow -Group 'Interfaces' -Check ('{0} [{1}]' -f $ifc.InterfaceAlias, $ifc.InterfaceIndex) -Result ('{0} / {1}{2}' -f $ifc.InterfaceKind, $ifc.ConnectionState, $(if ($addresses.Count) { '  ' + ($addresses -join ', ') } else { '' })) -Status $status -Detail $detail -Data $ifc))
    }

    $caveats = [System.Collections.Generic.List[string]]::new()
    $caveats.Add('IPv4 only. Every interface is listed, including disconnected ones and loopback - that is the point of this view.')
    if ($connectedWithAddress -gt 1) {
        $caveats.Add(('{0} interfaces are connected and hold a routable address. On a multi-homed machine Windows chooses between them on interface metric, and traffic can leave by a different one than you expect.' -f $connectedWithAddress))
    }

    return (New-NtSection -Name 'Interfaces' -State 'measured' -Method 'Get-NetIPInterface for every IPv4 interface, joined to Get-NetAdapter, Get-NetIPAddress and Get-DnsClientServerAddress by interface index.' -Rows @($rows) -Data ([pscustomobject]@{
        Interfaces        = [object[]]@($Context.AllInterfaces | Sort-Object InterfaceIndex)
        MultiHomed        = ($connectedWithAddress -gt 1)
        ConnectedWithAddr = $connectedWithAddress
    }) -Caveats @($caveats))
}

function Resolve-NtNextHopReachability {
    # Can this machine actually deliver a packet to $NextHop right now?
    #
    # Walks the chain, because that is where the real fault lives. $Depth guards
    # against a pair of static routes pointing at each other, which is rare but
    # produces an infinite loop rather than a wrong answer if left unguarded.
    param(
        [string]$NextHop,
        $RouteTable = $null,
        $IfMap = $null,
        [int]$Depth = 0,
        # Next hops already passed through on this chain, so a genuine loop
        # can be distinguished from a chain that is merely long.
        $Visited = $null
    )
    if (-not $RouteTable) { $RouteTable = Get-NtRouteTable }
    if (-not $IfMap)      { $IfMap = Get-NtInterfaceStateMap }

    $res = [pscustomobject]@{
        NextHop  = $NextHop
        Verdict  = 'Unreachable'
        Detail   = ''
        ViaRoute = ''
        Chain    = @()
    }

    if (-not $NextHop -or $NextHop -eq '0.0.0.0' -or $NextHop -eq '::') {
        $res.Verdict = 'OnLink'
        $res.Detail  = 'Directly attached - no next hop required.'
        return $res
    }
    # A LOOP is a next hop we have already visited. Depth alone does not prove
    # one - it proves only that the chain is longer than we followed - and
    # this used to state "the static routes point at each other" as fact after
    # eight hops, which is a different claim with a different remedy.
    if ($Visited -and $Visited.Contains($NextHop)) {
        $res.Verdict = 'ChainBroken'
        $res.Detail  = ('Next-hop resolution returned to {0}, which it had already passed through - these static routes point at each other.' -f $NextHop)
        return $res
    }
    if ($Depth -gt 8) {
        $res.Verdict = 'Indeterminate'
        $res.Detail  = 'The next-hop chain is more than 8 routes deep, so resolution stopped following it. That is not a loop - no address repeated - it just could not be resolved from here.'
        return $res
    }
    if (-not $Visited) { $Visited = [System.Collections.Generic.List[string]]::new() }
    $Visited.Add($NextHop)

    # 1. Is it on-link for an interface that is UP?
    #
    # Every candidate is collected before deciding. The first match used to
    # win outright, so a DISCONNECTED adapter holding the same prefix - a
    # dormant VPN or an unplugged NIC - could be enumerated first and produce
    # "InterfaceDown" while a connected interface carried the same subnet
    # perfectly well. Hash enumeration order is not a routing decision.
    $onLinkUp = $null; $onLinkDown = $null
    foreach ($idx in $IfMap.Keys) {
        $ifc = $IfMap[$idx]
        foreach ($p in @($ifc.Prefixes)) {
            if (-not (Test-NtIpInPrefix -IPAddress $NextHop -Prefix $p)) { continue }
            if ($ifc.Status -eq 'Connected') {
                if (-not $onLinkUp) { $onLinkUp = [pscustomobject]@{ If = $ifc; Prefix = $p } }
            } elseif (-not $onLinkDown) {
                $onLinkDown = [pscustomobject]@{ If = $ifc; Prefix = $p }
            }
        }
    }
    if ($onLinkUp) {
        $res.Verdict = 'DirectlyReachable'
        $res.Detail  = ('On-link on {0} ({1}), which is connected.' -f $onLinkUp.If.InterfaceAlias, $onLinkUp.Prefix)
        return $res
    }
    if ($onLinkDown) {
        $res.Verdict = 'InterfaceDown'
        $res.Detail  = ('On-link only on {0} ({1}), and that interface is {2} - no connected interface carries this subnet. This is the signature of a route that works only while a VPN or secondary link is up.' -f $onLinkDown.If.InterfaceAlias, $onLinkDown.Prefix, $onLinkDown.If.Status)
        return $res
    }

    # 2. Is it covered by a more specific route? Longest prefix wins, and the
    #    default route is excluded here so we can report "only the default
    #    covers this" as its own, more informative case.
    $best = $null; $bestLen = -1
    foreach ($r in @($RouteTable.Active)) {
        $dp = [string]$r.DestinationPrefix
        if ($dp -eq '0.0.0.0/0' -or -not $dp) { continue }
        $len = 0
        $parts = $dp -split '/'
        if ($parts.Count -ne 2) { continue }
        if (-not [int]::TryParse($parts[1], [ref]$len)) { continue }
        if (Test-NtIpInPrefix -IPAddress $NextHop -Prefix $dp) {
            if ($len -gt $bestLen) { $bestLen = $len; $best = $r }
        }
    }

    if ($best) {
        $res.ViaRoute = ('{0} via {1}' -f $best.DestinationPrefix, $best.NextHop)
        if ($best.NextHop -eq '0.0.0.0') {
            $res.Verdict = 'DirectlyReachable'
            $res.Detail  = ('Covered by on-link route {0} on {1}.' -f $best.DestinationPrefix, $best.InterfaceAlias)
            return $res
        }
        $inner = Resolve-NtNextHopReachability -NextHop $best.NextHop -RouteTable $RouteTable -IfMap $IfMap -Depth ($Depth + 1) -Visited $Visited
        $chain = [System.Collections.Generic.List[string]]::new()
        $chain.Add($res.ViaRoute)
        foreach ($c in @($inner.Chain)) { $chain.Add([string]$c) }
        $res.Chain = [object[]]@($chain)

        # 'ViaRoute' and 'ViaDefaultGateway' are REACHABLE verdicts. Accepting
        # only DirectlyReachable/OnLink meant a chain two routes deep - each
        # link of it fine - was reported as ChainBroken, i.e. a working
        # configuration declared faulty because the recursion would not accept
        # its own successful result.
        if ($inner.Verdict -in @('DirectlyReachable', 'OnLink', 'ViaRoute', 'ViaDefaultGateway')) {
            $res.Verdict = 'ViaRoute'
            $res.Detail  = ('Reached through {0}, whose own next hop is reachable ({1}).' -f $res.ViaRoute, $inner.Verdict)
        } else {
            $res.Verdict = 'ChainBroken'
            $res.Detail  = ('Reached only through {0}, and THAT route is not usable: {1}' -f $res.ViaRoute, $inner.Detail)
        }
        return $res
    }

    # 3. Only the default route covers it.
    $defaults = @(Get-NtDefaultRoutes)
    if ($defaults.Count -gt 0) {
        $res.Verdict = 'ViaDefaultGateway'
        $res.Detail  = ('No specific route covers this address, so it would be sent to the default gateway {0}.' -f $defaults[0].NextHop)
        if (Test-NtIsPrivateAddress $NextHop) {
            # "Very unlikely" was an assumption about someone else's network.
            # Routing private ranges onward is exactly what an enterprise
            # gateway, a site-to-site tunnel or an SD-WAN edge is for - which
            # is the normal case at every multi-site customer this tool is
            # pointed at.
            $res.Detail += ' It is a private address with no specific route, so whether it is deliverable depends entirely on whether the gateway routes that range onward - which enterprise gateways, site-to-site tunnels and SD-WAN edges commonly do. This cannot be determined from this machine.'
        }
        return $res
    }

    $res.Verdict = 'Unreachable'
    $res.Detail  = 'Not on-link, not covered by any route, and there is no default route.'
    return $res
}

function Test-NtIsPrivateAddress {
    param([string]$IPAddress)
    if (-not (Test-NtIsIPv4 $IPAddress)) { return $false }
    foreach ($p in @('10.0.0.0/8','172.16.0.0/12','192.168.0.0/16','169.254.0.0/16','127.0.0.0/8')) {
        if (Test-NtIpInPrefix -IPAddress $IPAddress -Prefix $p) { return $true }
    }
    return $false
}

function ConvertTo-NtRouteDeleteCommand {
    # The exact command a technician would run. Returned as a STRING and never
    # executed unless Invoke-NtRemediation is called explicitly.
    param([string]$DestinationPrefix, [string]$NextHop = '')
    $parts = $DestinationPrefix -split '/'
    if ($parts.Count -ne 2) { return ('route delete {0}' -f $DestinationPrefix) }
    $len = 0
    if (-not [int]::TryParse($parts[1], [ref]$len)) { return ('route delete {0}' -f $parts[0]) }
    $mask = if ($len -eq 0) { [uint32]0 } else { [uint32]([uint32]::MaxValue -shl (32 - $len)) }
    $maskStr = ConvertFrom-NtUInt32 $mask
    if ($NextHop -and $NextHop -ne '0.0.0.0') {
        return ('route delete {0} mask {1} {2}' -f $parts[0], $maskStr, $NextHop)
    }
    return ('route delete {0} mask {1}' -f $parts[0], $maskStr)
}

function Get-NtRouteAudit {
    # Every non-default, non-system route with a verdict.
    #
    # Windows generates a large number of routes it manages itself (on-link
    # /32s, broadcast, multicast, loopback). Auditing those produces pages of
    # noise, so they are filtered out and counted rather than listed.
    param($Context = $null)
    if (-not $Context) { $Context = Get-NtLocalContext }

    $table = Get-NtRouteTable
    $ifMap = Get-NtInterfaceStateMap
    $rows  = [System.Collections.Generic.List[object]]::new()
    $audited = [System.Collections.Generic.List[object]]::new()

    # Persistent routes are keyed so the live table can be cross-referenced.
    $persistKeys = @{}
    foreach ($p in @($table.Persistent)) {
        $persistKeys[(Get-NtRouteKey -Route $p)] = $p
    }

    $noise = 0
    $candidates = [System.Collections.Generic.List[object]]::new()

    foreach ($r in @($table.Active)) {
        $dp = [string]$r.DestinationPrefix
        if (-not $dp) { continue }
        if ($dp -eq '0.0.0.0/0') { $candidates.Add($r); continue }
        # Windows-managed noise.
        if ($dp -match '^(224\.|255\.255\.255\.255|127\.)') { $noise++; continue }
        if ($dp -match '/32$' -and $r.NextHop -eq '0.0.0.0') { $noise++; continue }
        # Connected-subnet routes are NOT filtered. They cannot be stale, but a
        # technician reading the grid needs to see which subnets this machine
        # believes are on-link before any verdict about a next hop makes sense.
        $candidates.Add($r)
    }

    # A persistent route whose interface no longer exists never reaches the live
    # table at all, so it must be picked up from the persistent store directly.
    foreach ($p in @($table.Persistent)) {
        $seen = $false
        foreach ($c in @($candidates)) {
            if ((Get-NtRouteKey -Route $c) -eq (Get-NtRouteKey -Route $p)) { $seen = $true; break }
        }
        if (-not $seen) { $candidates.Add($p) }
    }

    # Which addresses are actually IN the forwarding table. This is the
    # distinction the whole audit turns on - see the header comment above.
    $activeKeys = @{}
    foreach ($a in @($table.Active)) {
        $activeKeys[(Get-NtRouteKey -Route $a)] = $true
    }

    foreach ($r in @($candidates)) {
        $dp = [string]$r.DestinationPrefix
        $isDefault = ($dp -eq '0.0.0.0/0')
        $key = Get-NtRouteKey -Route $r

        $inActive     = $activeKeys.ContainsKey($key)
        $inPersistent = $persistKeys.ContainsKey($key) -or ($r.Store -eq 'Persistent')
        $store = if ($inActive -and $inPersistent) { 'Both' }
                 elseif ($inActive)                { 'Active' }
                 else                              { 'PersistentOnly' }
        $isPersistent = $inPersistent

        $reach = Resolve-NtNextHopReachability -NextHop ([string]$r.NextHop) -RouteTable $table -IfMap $ifMap

        $verdict = 'OK'
        $status  = 'ok'
        $note    = $reach.Detail

        switch ($reach.Verdict) {
            'OnLink'            { $verdict = 'OnLink';           $status = 'ok' }
            'DirectlyReachable' { $verdict = 'Reachable';        $status = 'ok' }
            'ViaRoute'          { $verdict = 'Reachable';        $status = 'ok' }
            'InterfaceDown'     { $verdict = 'VpnDependent';     $status = 'warn' }
            'ChainBroken'       { $verdict = 'StaleUnreachable'; $status = 'fail' }
            'Unreachable'       { $verdict = 'StaleUnreachable'; $status = 'fail' }
            'Indeterminate'     { $verdict = 'Unresolved';       $status = 'info' }
            'ViaDefaultGateway' {
                if (Test-NtIsPrivateAddress ([string]$r.NextHop)) {
                    # NOT a failure. A private next hop with no specific route
                    # is deliverable exactly when the gateway routes that
                    # range onward - which is what a site-to-site tunnel or an
                    # SD-WAN edge does for a living, and this tool cannot see
                    # the far side of the gateway to check. Calling it
                    # StaleUnreachable/fail condemned a normal multi-site
                    # configuration and put a route-delete command next to it.
                    $verdict = 'ViaDefaultUnverified'; $status = 'warn'
                } else {
                    $verdict = 'ViaDefault'; $status = 'info'
                }
            }
        }

        if ($isDefault) {
            $verdict = 'Default'
            $status  = 'ok'
            $note    = 'Default route.'
        }

        # THE distinction. A route sitting in the persistent store that Windows
        # has NOT installed is not steering anything - it cannot be the cause of
        # a fault happening right now, however bad its next hop looks. Reporting
        # it as a live failure sends the reader after the wrong thing, which is
        # exactly what happened on the case this tool was built from.
        # Keep the raw next-hop assessment before it is overridden below, so a
        # caller can still tell "residue that would break if installed" from
        # "residue that is harmless".
        $nextHopVerdict = $verdict
        $nextHopStatus  = $status

        # --- binding: WHICH interface is this route attached to? -----------
        # The transcript singles this out: a route on a VPN adapter tells a
        # different story from the same route on the physical NIC. It also
        # answers, from one snapshot, a question that otherwise needs a second
        # visit with the VPN connected.
        $ifIdx  = [int]$r.InterfaceIndex
        $ifRec  = $(if ($ifMap.ContainsKey($ifIdx)) { $ifMap[$ifIdx] } else { $null })
        $ifKind = $(if ($ifRec) { [string]$ifRec.Kind } else { '' })
        $ifState = 'Missing'
        if ($ifRec) { $ifState = [string]$ifRec.Status }
        $ifMetric = $(if ($ifRec) { [int]$ifRec.Metric } else { 0 })
        $ifAliasResolved = $(if ($ifRec) { [string]$ifRec.InterfaceAlias } else { [string]$r.InterfaceAlias })

        $bindingFlag = ''
        $bindingNote = ''

        if ($r.Protocol -eq 'Dhcp') {
            # DHCP option 121 pushes classless static routes. Deleting one on
            # the endpoint looks like it worked and comes straight back at the
            # next lease renewal, so the delete suggestion is actively wrong.
            $bindingFlag = 'DhcpSupplied'
            $bindingNote = ' Supplied by DHCP (option 121), not configured on this machine. Deleting it locally will appear to work and it will return at the next lease renewal - correct the DHCP scope instead.'
        }
        elseif (-not $ifRec) {
            $bindingFlag = 'OrphanedInterface'
            $bindingNote = (' Bound to interface index {0}, which no longer exists on this machine. It can never be installed, so it is inert and safe to remove - no VPN test needed.' -f $ifIdx)
        }
        elseif ($ifState -ne 'Connected') {
            $bindingFlag = 'BoundToDisconnected'
            if ($ifKind -eq 'VPN') {
                $bindingNote = (' Bound to "{0}", a VPN or overlay adapter that is currently disconnected. It WILL be installed when that adapter connects - which is the mechanism behind a destination that only works while the VPN is up.' -f $ifAliasResolved)
            } else {
                $bindingNote = (' Bound to "{0}", which is {1}. It will be installed if that interface comes up.' -f $ifAliasResolved, $ifState)
            }
        }
        elseif (-not $isDefault -and $r.NextHop -and $r.NextHop -ne '0.0.0.0') {
            # Connected interface, but is the next hop even on THIS interface?
            $onOwnLink = $false
            foreach ($p in @($ifRec.Prefixes)) {
                if (Test-NtIpInPrefix -IPAddress ([string]$r.NextHop) -Prefix $p) { $onOwnLink = $true; break }
            }
            if (-not $onOwnLink -and $nextHopStatus -eq 'fail') {
                $bindingFlag = 'MisboundNextHop'
                $bindingNote = (' Bound to "{0}" ({1}, connected), but {2} is not on any subnet that interface holds. This route IS installed and still cannot deliver - the usual cause is a route added by hand against the wrong adapter.' -f $ifAliasResolved, $ifKind, $r.NextHop)
            }
        }

        $severityNote = ''
        if ($store -eq 'PersistentOnly') {
            if ($status -eq 'fail' -or $status -eq 'warn') {
                $severityNote = ' NOT INSTALLED: this route is configured in the persistent store but is absent from the active forwarding table, so it is not steering traffic and is not the cause of any current failure. The next-hop assessment above describes what WOULD happen if it were installed'
                # Do not promise it might come back when the binding analysis
                # has already established that it cannot.
                if ($bindingFlag -eq 'OrphanedInterface') {
                    $severityNote += '.'
                } else {
                    $severityNote += ' - which Windows may do when a VPN or interface comes up.'
                }
            } else {
                $severityNote = ' Configured but not installed in the active forwarding table.'
            }
            $verdict = 'PersistentNotActive'
            $status  = 'warn'
        } elseif ($isPersistent -and $status -eq 'fail') {
            $severityNote = ' This route is active AND persistent: it is breaking this destination now, and it survives reboots and rebuilds.'
        }

        $deleteCmd = ''
        $fixHint   = ''
        if ($bindingFlag -eq 'DhcpSupplied') {
            # Deliberately NO delete command. See the binding note above.
            $fixHint = 'Fix the DHCP scope (option 121, classless static routes). Do not delete this on the endpoint.'
        } elseif (-not $isDefault -and $verdict -in @('StaleUnreachable', 'VpnDependent')) {
            # Only where the next hop is demonstrably not deliverable from
            # here. It used to be offered for any warn, which included
            # ViaDefaultUnverified - a route that is very likely fine - so the
            # tool suggested deleting working configuration on the strength of
            # a guess about the far side of the gateway.
            $deleteCmd = ConvertTo-NtRouteDeleteCommand -DestinationPrefix $dp -NextHop ([string]$r.NextHop)
        }

        $entry = [pscustomobject]@{
            DestinationPrefix = $dp
            NextHop           = [string]$r.NextHop
            InterfaceAlias    = $ifAliasResolved
            InterfaceIndex    = [int]$r.InterfaceIndex
            InterfaceKind     = $ifKind
            InterfaceState    = $ifState
            InterfaceMetric   = $ifMetric
            RouteMetric       = [int]$r.RouteMetric
            TotalMetric       = ([int]$r.RouteMetric + $ifMetric)
            BindingFlag       = $bindingFlag
            FixHint           = $fixHint
            Protocol          = [string]$r.Protocol
            Persistent        = $isPersistent
            Store             = $store
            InActiveTable     = $inActive
            NextHopVerdict    = $nextHopVerdict
            NextHopStatus     = $nextHopStatus
            Verdict           = $verdict
            Status            = $status
            Detail            = ($note + $severityNote + $bindingNote)
            Chain             = [object[]]@($reach.Chain)
            DeleteCommand     = $deleteCmd
        }
        $audited.Add($entry)

        $rows.Add((New-NtRow -Group 'Routes' -Check ('{0} via {1}' -f $dp, $r.NextHop) -Result $verdict -Status $status -Detail ($note + $severityNote + $bindingNote) -Data $entry))
    }

    $bad = @(@($audited) | Where-Object { $_.Status -eq 'fail' })
    $warn = @(@($audited) | Where-Object { $_.Status -eq 'warn' })

    # Counted separately because they mean completely different things: one is a
    # fault happening now, the other is configuration residue.
    $activeBad      = @(@($audited) | Where-Object { $_.InActiveTable -and $_.Status -eq 'fail' })
    $persistOnly    = @(@($audited) | Where-Object { $_.Store -eq 'PersistentOnly' })
    # Residue that WOULD break the destination if Windows ever installed it.
    $persistOnlyBad = @(@($persistOnly) | Where-Object { $_.NextHopStatus -eq 'fail' })

    $caveats = @(
        'Only IPv4 routes are audited.',
        ('{0} Windows-managed routes (on-link /32, multicast, broadcast, loopback) were filtered out.' -f $noise),
        'A route in the persistent store is NOT necessarily in the forwarding table. Only routes marked Active or Both can affect traffic right now.'
    )

    $method = 'Get-NetRoute against both the ActiveStore and the PersistentStore, compared so that a configured-but-not-installed route is never reported as a live fault; each next hop is then resolved against the live interface and route tables, following the chain where one static route depends on another.'

    $section = New-NtSection -Name 'Route audit' -State 'measured' -Method $method -Caveats $caveats -Rows @($rows) -Data ([pscustomobject]@{
        Routes              = [object[]]@($audited)
        BadCount            = $bad.Count
        WarnCount           = $warn.Count
        ActiveBadCount      = $activeBad.Count
        PersistentOnlyCount = $persistOnly.Count
        PersistentOnlyBad   = [object[]]@($persistOnlyBad)
        FilteredNoise  = $noise
        PersistentSeen = @($table.Persistent).Count
    })
    return $section
}

function Resolve-NtSelectedRoute {
    # Which route will Windows ACTUALLY use for this destination, and which
    # source address will the packet carry?
    #
    # The runbook calls Find-NetRoute the highest-value command in the ladder and
    # badly underused, because it returns the selected route and source IP rather
    # than making you read the table by hand. It throws for a destination with no
    # route at all, so the manual longest-prefix fallback below is not optional.
    param(
        [string]$Destination,
        $RouteTable = $null,
        # Read the table ourselves instead of asking Windows. Windows' own
        # answer is authoritative and is still preferred by default - this
        # exists so the table-reading path can be exercised and compared
        # against it, which is the only way to know the fallback agrees.
        [switch]$TableOnly
    )

    $out = [pscustomobject]@{
        Destination     = $Destination
        Resolved        = $false
        Method          = ''
        SourceAddress   = ''
        NextHop         = ''
        InterfaceAlias  = ''
        InterfaceIndex  = 0
        RoutePrefix     = ''
        RouteMetric     = 0
        IsDefaultRoute  = $false
        IsPersistent    = $false
        # Inferred means this tool read the table itself rather than Windows
        # answering. Ambiguous means the table does not decide the question.
        Inferred        = $false
        Ambiguous       = $false
        Detail          = ''
        # WHY it is unresolved. Without this, "the name did not resolve" and
        # "Windows has no route" were the same value, and the conclusion
        # engine reported a DNS failure as a confirmed critical routing fault.
        Reason          = ''
    }
    if (-not (Test-NtIsIPv4 $Destination)) {
        $out.Reason = 'not-an-ipv4-address'
        $out.Detail = ('"{0}" is not an IPv4 address, so no route lookup could be performed. This is a question that was never asked, not a route that does not exist.' -f $Destination)
        return $out
    }
    if (-not $RouteTable) { $RouteTable = Get-NtRouteTable }

    try {
        if ($TableOnly) { throw 'TableOnly requested' }
        $fnr = @(Find-NetRoute -RemoteIPAddress $Destination -ErrorAction Stop)
        if ($fnr.Count -gt 0) {
            # Find-NetRoute returns two objects: the source address, then the route.
            foreach ($o in $fnr) {
                if ($o.PSObject.Properties.Match('IPAddress').Count -and $o.IPAddress) {
                    $out.SourceAddress = [string]$o.IPAddress
                }
                if ($o.PSObject.Properties.Match('DestinationPrefix').Count -and $o.DestinationPrefix) {
                    $out.RoutePrefix    = [string]$o.DestinationPrefix
                    $out.NextHop        = [string]$o.NextHop
                    $out.InterfaceIndex = [int]$o.InterfaceIndex
                    try { $out.InterfaceAlias = [string]$o.InterfaceAlias } catch {}
                    try { $out.RouteMetric = [int]$o.RouteMetric } catch {}
                }
            }
            $out.Resolved = $true
            $out.Method   = 'Find-NetRoute'
        }
    } catch {
        $out.Detail = ('Find-NetRoute could not resolve a route: {0}' -f $_.Exception.Message)
    }

    if (-not $out.Resolved) {
        # Manual longest-prefix match, so an unroutable destination still gets a
        # useful answer instead of an exception.
        #
        # Longest prefix is only the FIRST tie-break. Among candidates of equal
        # prefix length Windows compares the TOTAL metric - route metric plus
        # interface metric - and this used to take whichever equal-length route
        # it happened to see first: a synthetic pair selected metric 500 over
        # metric 1. Getting that wrong picks the wrong next hop and interface,
        # and every conclusion drawn from them inherits the error.
        $ifStates = $null
        try { $ifStates = Get-NtInterfaceStateMap } catch { }
        $bestLen = -1
        $cands = [System.Collections.Generic.List[object]]::new()
        foreach ($r in @($RouteTable.Active)) {
            $dp = [string]$r.DestinationPrefix
            $parts = $dp -split '/'
            if ($parts.Count -ne 2) { continue }
            $len = 0
            if (-not [int]::TryParse($parts[1], [ref]$len)) { continue }
            if (-not (Test-NtIpInPrefix -IPAddress $Destination -Prefix $dp)) { continue }
            if ($len -gt $bestLen) { $bestLen = $len; $cands.Clear() }
            if ($len -eq $bestLen) { $cands.Add($r) }
        }
        $ranked = @()
        if ($cands.Count -gt 0) {
            $scored = foreach ($c in $cands) {
                $ifm = 0; $up = $false
                if ($ifStates -and $ifStates.ContainsKey([int]$c.InterfaceIndex)) {
                    $st = $ifStates[[int]$c.InterfaceIndex]
                    try { $ifm = [int]$st.Metric } catch { }
                    try { $up = ([string]$st.Status -eq 'Connected') } catch { }
                }
                [pscustomobject]@{
                    Route = $c
                    Total = ([int]$c.RouteMetric + $ifm)
                    # A route on a disconnected interface cannot carry traffic,
                    # so it loses to any candidate that can - whatever its metric.
                    UpRank = $(if ($up) { 0 } else { 1 })
                }
            }
            $ranked = @($scored | Sort-Object UpRank, Total)
        }
        if ($ranked.Count -gt 0) {
            $best = $ranked[0].Route
            $out.Resolved       = $true
            $out.Method         = 'longest-prefix match, lowest total metric (INFERRED - Find-NetRoute was unavailable, so this is this tool''s reading of the table rather than Windows'' own answer)'
            $out.RoutePrefix    = [string]$best.DestinationPrefix
            $out.NextHop        = [string]$best.NextHop
            $out.InterfaceAlias = [string]$best.InterfaceAlias
            $out.InterfaceIndex = [int]$best.InterfaceIndex
            $out.RouteMetric    = [int]$best.RouteMetric
            $out.Inferred       = $true
            # The fallback never filled in a source address, yet its results
            # fed conclusions that compare source addresses between hosts.
            if ($ifStates -and $ifStates.ContainsKey([int]$best.InterfaceIndex)) {
                try {
                    $addrs = @($ifStates[[int]$best.InterfaceIndex].Addresses)
                    if ($addrs.Count -gt 0) { $out.SourceAddress = [string]$addrs[0] }
                } catch { }
            }
            $tied = @($ranked | Where-Object { $_.Total -eq $ranked[0].Total -and $_.UpRank -eq $ranked[0].UpRank })
            if ($tied.Count -gt 1) {
                $out.Ambiguous = $true
                $out.Detail = ('{0} routes match this destination with the same prefix length AND the same total metric ({1}), so which one Windows uses cannot be determined from the table alone: {2}. Treat the selection below as one of several possibilities.' -f `
                    $tied.Count, $ranked[0].Total, ((@($tied | ForEach-Object { '{0} via {1} on {2}' -f $_.Route.DestinationPrefix, $_.Route.NextHop, $_.Route.InterfaceAlias })) -join '; '))
            }
        }
    }

    if ($out.Resolved) {
        $out.IsDefaultRoute = ($out.RoutePrefix -eq '0.0.0.0/0')
        foreach ($p in @($RouteTable.Persistent)) {
            if ($p.DestinationPrefix -eq $out.RoutePrefix -and $p.NextHop -eq $out.NextHop -and
                [int]$p.InterfaceIndex -eq [int]$out.InterfaceIndex) {
                $out.IsPersistent = $true; break
            }
        }
        if (-not $out.Detail) {
            if ($out.IsDefaultRoute) {
                $out.Detail = ('Traffic follows the default route out {0} via {1}.' -f $out.InterfaceAlias, $out.NextHop)
            } else {
                $out.Detail = ('Traffic is steered by the specific route {0} via {1} on {2}, NOT by the default gateway.' -f $out.RoutePrefix, $out.NextHop, $out.InterfaceAlias)
            }
        }
    }
    return $out
}

# =============================================================================
# 5. Storage locations
# =============================================================================

function Get-NtDataDir {
    # Per-machine store: OUI cache and the local inventory.
    param()
    $dir = Join-Path $env:ProgramData 'NetToolkit'
    if (-not (Test-Path -LiteralPath $dir)) {
        try { New-Item -ItemType Directory -Path $dir -Force -ErrorAction Stop | Out-Null } catch {}
    }
    return $dir
}

function Get-NtProjectDir {
    # The toolkit's own folder, used for the site profiles, baselines, and the
    # cross-site inventory rollup.
    #
    # $PSScriptRoot is empty when this file is rebuilt from text inside a
    # background runspace, so the caller can pin it explicitly and the module
    # falls back to the module path only when it is actually available.
    param([string]$Hint = '')
    if ($Hint -and (Test-Path -LiteralPath $Hint)) { return $Hint }
    if ($script:NtProjectDir -and (Test-Path -LiteralPath $script:NtProjectDir)) { return $script:NtProjectDir }
    if ($PSScriptRoot -and (Test-Path -LiteralPath $PSScriptRoot)) { return $PSScriptRoot }
    return (Get-Location).Path
}

function Set-NtProjectDir {
    param([string]$Path)
    $script:NtProjectDir = $Path
}

function Read-NtJsonFile {
    # PS 5.1 trap: @(Get-Content ... | ConvertFrom-Json) silently collapses a
    # JSON array into a single object. Assign first, then wrap at the call site.
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    try {
        $raw = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop
        if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
        $obj = $raw | ConvertFrom-Json -ErrorAction Stop
        return $obj
    } catch {
        # A CORRUPT file and a MISSING file both returned $null, so a damaged
        # inventory silently became an empty one - and the next write then
        # overwrote the damaged file with a fresh empty one, destroying
        # whatever history might have been recoverable from it. Preserve it
        # and say so.
        try {
            $bad = ('{0}.corrupt-{1}' -f $Path, (Get-Date -Format 'yyyyMMdd_HHmmss'))
            Copy-Item -LiteralPath $Path -Destination $bad -Force -ErrorAction Stop
            Write-Warning ('{0} could not be parsed and was preserved as {1}. Treating it as empty for this run.' -f $Path, $bad)
        } catch {
            Write-Warning ('{0} could not be parsed, and a copy could not be taken. Treating it as empty for this run.' -f $Path)
        }
        return $null
    }
}

function Write-NtJsonFile {
    # Atomic-ish write: build beside the target, then move over it. A half
    # written inventory is worse than a stale one.
    param([string]$Path, $Object, [int]$Depth = 8)
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        try { New-Item -ItemType Directory -Path $dir -Force -ErrorAction Stop | Out-Null } catch {}
    }
    # A UNIQUE temporary name per writer. Every writer shared "<path>.tmp", so
    # two runs saving at once - two Backstage sessions, or a scheduled job
    # overlapping a manual one - wrote the same scratch file and then moved it
    # twice, interleaving two documents into one.
    $tmp = ('{0}.{1}.{2}.tmp' -f $Path, $PID, [guid]::NewGuid().ToString('N').Substring(0, 8))
    try {
        $json = $Object | ConvertTo-Json -Depth $Depth
        Set-Content -LiteralPath $tmp -Value $json -Encoding UTF8 -ErrorAction Stop
        Move-Item -LiteralPath $tmp -Destination $Path -Force -ErrorAction Stop
        return $true
    } catch {
        try { if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue } } catch {}
        return $false
    }
}

# =============================================================================
# 6. Layer 2 - ARP, MAC, vendor
# =============================================================================
# ARP is not optional evidence: a host MUST answer ARP to use the network at
# all. It is also the only layer that can prove an on-link host is alive when
# Windows Firewall is dropping inbound ICMP, which it does by default.

function ConvertTo-NtNormalMac {
    param([string]$Mac)
    if (-not $Mac) { return '' }
    return (($Mac -replace '[^0-9A-Fa-f]', '').ToUpper())
}

function Format-NtMac {
    param([string]$Mac)
    $n = ConvertTo-NtNormalMac $Mac
    if ($n.Length -ne 12) { return $Mac }
    return (($n -split '(.{2})' | Where-Object { $_ }) -join ':')
}

function Test-NtLocallyAdministered {
    # Bit 1 of the first octet. Set means the MAC was assigned by software, not
    # burned in - which on a client network means a randomised phone or laptop.
    # Those legitimately appear on several IPs, so they must not be reported as
    # duplicate hardware.
    param([string]$Mac)
    $n = ConvertTo-NtNormalMac $Mac
    if ($n.Length -lt 2) { return $false }
    try { return ((([Convert]::ToInt32($n.Substring(0,2), 16)) -band 0x02) -ne 0) } catch { return $false }
}

function Get-NtArpTable {
    # Every neighbour entry that carries a MAC, from every state that can hold
    # one, plus legacy arp -a for anything the cmdlet does not expose.
    param()
    $table = @{}
    foreach ($state in @('Reachable','Stale','Permanent','Probe','Delay','Unreachable')) {
        try {
            foreach ($n in @(Get-NetNeighbor -AddressFamily IPv4 -State $state -ErrorAction SilentlyContinue)) {
                $ip = [string]$n.IPAddress
                $mac = [string]$n.LinkLayerAddress
                if (-not $mac -or $mac -eq '00-00-00-00-00-00') { continue }
                if ($table.ContainsKey($ip)) { continue }
                $table[$ip] = [pscustomobject]@{
                    IPAddress = $ip
                    Mac       = (ConvertTo-NtNormalMac $mac)
                    State     = $state
                    Source    = 'Get-NetNeighbor'
                }
            }
        } catch {}
    }
    try {
        foreach ($line in (arp -a 2>$null)) {
            if ($line -match '^\s+(\d+\.\d+\.\d+\.\d+)\s+([0-9a-fA-F-]{17})\s+(\w+)') {
                $ip = $matches[1]
                if ($table.ContainsKey($ip)) { continue }
                $table[$ip] = [pscustomobject]@{
                    IPAddress = $ip
                    Mac       = (ConvertTo-NtNormalMac $matches[2])
                    State     = $matches[3]
                    Source    = 'arp -a'
                }
            }
        }
    } catch {}
    return $table
}

function Get-NtMacCollisions {
    # One MAC on several live IPs. Genuine causes: a router answering proxy ARP,
    # a misconfigured host, or a device with two addresses. Randomised MACs are
    # flagged separately by the caller so they do not read as a fault.
    param($ArpTable)
    $macToIps = @{}
    foreach ($k in $ArpTable.Keys) {
        $entry = $ArpTable[$k]
        $mac = $entry.Mac
        if (-not $mac) { continue }
        if (-not $macToIps.ContainsKey($mac)) {
            $macToIps[$mac] = [System.Collections.Generic.List[string]]::new()
        }
        $macToIps[$mac].Add([string]$entry.IPAddress)
    }
    $collisions = @{}
    foreach ($mac in $macToIps.Keys) {
        if ($macToIps[$mac].Count -gt 1) { $collisions[$mac] = @($macToIps[$mac]) }
    }
    return $collisions
}

function Get-NtOuiRegistrySources {
    # The IEEE assignment registries. Downloading these once removes the
    # per-prefix rate limit that made vendor naming the slowest part of a sweep.
    # Note oui36/oas.csv is a 404 - the MA-S file is oui36.csv.
    return @(
        @{ Reg = 'MA-L'; Url = 'https://standards-oui.ieee.org/oui/oui.csv' }
        @{ Reg = 'MA-M'; Url = 'https://standards-oui.ieee.org/oui28/mam.csv' }
        @{ Reg = 'MA-S'; Url = 'https://standards-oui.ieee.org/oui36/oui36.csv' }
        @{ Reg = 'IAB';  Url = 'https://standards-oui.ieee.org/iab/iab.csv' }
    )
}

function Get-NtOuiTablePath {
    return (Join-Path (Get-NtDataDir) 'ieee-oui.txt')
}

function Get-NtOuiTableAgeDays {
    # -1 when the IEEE data has never been downloaded.
    param()
    $p = Get-NtOuiTablePath
    if (-not (Test-Path -LiteralPath $p)) { return -1 }
    try { return [int]((Get-Date) - (Get-Item -LiteralPath $p).LastWriteTime).TotalDays } catch { return -1 }
}

function Update-NtOuiTable {
    # Fetches the IEEE registries and writes one flat prefix<TAB>org file.
    # Returns a result object; a PARTIAL download must be reported as partial
    # rather than looking like a clean success.
    param($Progress = $null, $Shared = $null, [int]$TimeoutSec = 120)
    $out = [pscustomobject]@{ Ok = $false; Count = 0; Errors = @(); Path = (Get-NtOuiTablePath) }
    $errors = [System.Collections.Generic.List[string]]::new()
    $lines  = [System.Collections.Generic.List[string]]::new()

    foreach ($src in (Get-NtOuiRegistrySources)) {
        if ($Shared -and $Shared.Cancel) { [void]$errors.Add('cancelled'); break }
        if ($Progress) { & $Progress ('Downloading {0}...' -f $src.Reg) }
        $body = ''
        try {
            $req = [System.Net.HttpWebRequest]::Create($src.Url)
            $req.Method = 'GET'
            $req.Timeout = $TimeoutSec * 1000
            $req.UserAgent = 'NetTool/1.0'
            $resp = $req.GetResponse()
            $sr = New-Object System.IO.StreamReader($resp.GetResponseStream())
            $body = $sr.ReadToEnd()
            $sr.Close(); $resp.Close()
        } catch {
            [void]$errors.Add(('{0}: {1}' -f $src.Reg, $_.Exception.Message))
            continue
        }
        if ([string]::IsNullOrWhiteSpace($body)) { [void]$errors.Add(('{0}: empty response' -f $src.Reg)); continue }
        if ($Progress) { & $Progress ('Parsing {0}...' -f $src.Reg) }
        try {
            # ConvertFrom-Csv, not a regex: organisation names contain commas
            # and are quoted.
            $rows = $body | ConvertFrom-Csv
            foreach ($row in $rows) {
                $assign = [string]$row.Assignment
                if (-not $assign) { continue }
                $assign = (($assign -replace '[^0-9A-Fa-f]', '').ToUpper())
                if (-not $assign) { continue }
                $org = [string]$row.'Organization Name'
                if (-not $org) { $org = 'Unnamed registrant' }
                # Double quotes: `t is only an escape in a double-quoted string.
                [void]$lines.Add(("{0}`t{1}" -f $assign, $org.Trim()))
            }
        } catch {
            [void]$errors.Add(('{0}: parse failed - {1}' -f $src.Reg, $_.Exception.Message))
        }
    }

    $out.Errors = @($errors.ToArray())
    if (@($lines).Count -eq 0) { return $out }
    try {
        if ($Progress) { & $Progress 'Writing OUI table...' }
        Set-Content -LiteralPath (Get-NtOuiTablePath) -Value $lines.ToArray() -Encoding UTF8 -ErrorAction Stop
        $out.Ok = $true
        $out.Count = @($lines).Count
        $script:NtOuiTable = $null   # force a reload next time it is asked for
    } catch {
        [void]$errors.Add(('write failed - {0}' -f $_.Exception.Message))
        $out.Errors = @($errors.ToArray())
    }
    return $out
}

function Get-NtOuiTable {
    # Loads the flat IEEE file into a prefix -> organisation hashtable, ONCE per
    # runspace. Get-NtOuiVendor is called several times per sweep and the table
    # is ~59k rows, so reloading it each call would cost more than the lookups
    # save. Returns $null when the data has not been downloaded, which is the
    # signal to fall back to the online path.
    param()
    if ($script:NtOuiTable) { return $script:NtOuiTable }
    $p = Get-NtOuiTablePath
    if (-not (Test-Path -LiteralPath $p)) { return $null }
    $t = @{}
    try {
        foreach ($line in [System.IO.File]::ReadAllLines($p)) {
            if (-not $line) { continue }
            $parts = $line -split "`t", 2
            if (@($parts).Count -lt 2) { continue }
            if (-not $t.ContainsKey($parts[0])) { $t[$parts[0]] = $parts[1] }
        }
    } catch { return $null }
    if ($t.Count -eq 0) { return $null }
    $script:NtOuiTable = $t
    return $t
}

function Get-NtMacKind {
    # Broadcast / multicast / locally-administered classification. None of these
    # have a manufacturer to find, and reporting them as "Unknown" sends someone
    # looking for one. Multicast is tested BEFORE locally-administered because
    # the well-known multicast prefixes set both bits - 33:33:.. (IPv6) is both,
    # and it is not a randomised device.
    param([string]$Mac)
    $n = ConvertTo-NtNormalMac $Mac
    if ($n.Length -lt 2) { return '' }
    if ($n -eq 'FFFFFFFFFFFF') { return 'Broadcast' }
    $first = 0
    try { $first = [Convert]::ToInt32($n.Substring(0, 2), 16) } catch { return '' }
    if (($first -band 0x01) -ne 0) {
        if ($n.StartsWith('01005E'))     { return 'Multicast (IPv4)' }
        if ($n.StartsWith('3333'))       { return 'Multicast (IPv6)' }
        if ($n.StartsWith('0180C2'))     { return 'Multicast (802.1)' }
        return 'Multicast'
    }
    if (($first -band 0x02) -ne 0) { return 'Private (random) MAC - no vendor' }
    return ''
}

function Get-NtOuiVendor {
    # Vendor from the OUI, cached on disk forever because OUI assignments do not
    # change. Network access is best-effort: on an isolated site the cache is
    # simply cold and every vendor reads "Unknown", which is not an error.
    param(
        [string[]]$Macs = @(),
        [switch]$NoLookup,
        [int]$TimeoutSec = 3,
        # Total wall-clock ceiling for the whole enrichment pass, not per
        # lookup. The rate limit means each unknown prefix costs ~1.1s, so
        # without this a new site's first sweep spent longer naming vendors
        # than it did finding hosts.
        [int]$BudgetSec = 15,
        $Shared = $null
    )
    $cachePath = Join-Path (Get-NtDataDir) 'oui-cache.json'
    $cache = @{}
    $existing = Read-NtJsonFile -Path $cachePath
    if ($existing) {
        foreach ($p in $existing.PSObject.Properties) { $cache[$p.Name] = [string]$p.Value }
    }

    $result = @{}
    $needed = [System.Collections.Generic.List[string]]::new()

    # The IEEE table, when it has been downloaded, answers everything offline
    # and instantly. Its other advantage is LONGEST PREFIX matching: IEEE issues
    # 24-bit (MA-L), 28-bit (MA-M) and 36-bit (MA-S/IAB) blocks, and the 24-bit
    # prefix covering a small block belongs to the IEEE itself - which is why
    # the online service answers "IEEE Registration Authority" for those. Trying
    # 9, then 7, then 6 hex characters finds the actual sub-assignee.
    $ieee = Get-NtOuiTable

    foreach ($m in @($Macs)) {
        $n = ConvertTo-NtNormalMac $m
        if ($n.Length -lt 6) { continue }
        if ($result.ContainsKey($n)) { continue }

        # Broadcast, multicast and randomised addresses have no manufacturer.
        $kind = Get-NtMacKind $n
        if ($kind) { $result[$n] = $kind; continue }

        if ($ieee) {
            $hit = ''
            foreach ($len in @(9, 7, 6)) {
                if ($n.Length -lt $len) { continue }
                $p = $n.Substring(0, $len)
                if ($ieee.ContainsKey($p)) { $hit = $ieee[$p]; break }
            }
            if ($hit) { $result[$n] = $hit; continue }
        }

        $oui = $n.Substring(0,6)
        if ($cache.ContainsKey($oui)) { $result[$n] = $cache[$oui]; continue }
        # With the IEEE data present a miss is authoritative - the prefix really
        # is unassigned - so do not spend 1.1s online confirming it. Without it,
        # fall through to the online path exactly as before.
        if ($ieee) { $result[$n] = 'Unregistered'; continue }
        if ($needed -notcontains $oui) { $needed.Add($oui) }
    }

    if (-not $NoLookup -and $needed.Count -gt 0) {
        # A BUDGET, and a cancel check.
        #
        # The rate limit forces 1.1 s of sleep per unknown OUI, serially, with
        # no ceiling: a sweep of a new site turning up 30 unknown prefixes
        # sat here for over half a minute before any result appeared, and
        # Cancel did not reach it. Vendor names are the least important thing
        # this tool produces - they must never be the slowest.
        $dirty = $false
        $swOui = [System.Diagnostics.Stopwatch]::StartNew()
        $done = 0
        foreach ($oui in $needed) {
            if ($Shared -and $Shared.Cancel) { break }
            if ($swOui.Elapsed.TotalSeconds -ge $BudgetSec) { break }
            try {
                $url = ('https://api.macvendors.com/{0}' -f $oui)
                $v = Invoke-RestMethod -Uri $url -TimeoutSec $TimeoutSec -ErrorAction Stop
                $cache[$oui] = [string]$v
                $dirty = $true
            } catch {
                # 404 means the OUI is genuinely unregistered - cache that so we
                # never ask again. Anything else is a transient network problem
                # and must NOT be cached as a negative.
                $code = 0
                try { $code = [int]$_.Exception.Response.StatusCode } catch {}
                if ($code -eq 404) { $cache[$oui] = 'Unregistered'; $dirty = $true }
            }
            $done++
            # Do not pay the rate-limit pause after the LAST lookup, or on the
            # way out of the budget.
            if ($done -lt $needed.Count -and $swOui.Elapsed.TotalSeconds -lt $BudgetSec) {
                Start-Sleep -Milliseconds 1100   # free tier is rate limited to ~1/sec
            }
        }
        $swOui.Stop()
        if ($done -lt $needed.Count) {
            Write-Verbose ('OUI lookup stopped after {0} of {1} prefixes ({2:N1}s budget). The rest read as Unknown - a missing vendor name is cosmetic.' -f $done, $needed.Count, $BudgetSec)
        }
        if ($dirty) { [void](Write-NtJsonFile -Path $cachePath -Object $cache -Depth 3) }
    }

    foreach ($m in @($Macs)) {
        $n = ConvertTo-NtNormalMac $m
        if ($n.Length -lt 6) { continue }
        if ($result.ContainsKey($n)) { continue }
        $oui = $n.Substring(0,6)
        if ($cache.ContainsKey($oui)) { $result[$n] = $cache[$oui] } else { $result[$n] = 'Unknown' }
    }
    return $result
}

function Get-NtArpAudit {
    # ARP as evidence rather than as a table dump: who the gateway is, whether
    # anything is answering for two addresses, and whether an on-link target
    # resolves at layer 2 at all.
    param(
        $Context = $null,
        [string]$Target = '',
        [switch]$NoVendorLookup
    )
    if (-not $Context) { $Context = Get-NtLocalContext }
    $arp  = Get-NtArpTable
    $rows = [System.Collections.Generic.List[object]]::new()

    $macs = @()
    foreach ($k in $arp.Keys) { $macs += $arp[$k].Mac }
    $vendors = Get-NtOuiVendor -Macs $macs -NoLookup:$NoVendorLookup -Shared $Shared

    $gw = Get-NtPrimaryGateway -Context $Context
    $gatewayMac = ''
    $gatewayVendor = ''
    if ($gw -and $arp.ContainsKey($gw)) {
        $gatewayMac = $arp[$gw].Mac
        if ($vendors.ContainsKey($gatewayMac)) { $gatewayVendor = $vendors[$gatewayMac] }
        $detail = 'ARP resolution to the gateway proves the local segment works at layer 2, regardless of whether the gateway answers ICMP.'
        $rows.Add((New-NtRow -Group 'ARP' -Check ('Gateway {0}' -f $gw) -Result ('{0} ({1})' -f (Format-NtMac $gatewayMac), $gatewayVendor) -Status 'ok' -Detail $detail))
    } elseif ($gw) {
        $detail = 'The gateway is not in the neighbour cache. If nothing else on the LAN works either, this is a layer 2 or VLAN problem, not a routing one.'
        $rows.Add((New-NtRow -Group 'ARP' -Check ('Gateway {0}' -f $gw) -Result 'No ARP entry' -Status 'warn' -Detail $detail))
    }

    # Is the target on-link? Only then does an ARP entry mean anything for it.
    $targetOnLink = $false
    $targetArp = $null
    if ($Target -and (Test-NtIsIPv4 $Target)) {
        foreach ($p in @($Context.ConnectedPrefixes)) {
            if (Test-NtIpInPrefix -IPAddress $Target -Prefix $p) { $targetOnLink = $true; break }
        }
        if ($targetOnLink) {
            if ($arp.ContainsKey($Target)) {
                $targetArp = $arp[$Target]
                $vend = ''
                if ($vendors.ContainsKey($targetArp.Mac)) { $vend = $vendors[$targetArp.Mac] }
                # Branch on the STATE. Any entry used to read as proof of life,
                # so an Unreachable entry - a recorded resolution FAILURE -
                # was reported as "powered on and connected".
                $nc = Get-NtNeighbourConfidence -State $targetArp.State
                $rows.Add((New-NtRow -Group 'ARP' -Check ('Target {0}' -f $Target) `
                    -Result ('{0} ({1}), state {2}' -f (Format-NtMac $targetArp.Mac), $vend, $targetArp.State) `
                    -Status $nc.Status -Detail $nc.Detail))
            } else {
                # NOT a fault, and not yet a finding. The cache is read before
                # the target is probed, so an entirely healthy host that simply
                # has not been talked to recently has no entry - and this row
                # used to call that "switched off, unplugged, or on a different
                # VLAN" at fail severity, before a single packet had been sent
                # to it.
                $rows.Add((New-NtRow -Group 'ARP' -Check ('Target {0}' -f $Target) -Result 'Not in the neighbour cache' -Status 'info' `
                    -Detail 'The target is on this subnet but has no neighbour entry YET. This is read before the target is probed, so an address simply not talked to recently looks exactly like one that is switched off. If the probes below get a reply, this row means nothing; if address resolution is still absent afterwards, that is the finding.'))
            }
        } else {
            $rows.Add((New-NtRow -Group 'ARP' -Check ('Target {0}' -f $Target) -Result 'Off-link - ARP not applicable' -Status 'info' -Detail 'The target is not on a directly connected subnet, so it can never appear in this machine ARP cache. Only the next hop does.'))
        }
    }

    $collisions = Get-NtMacCollisions -ArpTable $arp
    foreach ($mac in $collisions.Keys) {
        $ips = @($collisions[$mac])
        $la  = Test-NtLocallyAdministered $mac
        $vend = ''
        if ($vendors.ContainsKey($mac)) { $vend = $vendors[$mac] }
        if ($la) {
            $rows.Add((New-NtRow -Group 'ARP' -Check ('MAC {0}' -f (Format-NtMac $mac)) -Result ('{0} addresses' -f $ips.Count) -Status 'info' -Detail ('Locally administered (randomised) MAC on {0}. Normal for phones and modern laptops - not a fault.' -f ($ips -join ', '))))
        } else {
            $rows.Add((New-NtRow -Group 'ARP' -Check ('MAC {0}' -f (Format-NtMac $mac)) -Result ('{0} addresses' -f $ips.Count) -Status 'warn' -Detail ('One burned-in MAC ({0}) answering for {1}. Usually a router doing proxy ARP or a duplicate address.' -f $vend, ($ips -join ', '))))
        }
    }

    $entries = [System.Collections.Generic.List[object]]::new()
    foreach ($k in $arp.Keys) {
        $e = $arp[$k]
        $entries.Add([pscustomobject]@{
            IPAddress           = $e.IPAddress
            Mac                 = $e.Mac
            MacFormatted        = (Format-NtMac $e.Mac)
            Vendor              = $(if ($vendors.ContainsKey($e.Mac)) { $vendors[$e.Mac] } else { 'Unknown' })
            State               = $e.State
            LocallyAdministered = (Test-NtLocallyAdministered $e.Mac)
        })
    }

    $data = [pscustomobject]@{
        Entries       = [object[]]@($entries | Sort-Object { ConvertTo-NtUInt32 $_.IPAddress })
        Gateway       = $gw
        GatewayMac    = $gatewayMac
        GatewayVendor = $gatewayVendor
        Collisions    = $collisions
        TargetOnLink  = $targetOnLink
        TargetEntry   = $targetArp
    }

    $method = 'Get-NetNeighbor across every state that can hold a MAC, merged with arp -a, then OUI vendor lookup from a local cache.'
    return (New-NtSection -Name 'ARP and layer 2' -State 'measured' -Method $method -Rows @($rows) -Data $data -Caveats @(
        'ARP only ever describes directly connected subnets. An off-link host has no entry here and never will.'
    ))
}

# =============================================================================
# 7. Name resolution - hosts, lmhosts, DNS, NRPT
# =============================================================================
# A hosts entry beats DNS silently and survives every DNS fix anyone tries. It
# is cheap to read and it is the sort of thing left behind after a migration or
# a vendor's "temporary" workaround, so it gets checked before DNS is blamed.

function Get-NtHostsFile {
    # Parses hosts (and lmhosts) into structured entries with line numbers, so a
    # remediation step can target one line instead of rewriting the file.
    param([string]$Path = '')
    if (-not $Path) {
        $Path = Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'
    }
    $entries = [System.Collections.Generic.List[object]]::new()
    $exists = Test-Path -LiteralPath $Path
    $lineCount = 0

    if ($exists) {
        try {
            $lines = @(Get-Content -LiteralPath $Path -ErrorAction Stop)
            $lineCount = $lines.Count
            # Sections that software writes and manages for itself. An entry
            # in one of these was not typed by a person, and saying which
            # product wrote it is usually the whole explanation - Tailscale,
            # for instance, puts every tailnet machine's short name here, so
            # that name then beats both DNS and the device itself.
            $section = ''
            for ($i = 0; $i -lt $lines.Count; $i++) {
                $raw = [string]$lines[$i]
                $trim = $raw.Trim()
                if ($trim -match '^#\s*TailscaleHostsSectionStart') { $section = 'Tailscale' }
                elseif ($trim -match '^#\s*TailscaleHostsSectionEnd') { $section = ''; continue }
                elseif ($trim -match '^#\s*Added by Docker Desktop') { $section = 'Docker Desktop' }
                elseif ($section -eq 'Docker Desktop' -and $trim -match '^#\s*End of section') { $section = ''; continue }
                if ($trim.Length -eq 0) { continue }

                $commented = $trim.StartsWith('#')
                $body = $trim
                if ($commented) { $body = $trim.TrimStart('#').Trim() }
                if ($body.Length -eq 0) { continue }

                # Strip a trailing inline comment before splitting.
                $hashAt = $body.IndexOf('#')
                if ($hashAt -ge 0) { $body = $body.Substring(0, $hashAt).Trim() }
                if ($body.Length -eq 0) { continue }

                $tokens = @($body -split '\s+' | Where-Object { $_ })
                if ($tokens.Count -lt 2) { continue }
                $ip = $tokens[0]
                # A commented line only counts as an entry if it actually looks
                # like one; the stock file is full of prose comments.
                if (-not (Test-NtIsIPv4 $ip)) {
                    if ($ip -notmatch '^[0-9a-fA-F:]+$') { continue }
                }
                $names = @($tokens[1..($tokens.Count - 1)])
                $entries.Add([pscustomobject]@{
                    LineNumber = ($i + 1)
                    IPAddress  = $ip
                    Names      = [object[]]$names
                    Commented  = $commented
                    Raw        = $raw
                    Section    = $section
                })
            }
        } catch {}
    }

    # Duplicate active mappings. Harmless in themselves - Windows uses the first
    # match - but they are a reliable sign of a file that has been edited by
    # several people over several years, and they make the file hard to read.
    $dupes = [System.Collections.Generic.List[object]]::new()
    $seenMap = @{}
    foreach ($e in @($entries | Where-Object { -not $_.Commented })) {
        foreach ($n in @($e.Names)) {
            $key = ('{0}|{1}' -f $e.IPAddress, $n.ToLower())
            if ($seenMap.ContainsKey($key)) {
                $seenMap[$key].Lines.Add($e.LineNumber)
            } else {
                $seenMap[$key] = [pscustomobject]@{
                    IPAddress = $e.IPAddress
                    Name      = $n
                    Lines     = [System.Collections.Generic.List[int]]::new()
                }
                $seenMap[$key].Lines.Add($e.LineNumber)
            }
        }
    }
    foreach ($k in $seenMap.Keys) {
        if (@($seenMap[$k].Lines).Count -gt 1) { $dupes.Add($seenMap[$k]) }
    }

    [pscustomobject]@{
        Path        = $Path
        Exists      = $exists
        LineCount   = $lineCount
        Entries     = [object[]]@($entries)
        ActiveCount = @(@($entries) | Where-Object { -not $_.Commented }).Count
        Duplicates  = [object[]]@($dupes)
    }
}

function Get-NtNameResolutionSection {
    # Answers one question: is anything on this machine sending the target name
    # somewhere other than where DNS says?
    param(
        [string]$Target = '',
        $Context = $null
    )
    if (-not $Context) { $Context = Get-NtLocalContext }
    $rows = [System.Collections.Generic.List[object]]::new()

    $hosts    = Get-NtHostsFile
    $lmPath   = Join-Path $env:SystemRoot 'System32\drivers\etc\lmhosts'
    $lmhosts  = Get-NtHostsFile -Path $lmPath

    if (-not $hosts.Exists) {
        $rows.Add((New-NtRow -Group 'Names' -Check 'hosts file' -Result 'Missing' -Status 'warn' -Detail ('{0} does not exist. Unusual but not itself a fault.' -f $hosts.Path)))
    } elseif ($hosts.ActiveCount -eq 0) {
        $rows.Add((New-NtRow -Group 'Names' -Check 'hosts file' -Result 'No active entries' -Status 'ok' -Detail 'Only comments. Nothing here can override DNS.'))
    } else {
        $rows.Add((New-NtRow -Group 'Names' -Check 'hosts file' -Result ('{0} active entries' -f $hosts.ActiveCount) -Status 'warn' -Detail 'Active hosts entries override DNS silently and survive every DNS fix. Each is listed below.'))
        foreach ($e in @($hosts.Entries | Where-Object { -not $_.Commented })) {
            $rows.Add((New-NtRow -Group 'Names' -Check ('hosts line {0}' -f $e.LineNumber) -Result ('{0} -> {1}' -f ($e.Names -join ' '), $e.IPAddress) -Status 'info' -Detail $e.Raw.Trim() -Data $e))
        }
    }

    if ($lmhosts.Exists -and $lmhosts.ActiveCount -gt 0) {
        $rows.Add((New-NtRow -Group 'Names' -Check 'lmhosts' -Result ('{0} active entries' -f $lmhosts.ActiveCount) -Status 'warn' -Detail 'lmhosts still influences NetBIOS name resolution. Rare in modern estates, and usually a leftover.'))
    }

    # Entries that specifically concern the target, by address or by name.
    $targetHits = [System.Collections.Generic.List[object]]::new()
    if ($Target) {
        foreach ($e in @($hosts.Entries)) {
            $match = $false
            if ($e.IPAddress -eq $Target) { $match = $true }
            foreach ($n in @($e.Names)) {
                if ($n -and $Target -and $n.ToLower() -eq $Target.ToLower()) { $match = $true }
            }
            if ($match) { $targetHits.Add($e) }
        }
        foreach ($e in @($targetHits)) {
            $state = if ($e.Commented) { 'commented out' } else { 'ACTIVE' }
            $status = if ($e.Commented) { 'info' } else { 'fail' }
            $rows.Add((New-NtRow -Group 'Names' -Check ('hosts entry for target (line {0})' -f $e.LineNumber) -Result ('{0} - {1} -> {2}' -f $state, ($e.Names -join ' '), $e.IPAddress) -Status $status -Detail 'A hosts entry naming the target is the first thing to rule out - it overrides DNS with no log and no warning.' -Data $e))
        }
    }

    # DNS versus hosts, when the target is a NAME rather than a literal address.
    $dnsData = [pscustomobject]@{
        TargetIsName   = $false
        WithHosts      = @()
        DnsOnly        = @()
        Overridden     = $false
    }
    if ($Target -and -not (Test-NtIsIPv4 $Target)) {
        $dnsData.TargetIsName = $true
        $withHosts = @()
        $dnsOnly   = @()
        try {
            $withHosts = @(Resolve-DnsName -Name $Target -Type A -ErrorAction Stop |
                           Where-Object { $_.IPAddress } | ForEach-Object { [string]$_.IPAddress })
        } catch {}
        try {
            $dnsOnly = @(Resolve-DnsName -Name $Target -Type A -DnsOnly -NoHostsFile -ErrorAction Stop |
                         Where-Object { $_.IPAddress } | ForEach-Object { [string]$_.IPAddress })
        } catch {}
        $dnsData.WithHosts = [object[]]$withHosts
        $dnsData.DnsOnly   = [object[]]$dnsOnly

        if ($withHosts.Count -eq 0 -and $dnsOnly.Count -eq 0) {
            $rows.Add((New-NtRow -Group 'Names' -Check ('Resolve {0}' -f $Target) -Result 'No answer' -Status 'fail' -Detail 'The name does not resolve at all. Fix name resolution before investigating routing.'))
        } elseif ($withHosts.Count -gt 0 -and $dnsOnly.Count -gt 0) {
            $diff = @(Compare-Object -ReferenceObject $dnsOnly -DifferenceObject $withHosts)
            if ($diff.Count -gt 0) {
                # These are two SEQUENTIAL lookups, not a controlled
                # comparison. A name behind a load balancer, a round-robin
                # record or a geo-steered CDN legitimately returns different
                # addresses microseconds apart, and this was calling that a
                # confirmed local override - sending a technician to edit a
                # hosts file that has nothing to do with it.
                #
                # It is only an override if the local answer is one the
                # DNS-only answer does not contain AND the hosts file
                # actually carries an entry for this name. Otherwise it is
                # recorded as a difference, which is what was observed.
                $localOnly = @($withHosts | Where-Object { $dnsOnly -notcontains $_ })
                $hostsHasName = $false
                foreach ($h in @($hosts.Entries | Where-Object { -not $_.Commented })) {
                    foreach ($n in @($h.Names)) {
                        if ([string]$n -eq $Target) { $hostsHasName = $true; break }
                    }
                    if ($hostsHasName) { break }
                }
                if ($localOnly.Count -gt 0 -and $hostsHasName) {
                    $dnsData.Overridden = $true
                    $rows.Add((New-NtRow -Group 'Names' -Check ('Resolve {0}' -f $Target) -Result ('local {0}, DNS {1}' -f ($withHosts -join ', '), ($dnsOnly -join ', ')) -Status 'fail' `
                        -Detail 'Normal resolution returns an address DNS does not, AND the hosts file carries an entry for this exact name - so the local file is overriding DNS here.'))
                } else {
                    $rows.Add((New-NtRow -Group 'Names' -Check ('Resolve {0}' -f $Target) -Result ('first {0}, second {1}' -f ($withHosts -join ', '), ($dnsOnly -join ', ')) -Status 'info' `
                        -Detail 'Two sequential lookups returned different addresses. That is NOT by itself evidence of a local override - a load balancer, a round-robin record or a geo-steered CDN answers differently on consecutive queries by design. No hosts entry for this name was found. Worth knowing which address was actually tested; not worth editing anything over.'))
                }
            } else {
                $rows.Add((New-NtRow -Group 'Names' -Check ('Resolve {0}' -f $Target) -Result ($dnsOnly -join ', ') -Status 'ok' -Detail 'Normal and DNS-only resolution agree, so nothing local is overriding this name.'))
            }
        } else {
            $answer = if ($withHosts.Count -gt 0) { $withHosts } else { $dnsOnly }
            $rows.Add((New-NtRow -Group 'Names' -Check ('Resolve {0}' -f $Target) -Result ($answer -join ', ') -Status 'ok' -Detail 'Resolved.'))
        }
    }

    # NRPT: a VPN client commonly pushes these, and they redirect whole
    # namespaces to a resolver that is unreachable once the tunnel drops.
    # Projected to the fields that matter. The raw CIM objects carried their
    # whole class metadata into the export - 550 KB of the report for one
    # Tailscale rule, most of a 4.6 MB JSON file.
    $nrpt = @()
    try {
        $nrpt = @(Get-DnsClientNrptPolicy -ErrorAction Stop | ForEach-Object {
            [pscustomobject]@{ Namespace = [object[]]@($_.Namespace); NameServers = [object[]]@($_.NameServers) }
        })
    } catch {}
    if ($nrpt.Count -gt 0) {
        $shown = @($nrpt | Select-Object -First 5 | ForEach-Object { '{0} -> {1}' -f (@($_.Namespace) -join ' '), (@($_.NameServers) -join ', ') })
        $rows.Add((New-NtRow -Group 'Names' -Check 'NRPT policy' -Result ('{0} rule(s)' -f $nrpt.Count) -Status 'warn' -Detail ('Name Resolution Policy rules redirect specific namespaces to specific servers. VPN clients push these, and they often outlive the tunnel. {0}{1}' -f ($shown -join '; '), $(if ($nrpt.Count -gt 5) { ' ...' } else { '' }))))
    }

    $suffixes = @()
    try {
        $g = Get-DnsClientGlobalSetting -ErrorAction Stop
        $suffixes = @($g.SuffixSearchList)
    } catch {}

    $data = [pscustomobject]@{
        Hosts        = $hosts
        LmHosts      = $lmhosts
        TargetHits   = [object[]]@($targetHits)
        Dns          = $dnsData
        NrptRules    = [object[]]$nrpt
        SuffixSearch = [object[]]$suffixes
        DnsServers   = [object[]]@($Context.DnsServers)
    }

    $method = 'Parses hosts and lmhosts directly, then resolves the target both normally and with -DnsOnly -NoHostsFile; a difference between the two is a local override.'
    return (New-NtSection -Name 'Name resolution' -State 'measured' -Method $method -Rows @($rows) -Data $data -Caveats @(
        'A hosts entry is only reported as a fault when it names the target being tested. Other active entries are listed but not judged.'
    ))
}

# =============================================================================
# 8. Probes - ICMP, TTL reading, TCP, banners
# =============================================================================

function Get-NtTtlReading {
    # Runbook section 2, as code.
    #
    # Every ping reply carries two facts most people throw away:
    #   * the INITIAL TTL tells you the OS class of the responder
    #       64  = Linux or a network appliance
    #       128 = Windows
    #       255 = some network gear (and many appliances' own control plane)
    #   * the DELTA tells you how many routers the reply crossed
    #
    # In the original case, 10.50.9.1 replying TTL 63 proved exactly one router
    # hop, and 10.60.100.5 replying TTL 120 proved an eight-hop path across the
    # overlay WITH a working return path. Both were free, and both were ignored.
    param([int]$ObservedTtl)

    # EVERYTHING except ObservedTtl below is an ESTIMATE.
    #
    # The initial TTL is not carried in the packet - it is guessed by rounding
    # the observed value up to the nearest common default. That guess is
    # usually right and is wrong in ways that matter: appliances and hardened
    # Linux builds ship non-default TTLs, some VPN and overlay stacks rewrite
    # them, and a responder 70 hops away with an initial 128 is
    # indistinguishable from one 6 hops away with an initial 64. The hop count
    # and OS class inherit that uncertainty, and the previous wording -
    # "proved exactly one router hop", "the responder is on this segment" -
    # stated both as fact.
    $out = [pscustomobject]@{
        ObservedTtl = $ObservedTtl   # the only measurement here
        InitialTtl  = 0              # estimated
        Hops        = -1             # estimated
        OsClass     = 'unknown'      # estimated
        IsEstimate  = $true
        Detail      = ''
    }
    if ($ObservedTtl -le 0) {
        $out.Detail = 'No TTL was observed (no ICMP reply), so no path fingerprint is available.'
        return $out
    }

    $candidates = @(
        @{ Init = 64;  Class = 'Linux or network appliance' },
        @{ Init = 128; Class = 'Windows' },
        @{ Init = 255; Class = 'network gear' }
    )
    foreach ($c in $candidates) {
        if ($ObservedTtl -le $c.Init) {
            $out.InitialTtl = [int]$c.Init
            $out.OsClass    = [string]$c.Class
            $out.Hops       = [int]$c.Init - $ObservedTtl
            break
        }
    }
    if ($out.InitialTtl -eq 0) {
        $out.Detail = ('TTL {0} is above every common initial value - the responder uses a non-standard stack.' -f $ObservedTtl)
        return $out
    }

    $caveat = 'The initial TTL is inferred by rounding up to the nearest common default, so a responder using a non-standard value would read as a different distance.'
    if ($out.Hops -eq 0) {
        $out.Detail = ('TTL {0}, consistent with an initial value of {1} and NO router in between - the responder would then be on this segment, and looks like {2}. {3}' -f $ObservedTtl, $out.InitialTtl, $out.OsClass, $caveat)
    } elseif ($out.Hops -eq 1) {
        $out.Detail = ('TTL {0}, consistent with one decrement from {1} - about one router hop away. Responder looks like {2}. {3}' -f $ObservedTtl, $out.InitialTtl, $out.OsClass, $caveat)
    } else {
        $out.Detail = ('TTL {0}, consistent with {1} decrements from {2} - roughly a {1}-hop path. Responder looks like {3}. {4}' -f $ObservedTtl, $out.Hops, $out.InitialTtl, $out.OsClass, $caveat)
    }
    return $out
}

function Test-NtIcmp {
    # N echo probes with the reply TTL retained.
    #
    # A TTL that CHANGES between probes means the path changed mid-test, which
    # is worth more than the latency figures. Callers surface it.
    param(
        [string]$Target,
        [int]$Count = 4,
        [int]$TimeoutMs = 1000,
        $Shared = $null
    )
    # An empty target is not "no reply" - Ping.Send('') resolves to the LOCAL
    # machine, so a missing target silently produces a confident report about
    # the wrong host. Refuse instead.
    if ([string]::IsNullOrWhiteSpace($Target)) {
        return [pscustomobject]@{
            Target = ''; Sent = 0; Received = 0; Success = $false; Ttls = @()
            TtlStable = $true; Rtt = $null; Address = ''; Status = 'NoTarget'
            TtlReading = $null
            Detail = 'No target was supplied, so nothing was probed. This is a caller error, not a network finding.'
        }
    }
    $out = [pscustomobject]@{
        Target      = $Target
        Sent        = 0
        Received    = 0
        Success     = $false
        Ttls        = @()
        TtlStable   = $true
        Rtt         = $null
        Address     = ''
        Status      = ''
        TtlReading  = $null
        Detail      = ''
    }
    $ping = New-Object System.Net.NetworkInformation.Ping
    $buffer = New-Object byte[] 32
    $times = [System.Collections.Generic.List[double]]::new()
    $ttls  = [System.Collections.Generic.List[int]]::new()
    $lastStatus = ''
    try {
        for ($i = 0; $i -lt $Count; $i++) {
            if ($Shared -and $Shared.Cancel) { break }
            $out.Sent++
            try {
                $r = $ping.Send($Target, $TimeoutMs, $buffer)
                $lastStatus = [string]$r.Status
                if ($r.Status -eq [System.Net.NetworkInformation.IPStatus]::Success) {
                    $out.Received++
                    $times.Add([double]$r.RoundtripTime)
                    if ($r.Address) { $out.Address = $r.Address.ToString() }
                    # Options is null on some platforms and for some replies.
                    $t = 0
                    try { if ($r.Options) { $t = [int]$r.Options.Ttl } } catch {}
                    if ($t -gt 0) { $ttls.Add($t) }
                }
            } catch {
                $lastStatus = $_.Exception.Message
            }
        }
    } finally {
        try { $ping.Dispose() } catch {}
    }

    $out.Status = $lastStatus
    $out.Ttls   = [object[]]@($ttls)
    $out.Success = ($out.Received -gt 0)
    if ($times.Count -gt 0) { $out.Rtt = Get-NtStats -Values ([double[]]@($times)) }

    if ($ttls.Count -gt 0) {
        $distinct = @($ttls | Select-Object -Unique)
        $out.TtlStable = ($distinct.Count -eq 1)
        $out.TtlReading = Get-NtTtlReading -ObservedTtl ([int]$ttls[0])
        if (-not $out.TtlStable) {
            $out.Detail = ('The reply TTL varied across probes ({0}). The path changed during the test, or replies are arriving by more than one route.' -f (($distinct | Sort-Object) -join ', '))
        } else {
            $out.Detail = $out.TtlReading.Detail
        }
    } elseif ($out.Success) {
        $out.Detail = 'Replied, but no TTL was exposed on the reply.'
    } else {
        $out.Detail = ('No reply ({0}). ICMP is frequently blocked by policy, so this alone does not prove the host is down.' -f $lastStatus)
    }
    return $out
}

function Test-NtTcpPortDetail {
    # A TCP connect attempt, with WHY it ended.
    #
    # "closed or filtered" is presented as an inherent limitation of a connect
    # scan, and for the pair {closed, filtered} it is. But the socket layer
    # usually distinguishes them for us and that information was being thrown
    # away: a CONNECTION REFUSED arrives immediately and means a host is up
    # and actively rejecting, while a TIMEOUT means nothing came back at all.
    # For a technician those point in opposite directions - the first says the
    # host is there and the service is not, the second says the packets may
    # not be arriving.
    #
    # A reset can also come from a middlebox rather than the host, so this
    # records what was observed and does not claim to know who sent it.
    param(
        [string]$Target,
        [int]$Port,
        [int]$TimeoutMs = 800
    )
    $out = [pscustomobject]@{
        Port = $Port; Open = $false; Outcome = 'no-response'
        ElapsedMs = 0.0; SocketError = ''; Detail = ''
    }
    # Same trap as Test-NtIcmp: an empty host connects to the local machine.
    if ([string]::IsNullOrWhiteSpace($Target)) {
        $out.Outcome = 'not-tested'
        $out.Detail = 'No target was supplied, so nothing was probed.'
        return $out
    }
    $client = $null
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $client = New-Object System.Net.Sockets.TcpClient
        # ConnectAsync, not BeginConnect + AsyncWaitHandle.WaitOne.
        #
        # Measured on this machine: with the WaitOne pattern EVERY failure -
        # including a connection to loopback port 1, which must be an
        # immediate refusal - came back as a timeout after the full wait,
        # because the handle is not reliably signalled when the connect
        # FAILS. That lost the refused/timeout distinction this function
        # exists for, and it also means a scan of N closed ports costs N full
        # timeouts. A faulted Task completes immediately and carries the
        # SocketException with it.
        $task = $client.ConnectAsync($Target, $Port)
        $completed = $false
        try {
            $completed = $task.Wait($TimeoutMs)
        } catch [System.AggregateException] {
            # Wait() throws when the task faulted - that IS completion.
            $completed = $true
        }
        if (-not $completed) {
            $out.Outcome = 'timeout'
            $out.Detail = ('No response within {0} ms. Consistent with filtering, a path failure, or a host that is not there - a connect scan cannot separate those.' -f $TimeoutMs)
        } else {
            $fault = $null
            if ($task.IsFaulted -and $task.Exception) {
                $fault = $task.Exception.InnerException
                while ($fault -is [System.AggregateException]) { $fault = $fault.InnerException }
            }
            if ($null -eq $fault) {
                if ($client.Connected) {
                    $out.Open = $true
                    $out.Outcome = 'accepted'
                    $out.Detail = 'The handshake completed, which proves the packet arrived AND the reply found its way back.'
                } else {
                    $out.Outcome = 'closed'
                    $out.Detail = 'The connection did not establish, but the attempt ended immediately rather than timing out.'
                }
            } elseif ($fault -is [System.Net.Sockets.SocketException]) {
                $se = $fault
                $out.SocketError = [string]$se.SocketErrorCode
                switch ([string]$se.SocketErrorCode) {
                    'ConnectionRefused' {
                        $out.Outcome = 'refused'
                        $out.Detail = 'Actively REFUSED. Something sent a reset, so the packet reached a device that answered - this is not a filtering or path problem. Usually the host is up with nothing listening on that port, though an intermediary can also reset on the host''s behalf.'
                    }
                    'HostUnreachable'    { $out.Outcome = 'unreachable'; $out.Detail = 'The network reported the host as unreachable, which is a routing answer rather than a service one.' }
                    'NetworkUnreachable' { $out.Outcome = 'unreachable'; $out.Detail = 'The network reported the destination network as unreachable - this machine has no usable path for it.' }
                    'TimedOut'           { $out.Outcome = 'timeout';     $out.Detail = 'The stack timed the connection out with no response.' }
                    default              { $out.Outcome = 'error';       $out.Detail = ('The connection attempt failed: {0}.' -f $se.SocketErrorCode) }
                }
            } else {
                $out.Outcome = 'error'
                $out.SocketError = $fault.GetType().Name
                $out.Detail = ('The connection attempt failed locally: {0}' -f $fault.Message)
            }
        }
    } catch {
        $out.Outcome = 'error'
        $out.SocketError = $_.Exception.GetType().Name
        $out.Detail = ('The probe could not be started: {0}' -f $_.Exception.Message)
    } finally {
        $sw.Stop()
        if ($client) { try { $client.Close() } catch {} }
    }
    $out.ElapsedMs = [math]::Round($sw.Elapsed.TotalMilliseconds, 1)
    return $out
}

function Test-NtTcpPort {
    # Boolean wrapper, kept so existing callers are unaffected.
    param(
        [string]$Target,
        [int]$Port,
        [int]$TimeoutMs = 800
    )
    return [bool](Test-NtTcpPortDetail -Target $Target -Port $Port -TimeoutMs $TimeoutMs).Open
}

function Get-NtHttpBanner {
    # The Server header, and nothing else. Enough to name an appliance without
    # touching anything on it.
    param([string]$Target, [int]$Port = 80, [int]$TimeoutMs = 1500)
    $client = $null
    try {
        $client = New-Object System.Net.Sockets.TcpClient
        $iar = $client.BeginConnect($Target, $Port, $null, $null)
        if (-not ($iar.AsyncWaitHandle.WaitOne($TimeoutMs, $false) -and $client.Connected)) { return '' }
        $client.EndConnect($iar)
        $client.ReceiveTimeout = $TimeoutMs
        $client.SendTimeout    = $TimeoutMs
        $stream = $client.GetStream()
        # Refuse outright rather than trusting every caller to check. This function
    # writes bytes to a socket; on a raw print port those bytes are a print job.
    if ((Get-NtRawPortSet) -contains [int]$Port) {
        return '(raw port - no HTTP sent)'
    }
    $req = "HEAD / HTTP/1.0`r`nHost: $Target`r`nUser-Agent: NetToolkit`r`nConnection: close`r`n`r`n"
        $bytes = [System.Text.Encoding]::ASCII.GetBytes($req)
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush()
        $reader = New-Object System.IO.StreamReader($stream)
        $sb = New-Object System.Text.StringBuilder
        $deadline = (Get-Date).AddMilliseconds($TimeoutMs)
        while ((Get-Date) -lt $deadline) {
            $line = $reader.ReadLine()
            if ($null -eq $line) { break }
            if ($line -eq '') { break }
            [void]$sb.AppendLine($line)
        }
        $text = $sb.ToString()
        if ($text -match '(?im)^Server:\s*(.+)$') { return $matches[1].Trim() }
        if ($text -match '(?im)^(HTTP/[\d\.]+ \d+.*)$') { return $matches[1].Trim() }
        return ''
    } catch {
        return ''
    } finally {
        if ($client) { try { $client.Close() } catch {} }
    }
}

function Get-NtTlsSubject {
    # Certificate subject/issuer from a TLS handshake. On a firewall this is
    # usually the single most identifying fact available without credentials.
    #
    # The validation callback always returns true on purpose: we are reading the
    # certificate, not trusting it, and appliance certs are self-signed by
    # definition. PS 5.1 has no -SkipCertificateCheck, hence the callback.
    param([string]$Target, [int]$Port = 443, [int]$TimeoutMs = 2000)
    $client = $null
    $ssl = $null
    try {
        $client = New-Object System.Net.Sockets.TcpClient
        $iar = $client.BeginConnect($Target, $Port, $null, $null)
        if (-not ($iar.AsyncWaitHandle.WaitOne($TimeoutMs, $false) -and $client.Connected)) { return $null }
        $client.EndConnect($iar)
        $client.ReceiveTimeout = $TimeoutMs
        $client.SendTimeout    = $TimeoutMs

        $callback = [System.Net.Security.RemoteCertificateValidationCallback]{ param($a,$b,$c,$d) $true }
        $ssl = New-Object System.Net.Security.SslStream($client.GetStream(), $false, $callback)
        $ssl.AuthenticateAsClient($Target)
        $cert = $ssl.RemoteCertificate
        if (-not $cert) { return $null }
        $c2 = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($cert)
        # The negotiated protocol comes free with the handshake we already did,
        # and it dates an appliance more reliably than a banner. Deliberately
        # NOT probing whether TLS 1.0/1.1 are still accepted: that needs extra
        # handshakes and is a hardening question, not a reachability one.
        $proto = ''
        $cipher = ''
        try { $proto = [string]$ssl.SslProtocol } catch {}
        try { $cipher = [string]$ssl.CipherAlgorithm } catch {}
        return [pscustomobject]@{
            Subject   = [string]$c2.Subject
            Issuer    = [string]$c2.Issuer
            NotAfter  = $c2.NotAfter
            Thumbprint= [string]$c2.Thumbprint
            Protocol  = $proto
            Cipher    = $cipher
        }
    } catch {
        return $null
    } finally {
        if ($ssl) { try { $ssl.Dispose() } catch {} }
        if ($client) { try { $client.Close() } catch {} }
    }
}

function Get-NtSshBanner {
    # SSH servers announce themselves before any authentication.
    param([string]$Target, [int]$Port = 22, [int]$TimeoutMs = 1500)
    $client = $null
    try {
        $client = New-Object System.Net.Sockets.TcpClient
        $iar = $client.BeginConnect($Target, $Port, $null, $null)
        if (-not ($iar.AsyncWaitHandle.WaitOne($TimeoutMs, $false) -and $client.Connected)) { return '' }
        $client.EndConnect($iar)
        $client.ReceiveTimeout = $TimeoutMs
        $stream = $client.GetStream()
        $buf = New-Object byte[] 256
        $read = $stream.Read($buf, 0, $buf.Length)
        if ($read -gt 0) {
            return ([System.Text.Encoding]::ASCII.GetString($buf, 0, $read)).Trim()
        }
        return ''
    } catch {
        return ''
    } finally {
        if ($client) { try { $client.Close() } catch {} }
    }
}

function Resolve-NtPtr {
    # Reverse DNS with a hard ceiling. GetHostEntry blocks for many seconds on a
    # resolver that ignores PTR queries, and a traceroute does this per hop.
    param([string]$IPAddress, [int]$TimeoutMs = 1200)
    try {
        $task = [System.Net.Dns]::GetHostEntryAsync($IPAddress)
        if ($task.Wait($TimeoutMs)) { return [string]$task.Result.HostName }
    } catch {}
    return ''
}

function Invoke-NtTraceroute {
    # Hop-by-hop path using Ping with an increasing TTL.
    #
    # Not tracert.exe: parsing its localised console output is fragile, and doing
    # it directly gives control over probe count, a cancel check between probes,
    # and access to the reply TTL.
    #
    # A hop that does not answer is NOT a fault. Plenty of routers drop TTL
    # expiry or deprioritise it, so the trace continues past a silent hop and
    # reports "no reply" rather than "failed".
    param(
        [string]$Target,
        [int]$MaxHops = 20,
        [int]$TimeoutMs = 1200,
        [int]$ProbesPerHop = 2,
        [switch]$ResolveNames,
        $Shared = $null
    )
    $out = [pscustomobject]@{
        Target  = $Target
        Ok      = $false
        Reached = $false
        Hops    = @()
        Reason  = ''
    }
    $hops = [System.Collections.Generic.List[object]]::new()
    $ping = New-Object System.Net.NetworkInformation.Ping
    $buffer = New-Object byte[] 32
    try {
        for ($ttl = 1; $ttl -le $MaxHops; $ttl++) {
            if ($Shared -and $Shared.Cancel) { $out.Reason = 'Cancelled.'; break }
            if ($Shared) { $Shared.Status = ('Tracing hop {0} to {1}...' -f $ttl, $Target) }

            $opts = New-Object System.Net.NetworkInformation.PingOptions
            $opts.Ttl = $ttl
            $opts.DontFragment = $false

            $addr = ''
            $replyTtl = 0
            $final = $false
            $times = [System.Collections.Generic.List[double]]::new()

            for ($p = 0; $p -lt $ProbesPerHop; $p++) {
                if ($Shared -and $Shared.Cancel) { break }
                try {
                    $sw = [System.Diagnostics.Stopwatch]::StartNew()
                    $r = $ping.Send($Target, $TimeoutMs, $buffer, $opts)
                    $sw.Stop()
                    if ($r.Status -eq [System.Net.NetworkInformation.IPStatus]::TtlExpired -or
                        $r.Status -eq [System.Net.NetworkInformation.IPStatus]::Success) {
                        if ($r.Address) { $addr = $r.Address.ToString() }
                        $t = $sw.Elapsed.TotalMilliseconds
                        if ($r.RoundtripTime -gt $t) { $t = [double]$r.RoundtripTime }
                        $times.Add($t)
                        try { if ($r.Options -and $r.Options.Ttl -gt 0) { $replyTtl = [int]$r.Options.Ttl } } catch {}
                        if ($r.Status -eq [System.Net.NetworkInformation.IPStatus]::Success) { $final = $true }
                    }
                } catch {}
            }

            $stat = Get-NtStats -Values ([double[]]@($times))
            $name = ''
            if ($ResolveNames -and $addr) { $name = Resolve-NtPtr -IPAddress $addr }

            $reading = $null
            # Only the FINAL hop's TTL is a usable fingerprint. Intermediate
            # replies are TTL-expired messages generated by the router itself,
            # so their TTL describes the return path, not the forward hop count.
            if ($final -and $replyTtl -gt 0) { $reading = Get-NtTtlReading -ObservedTtl $replyTtl }

            $note = ''
            if ($times.Count -eq 0) {
                $note = 'no reply - this hop does not answer TTL expiry, which is common and not necessarily a fault'
            }

            $hops.Add([pscustomobject]@{
                Hop        = $ttl
                Address    = $addr
                Name       = $name
                Replies    = $times.Count
                MinMs      = [math]::Round($stat.Min, 1)
                AvgMs      = [math]::Round($stat.Mean, 1)
                MaxMs      = [math]::Round($stat.Max, 1)
                ReplyTtl   = $replyTtl
                TtlReading = $reading
                Final      = $final
                Note       = $note
            })

            if ($final) { $out.Reached = $true; break }
        }
        $out.Hops = [object[]]@($hops)
        $out.Ok = ($hops.Count -gt 0)
        if (-not $out.Reached -and $out.Ok -and -not $out.Reason) {
            $out.Reason = ('The trace did not reach {0} within {1} hops. Intermediate routers commonly suppress TTL-expired replies, so this alone is not proof of a break.' -f $Target, $MaxHops)
        }
    } catch {
        $out.Reason = $_.Exception.Message
    } finally {
        try { $ping.Dispose() } catch {}
    }
    return $out
}

function Get-NtLastRespondingHop {
    # The furthest point that ANSWERED - which is a useful reference to quote
    # to a vendor, and is NOT a demarcation line. Routers forward traffic
    # while declining to answer TTL-expiry all the time, and a tunnel hides
    # its interior hops by design, so the silence after this hop does not
    # locate the fault at it. Naming it a demarcation sends the ticket to
    # whoever owns the last device polite enough to reply.
    param($Trace)
    $last = $null
    foreach ($h in @($Trace.Hops)) {
        if ($h.Replies -gt 0 -and $h.Address) { $last = $h }
    }
    return $last
}

# =============================================================================
# 9. Port inventory
# =============================================================================

function Get-NtPortCatalogue {
    # Name lookup only. Keeping it in one place stops the GUI and the report
    # disagreeing about what port 4444 is.
    param()
    return @{
        21    = 'FTP';            22   = 'SSH';             23    = 'Telnet'
        25    = 'SMTP';           53   = 'DNS';             80    = 'HTTP'
        81    = 'HTTP-alt';       88   = 'Kerberos';        110   = 'POP3'
        135   = 'MSRPC';          139  = 'NetBIOS-SSN';     143   = 'IMAP'
        161   = 'SNMP';           389  = 'LDAP';            443   = 'HTTPS'
        444   = 'HTTPS-alt';      445  = 'SMB';             465   = 'SMTPS'
        500   = 'IKE';            514  = 'Syslog';          515   = 'LPD'
        587   = 'SMTP-submit';    631  = 'IPP';             636   = 'LDAPS'
        902   = 'VMware';         993  = 'IMAPS';           995   = 'POP3S'
        1194  = 'OpenVPN';        1433 = 'MSSQL';           1723  = 'PPTP'
        2179  = 'Hyper-V VMC';    3268 = 'LDAP-GC';         3306  = 'MySQL'
        3389  = 'RDP';            4433 = 'HTTPS-alt';       4443  = 'HTTPS-alt'
        4444  = 'Sophos SFOS admin'
        5000  = 'HTTP-alt';       5001 = 'HTTP-alt';        5060  = 'SIP'
        5061  = 'SIP-TLS';        5432 = 'PostgreSQL';      5985  = 'WinRM'
        5986  = 'WinRM-HTTPS';    8000 = 'HTTP-alt';        8080  = 'HTTP-proxy'
        8443  = 'HTTPS-alt';      8888 = 'HTTP-alt';        9100  = 'JetDirect'
        10000 = 'Webmin'
    }
}

function Get-NtGatewayPortList {
    # Management and service ports a firewall, router, or UTM actually listens
    # on. Deliberately short: this runs against customer edge kit, and a wide
    # sweep of the gateway is both slow and the sort of thing that lights up an
    # IDS for no diagnostic gain.
    @(22, 23, 53, 80, 81, 443, 444, 4433, 4443, 4444, 8080, 8443, 10000, 3389, 5985, 161, 500)
}

function Get-NtRawPortSet {
    # Ports that carry a RAW byte stream, not a request/response protocol.
    #
    # 9100 is JetDirect: whatever you send it is print data. This tool used to
    # send it "HEAD / HTTP/1.0" as part of banner grabbing, which a printer can
    # accept and emit as a page of garbage - a diagnostic tool producing
    # physical output on a customer's device. 515 (LPR) and 631 (IPP) are
    # included because the first is equally raw and the second, while it IS
    # HTTP-based, should be probed as IPP deliberately rather than swept as a
    # generic web port.
    #
    # Connect-only for everything in here: the fact that the TCP handshake
    # completes is the evidence, and no payload is sent at all.
    return @(9100, 9101, 9102, 515, 631)
}

function Get-NtCommonPortList {
    # General-purpose host ports for range sweeps.
    @(22, 53, 80, 135, 139, 443, 445, 515, 631, 902, 1433, 3389, 5985, 8080, 8443, 9100)
}

function Get-NtPortScan {
    # TCP connect scan of one host. Connect scan only - no raw sockets, nothing
    # that needs a driver, nothing that looks like an attack tool.
    param(
        [string]$Target,
        [int[]]$Ports = @(),
        [int]$TimeoutMs = 800,
        [switch]$Banners,
        $Shared = $null
    )
    if ([string]::IsNullOrWhiteSpace($Target)) { return @() }
    if (@($Ports).Count -eq 0) { $Ports = Get-NtCommonPortList }
    $catalogue = Get-NtPortCatalogue
    $open = [System.Collections.Generic.List[object]]::new()

    # The connects run in parallel. Sequentially, a filtered host costs
    # (ports x timeout): 17 management ports at 700 ms was nine seconds of
    # nothing, and a triage that scans the gateway, the target and the peer paid
    # it three times over. In parallel the whole list costs about one timeout.
    #
    # Same self-contained worker discipline as Invoke-NtSweep - raw .NET only,
    # because a runspace does not inherit the caller's functions.
    $portList = @(@($Ports) | ForEach-Object { [int]$_ } | Select-Object -Unique)
    # Returns an OUTCOME, not just a port number. The previous worker returned
    # 0 for everything that was not open, collapsing refused, timed out,
    # unreachable and "the probe could not start" into one value - and it used
    # BeginConnect + AsyncWaitHandle.WaitOne, which on this machine was not
    # signalled on failure at all, so every failure cost the full timeout and
    # was reported as a timeout regardless of what actually happened.
    $connectWorker = {
        param($ip, $port, $timeout)
        $res = New-Object psobject -Property @{ Port = [int]$port; Open = $false; Outcome = 'no-response'; ElapsedMs = 0.0; SocketError = '' }
        $client = $null
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        try {
            $client = New-Object System.Net.Sockets.TcpClient
            $task = $client.ConnectAsync($ip, [int]$port)
            $done = $false
            try { $done = $task.Wait([int]$timeout) } catch [System.AggregateException] { $done = $true }
            if (-not $done) {
                $res.Outcome = 'timeout'
            } else {
                $fault = $null
                if ($task.IsFaulted -and $task.Exception) {
                    $fault = $task.Exception.InnerException
                    while ($fault -is [System.AggregateException]) { $fault = $fault.InnerException }
                }
                if ($null -eq $fault) {
                    if ($client.Connected) { $res.Open = $true; $res.Outcome = 'accepted' } else { $res.Outcome = 'closed' }
                } elseif ($fault -is [System.Net.Sockets.SocketException]) {
                    $res.SocketError = [string]$fault.SocketErrorCode
                    switch ([string]$fault.SocketErrorCode) {
                        'ConnectionRefused'  { $res.Outcome = 'refused' }
                        'HostUnreachable'    { $res.Outcome = 'unreachable' }
                        'NetworkUnreachable' { $res.Outcome = 'unreachable' }
                        'TimedOut'           { $res.Outcome = 'timeout' }
                        default              { $res.Outcome = 'error' }
                    }
                } else {
                    $res.Outcome = 'error'
                    $res.SocketError = $fault.GetType().Name
                }
            }
        } catch {
            $res.Outcome = 'error'
            $res.SocketError = $_.Exception.GetType().Name
        } finally {
            $sw.Stop()
            if ($client) { try { $client.Close() } catch {} }
        }
        $res.ElapsedMs = [math]::Round($sw.Elapsed.TotalMilliseconds, 1)
        return $res
    }

    # Per-port outcomes, so a caller can tell 'refused' from 'timed out'
    # instead of inferring "closed or filtered" from absence.
    $script:NtLastPortOutcomes = @{}
    $openPorts = [System.Collections.Generic.List[int]]::new()
    $pool = [RunspaceFactory]::CreateRunspacePool(1, [math]::Min(32, [math]::Max(1, $portList.Count)))
    $pool.Open()
    $jobs = [System.Collections.Generic.List[object]]::new()
    try {
        if ($Shared) { $Shared.Status = ('Probing {0} ports on {1}...' -f $portList.Count, $Target) }
        foreach ($p in $portList) {
            if ($Shared -and $Shared.Cancel) { break }
            $ps = [PowerShell]::Create()
            $ps.RunspacePool = $pool
            [void]$ps.AddScript($connectWorker).AddArgument($Target).AddArgument($p).AddArgument($TimeoutMs)
            $jobs.Add([pscustomobject]@{ PS = $ps; Handle = $ps.BeginInvoke() })
        }
        foreach ($job in $jobs) {
            try {
                foreach ($result in @($job.PS.EndInvoke($job.Handle))) {
                    if ($null -eq $result) { continue }
                    $script:NtLastPortOutcomes[[int]$result.Port] = $result
                    if ($result.Open) { $openPorts.Add([int]$result.Port) }
                }
            } catch {
            } finally {
                try { $job.PS.Dispose() } catch {}
            }
        }
    } finally {
        try { $pool.Close(); $pool.Dispose() } catch {}
    }

    # Banners are grabbed sequentially, but only for ports that actually
    # answered - normally a handful, and each one is a real conversation.
    foreach ($p in @(@($openPorts) | Sort-Object)) {
        if ($Shared -and $Shared.Cancel) { break }
        if ($Shared) { $Shared.Status = ('Reading {0}:{1}...' -f $Target, $p) }

        $name = ''
        if ($catalogue.ContainsKey([int]$p)) { $name = [string]$catalogue[[int]$p] }
        $banner = ''
        $tls = $null

        if ($Banners) {
            switch ([int]$p) {
                22 { $banner = Get-NtSshBanner -Target $Target -Port $p }
                default {
                    if ($p -in @(443, 444, 4433, 4443, 4444, 8443, 636, 993, 995, 5986)) {
                        $tls = Get-NtTlsSubject -Target $Target -Port $p
                        if ($tls) {
                            $banner = $tls.Subject
                            if ($tls.Protocol) { $banner = ('{0}  [{1}]' -f $tls.Subject, $tls.Protocol) }
                        }
                    } elseif ((Get-NtRawPortSet) -contains [int]$p) {
                        # Connect-only. See Get-NtRawPortSet: sending HTTP to a
                        # raw print socket can print it.
                        $banner = 'open (raw port - connect only, no data sent)'
                    } elseif ($p -in @(80, 81, 8000, 8080, 8888, 5000, 5001, 10000)) {
                        $banner = Get-NtHttpBanner -Target $Target -Port $p
                    }
                }
            }
        }

        $open.Add([pscustomobject]@{
            Port    = [int]$p
            Service = $name
            Banner  = $banner
            Tls     = $tls
        })
    }
    return [object[]]@($open)
}

function Get-NtApplianceHint {
    # Name the box from whatever it volunteered. Used to attach the right
    # vendor-side commands to the escalation summary.
    param([string]$Vendor = '', $OpenPorts = @())
    $blob = $Vendor
    foreach ($p in @($OpenPorts)) {
        $blob += ' ' + [string]$p.Banner
        if ($p.Tls) { $blob += ' ' + [string]$p.Tls.Issuer }
    }
    $blob = $blob.ToLower()

    $map = @(
        @{ Match = 'sophos|sfos|astaro';         Name = 'Sophos (SFOS)' },
        @{ Match = 'fortinet|fortigate';         Name = 'Fortinet FortiGate' },
        @{ Match = 'sonicwall';                  Name = 'SonicWall' },
        @{ Match = 'watchguard';                 Name = 'WatchGuard' },
        @{ Match = 'palo alto|panos';            Name = 'Palo Alto' },
        @{ Match = 'velocloud|vmware sd-wan';    Name = 'VMware VeloCloud SD-WAN' },
        @{ Match = 'meraki|cisco';               Name = 'Cisco / Meraki' },
        @{ Match = 'ubiquiti|unifi|edgeos';      Name = 'Ubiquiti' },
        @{ Match = 'mikrotik|routeros|routerboard|rosssh'; Name = 'MikroTik (RouterOS)' },
        @{ Match = 'pfsense|netgate|opnsense';   Name = 'pfSense / OPNsense' },
        @{ Match = 'draytek|vigor';              Name = 'DrayTek' },
        @{ Match = 'juniper';                    Name = 'Juniper' },
        @{ Match = 'netgear';                    Name = 'Netgear' },
        @{ Match = 'tp-link|tplink';             Name = 'TP-Link' }
    )
    foreach ($m in $map) {
        if ($blob -match $m.Match) { return [string]$m.Name }
    }
    return ''
}

function Get-NtVendorCommands {
    # Commands to run ON the appliance, from the runbook's SFOS quick reference.
    # The escalation summary carries these so the next person does not have to
    # rediscover which menu option opens the console.
    param([string]$Appliance = '', [string]$Target = 'x.x.x.x')
    $cmds = [System.Collections.Generic.List[string]]::new()
    if ($Appliance -like 'Sophos*') {
        $cmds.Add('SSH as admin, option 4 = Device Console, option 5 = Advanced Shell (numbering varies by firmware)')
        $cmds.Add(('console> drop-packet-capture ''host {0}''' -f $Target))
        $cmds.Add(('console> ping {0}' -f $Target))
        $cmds.Add(('shell#   ip route get {0}' -f $Target))
        $cmds.Add(('shell#   tcpdump -i PortN -n host {0}' -f $Target))
        $cmds.Add('Log Viewer -> Firewall: filter on the destination IP and read the NAT rule ID, not just allow/deny')
        $cmds.Add('Log Viewer -> Admin: config changes, for "when did this last work"')
    } else {
        $cmds.Add(('Packet capture on the WAN/transport interface filtered to host {0}' -f $Target))
        $cmds.Add('Firewall log filtered on the destination IP, showing the rule AND any NAT applied')
        $cmds.Add(('Routing table lookup for {0} on the edge device' -f $Target))
    }
    return [object[]]@($cmds)
}

function Get-NtGatewaySection {
    # What the gateway is, and what it is listening on.
    #
    # Runbook section 2, "Management plane is not the data plane": in the
    # original case the firewall silently dropped ICMP to itself while routing,
    # serving DHCP and answering HTTPS on 4444 perfectly well. So a gateway that
    # fails to ping is reported as INFORMATION, never as a fault, whenever any
    # other evidence shows it working.
    param(
        $Context = $null,
        [string]$Gateway = '',
        [int[]]$Ports = @(),
        [int]$TimeoutMs = 700,
        # -NoVendorLookup did not reach this function at all, so an operator
        # who explicitly asked for no online enrichment still triggered an
        # outbound lookup for the gateway's MAC. On an isolated or
        # air-gapped site that is both a surprise and a delay.
        [switch]$NoVendorLookup,
        $Shared = $null
    )
    if (-not $Context) { $Context = Get-NtLocalContext }
    if (-not $Gateway) { $Gateway = Get-NtPrimaryGateway -Context $Context }
    if (@($Ports).Count -eq 0) { $Ports = Get-NtGatewayPortList }

    if (-not $Gateway) {
        return (New-NtSection -Name 'Gateway' -State 'skipped' -Reason 'This machine has no default gateway, so there is no gateway to inventory.')
    }

    $rows = [System.Collections.Generic.List[object]]::new()

    $icmp = Test-NtIcmp -Target $Gateway -Count 3 -TimeoutMs 800 -Shared $Shared
    if ($icmp.Success) {
        $rows.Add((New-NtRow -Group 'Gateway' -Check ('ICMP to {0}' -f $Gateway) -Result ('{0}/{1} replies, {2} ms avg' -f $icmp.Received, $icmp.Sent, [math]::Round($icmp.Rtt.Mean,1)) -Status 'ok' -Detail $icmp.Detail -Data $icmp))
    } else {
        $rows.Add((New-NtRow -Group 'Gateway' -Check ('ICMP to {0}' -f $Gateway) -Result 'No reply' -Status 'info' -Detail 'The gateway does not answer ping. That is a configuration choice on most firewalls and proves nothing about forwarding - ARP resolution, working DHCP and working internet are sufficient proof of life.' -Data $icmp))
    }

    $arp = Get-NtArpTable
    $gwMac = ''
    $gwVendor = ''
    if ($arp.ContainsKey($Gateway)) {
        $gwMac = $arp[$Gateway].Mac
        $v = Get-NtOuiVendor -Macs @($gwMac) -NoLookup:$NoVendorLookup -Shared $Shared
        if ($v.ContainsKey($gwMac)) { $gwVendor = $v[$gwMac] }
        $rows.Add((New-NtRow -Group 'Gateway' -Check 'Layer 2 identity' -Result ('{0} ({1})' -f (Format-NtMac $gwMac), $gwVendor) -Status 'ok' -Detail 'The gateway answers ARP, so the local segment and VLAN are correct.'))
    } else {
        $rows.Add((New-NtRow -Group 'Gateway' -Check 'Layer 2 identity' -Result 'Not in ARP cache' -Status 'warn' -Detail 'The gateway has not answered ARP. If nothing on the LAN works, start here rather than with routing.'))
    }

    if ($Shared) { $Shared.Status = ('Inventorying ports on {0}...' -f $Gateway) }
    $open = Get-NtPortScan -Target $Gateway -Ports $Ports -TimeoutMs $TimeoutMs -Banners -Shared $Shared

    if (@($open).Count -eq 0) {
        $rows.Add((New-NtRow -Group 'Gateway' -Check 'Open TCP ports' -Result 'None of the probed ports answered' -Status 'info' -Detail ('Probed {0} management ports. A hardened edge device legitimately answers none of them from the LAN.' -f @($Ports).Count)))
    } else {
        foreach ($p in @($open)) {
            $label = ('{0}/tcp {1}' -f $p.Port, $p.Service)
            $result = if ($p.Banner) { $p.Banner } else { 'open' }
            $rows.Add((New-NtRow -Group 'Gateway' -Check $label -Result $result -Status 'ok' -Detail 'Open. Listed as inventory, not as a finding.' -Data $p))
        }
    }

    $appliance = Get-NtApplianceHint -Vendor $gwVendor -OpenPorts $open
    if ($appliance) {
        $rows.Add((New-NtRow -Group 'Gateway' -Check 'Appliance' -Result $appliance -Status 'info' -Detail 'Identified from the OUI and the TLS or HTTP banners. Vendor-side commands for this platform are included in the escalation summary.'))
    }

    $data = [pscustomobject]@{
        Gateway    = $Gateway
        Mac        = $gwMac
        Vendor     = $gwVendor
        Icmp       = $icmp
        OpenPorts  = [object[]]@($open)
        Appliance  = $appliance
        PortsProbed= [object[]]@($Ports)
    }

    $method = ('TCP connect scan of {0} management ports, plus HTTP Server headers, TLS certificate subjects and SSH banners from whatever answered.' -f @($Ports).Count)
    return (New-NtSection -Name 'Gateway' -State 'measured' -Method $method -Rows @($rows) -Data $data -Caveats @(
        'Failing to ping a firewall proves nothing about whether it is forwarding.',
        'UDP services (SNMP, IKE, DNS over UDP) are not tested - a connect scan cannot see them.'
    ))
}

# =============================================================================
# 10. Target specification and sweep
# =============================================================================

function Resolve-NtTargetSpec {
    # Accepts a single IP, a hostname, CIDR, a-b octet ranges, or a comma list,
    # and returns the expanded address list.
    #
    # The size cap is deliberate. Sweeping a /16 from a client machine is slow,
    # noisy, and the sort of thing that gets an RMM agent quarantined by EDR.
    param(
        [string]$Spec,
        [int]$MaxAddresses = 1024,
        # Even -Force has a ceiling. Beyond this the answer is "use a different
        # tool", not "wait an hour and hope". 8,192 is a /19; a /16 is refused,
        # which matches this function's own stated intent - sweeping one from a
        # client machine is slow, noisy and liable to get an agent quarantined.
        [int]$AbsoluteMaxAddresses = 8192,
        [switch]$Force
    )
    $out = [pscustomobject]@{
        Spec      = $Spec
        Addresses = @()
        Count     = 0
        Kind      = ''
        Ok        = $false
        Reason    = ''
    }
    if ([string]::IsNullOrWhiteSpace($Spec)) {
        $out.Reason = 'No target was supplied.'
        return $out
    }

    $addresses = [System.Collections.Generic.List[string]]::new()
    $kinds = [System.Collections.Generic.List[string]]::new()

    foreach ($part in @($Spec -split '[,;]' | ForEach-Object { $_.Trim() } | Where-Object { $_ })) {

        # CIDR
        if ($part -match '^(\d+\.\d+\.\d+\.\d+)/(\d+)$') {
            $net = $matches[1]; $len = [int]$matches[2]
            if ($len -lt 0 -or $len -gt 32) { $out.Reason = ('Invalid prefix length in {0}.' -f $part); return $out }
            $netInt = ConvertTo-NtUInt32 $net
            if ($null -eq $netInt) { $out.Reason = ('Invalid network address in {0}.' -f $part); return $out }
            $mask = if ($len -eq 0) { [uint32]0 } else { [uint32]([uint32]::MaxValue -shl (32 - $len)) }
            $first = [uint32]($netInt -band $mask)
            # 64-bit throughout. A /0 is 2^32 addresses, which does not fit in
            # the UInt32 this used to compute in: the subtraction went negative
            # and the cast threw before any size check could explain itself.
            $size  = [uint64][math]::Pow(2, (32 - $len))
            $lastU = [uint64]$first + $size - 1
            # Skip network and broadcast for anything wider than a /31.
            $loU = if ($len -le 30) { [uint64]$first + 1 } else { [uint64]$first }
            $hiU = if ($len -le 30) { $lastU - 1 } else { $lastU }
            $usable = if ($hiU -ge $loU) { $hiU - $loU + 1 } else { [uint64]0 }
            # COUNT FIRST, then decide. Enumerating and breaking part-way
            # produced a truncated set reported as Ok - a /16 came back as
            # 4,097 of 65,534 addresses and called itself complete, so a
            # technician believed a subnet was swept when 94% of it was never
            # touched.
            if ($usable -gt [uint64]$AbsoluteMaxAddresses) {
                $out.Reason = ('{0} covers {1:N0} usable addresses, beyond the {2:N0} this tool will enumerate under any circumstances. Sweep a narrower prefix.' -f $part, $usable, $AbsoluteMaxAddresses)
                return $out
            }
            if ($usable -gt [uint64]$MaxAddresses -and -not $Force) {
                $out.Reason = ('{0} covers {1:N0} usable addresses, above the {2:N0} safety cap. Narrow the range, or re-run with -Force if you really mean it - large sweeps are slow and can trip intrusion detection.' -f $part, $usable, $MaxAddresses)
                return $out
            }
            for ($i = $loU; $i -le $hiU; $i++) {
                $addresses.Add((ConvertFrom-NtUInt32 ([uint32]$i)))
            }
            $kinds.Add('cidr')
            continue
        }

        # a.b.c.d-e  (last-octet range)
        if ($part -match '^(\d+\.\d+\.\d+)\.(\d+)\s*-\s*(\d+)$') {
            $prefix = $matches[1]; $start = [int]$matches[2]; $end = [int]$matches[3]
            # \d+ accepts 999. The prefix octets were never range-checked, so
            # 999.1.2.1-2 was accepted as a valid target and swept.
            $badOctet = $false
            foreach ($o in @($prefix -split '\.')) { if ([int]$o -lt 0 -or [int]$o -gt 255) { $badOctet = $true } }
            if ($badOctet) { $out.Reason = ('{0} is not a valid IPv4 address - every octet must be 0-255.' -f $part); return $out }
            if ($start -gt $end) { $tmp = $start; $start = $end; $end = $tmp }
            if ($start -lt 0 -or $end -gt 255) { $out.Reason = ('Octet range out of bounds in {0}.' -f $part); return $out }
            for ($i = $start; $i -le $end; $i++) { $addresses.Add(('{0}.{1}' -f $prefix, $i)) }
            $kinds.Add('range')
            continue
        }

        # a.b.c.d - a.b.c.e  (full address range)
        if ($part -match '^(\d+\.\d+\.\d+\.\d+)\s*-\s*(\d+\.\d+\.\d+\.\d+)$') {
            $a = ConvertTo-NtUInt32 $matches[1]
            $b = ConvertTo-NtUInt32 $matches[2]
            if ($null -eq $a -or $null -eq $b) { $out.Reason = ('Invalid address range {0}.' -f $part); return $out }
            if ($a -gt $b) { $t = $a; $a = $b; $b = $t }
            $spanU = [uint64]$b - [uint64]$a + 1
            if ($spanU -gt [uint64]$AbsoluteMaxAddresses) {
                $out.Reason = ('{0} covers {1:N0} addresses, beyond the {2:N0} this tool will enumerate under any circumstances.' -f $part, $spanU, $AbsoluteMaxAddresses)
                return $out
            }
            if ($spanU -gt [uint64]$MaxAddresses -and -not $Force) {
                $out.Reason = ('{0} covers {1:N0} addresses, above the {2:N0} safety cap. Narrow the range, or re-run with -Force.' -f $part, $spanU, $MaxAddresses)
                return $out
            }
            for ($i = [uint64]$a; $i -le [uint64]$b; $i++) {
                $addresses.Add((ConvertFrom-NtUInt32 ([uint32]$i)))
            }
            $kinds.Add('range')
            continue
        }

        # Single IPv4
        if (Test-NtIsIPv4 $part) {
            $addresses.Add($part)
            $kinds.Add('single')
            continue
        }

        # MAC: wherever the neighbour cache, or failing that the inventory,
        # last saw it. Refused rather than guessed when neither knows it.
        if (Test-NtIsMacAddress $part) {
            $mt = Resolve-NtMacTarget -Mac $part
            if ($mt.BestAddress) {
                $addresses.Add([string]$mt.BestAddress)
                $kinds.Add('mac')
                continue
            }
            $out.Reason = ('{0} is not in this PC''s neighbour cache and the inventory has no record of it. A MAC address is only visible from its own subnet.' -f $mt.MacFormatted)
            return $out
        }

        # Hostname
        try {
            $resolved = @([System.Net.Dns]::GetHostAddresses($part) |
                          Where-Object { $_.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork })
            if ($resolved.Count -gt 0) {
                foreach ($r in $resolved) { $addresses.Add($r.ToString()) }
                $kinds.Add('hostname')
                continue
            }
            $out.Reason = ('{0} resolved to no IPv4 address.' -f $part)
            return $out
        } catch {
            $out.Reason = ('{0} is not an IP address, range, or resolvable name.' -f $part)
            return $out
        }
    }

    # HashSet, not Select-Object -Unique. The latter is quadratic - measured at
    # 2.3 s for 4,094 addresses, and a /16 did not return inside five minutes.
    $seen = New-Object 'System.Collections.Generic.HashSet[string]'
    $ordered = [System.Collections.Generic.List[string]]::new()
    foreach ($a in $addresses) { if ($seen.Add($a)) { $ordered.Add($a) } }
    $unique = @($ordered.ToArray())
    $out.Addresses = [object[]]$unique
    $out.Count = $unique.Count
    $out.Kind = (($kinds | Select-Object -Unique) -join '+')

    if ($unique.Count -eq 0) {
        $out.Reason = 'The target expanded to no addresses.'
        return $out
    }
    if ($unique.Count -gt $MaxAddresses -and -not $Force) {
        $out.Reason = ('{0} addresses exceeds the {1} address safety cap. Narrow the range, or re-run with -Force if you really mean it - large sweeps are slow and can trip intrusion detection.' -f $unique.Count, $MaxAddresses)
        return $out
    }
    $out.Ok = $true
    return $out
}

function Test-NtRangeOnLink {
    # Is every address in this set on a directly connected subnet?
    #
    # This gates ARP recovery in the sweep. Recovering "alive but firewalled"
    # hosts from the ARP cache is correct on-link and WRONG off-link: a routed
    # host can never appear in this machine's ARP table, so applying the same
    # logic to a remote range would invent hosts that do not exist.
    param([string[]]$Addresses, $Context = $null)
    if (-not $Context) { $Context = Get-NtLocalContext }
    $prefixes = @($Context.ConnectedPrefixes)
    if ($prefixes.Count -eq 0) { return $false }
    foreach ($a in @($Addresses)) {
        $hit = $false
        foreach ($p in $prefixes) {
            if (Test-NtIpInPrefix -IPAddress $a -Prefix $p) { $hit = $true; break }
        }
        if (-not $hit) { return $false }
    }
    return $true
}

function Invoke-NtSweep {
    # Parallel reachability sweep over an address list.
    #
    # The worker scriptblock is deliberately SELF-CONTAINED - raw .NET only, no
    # calls back into this file. Runspaces do not inherit the caller's function
    # table, and rebuilding the whole helper file inside every one of 32
    # runspaces to get two functions is a poor trade.
    param(
        [string[]]$Addresses,
        [int[]]$Ports = @(),
        [int]$PingTimeoutMs = 500,
        [int]$PortTimeoutMs = 400,
        [int]$ThrottleLimit = 32,
        [switch]$ScanPorts,
        [switch]$ResolveNames,
        [switch]$NoVendorLookup,
        $Context = $null,
        $Shared = $null
    )
    if (-not $Context) { $Context = Get-NtLocalContext }
    $list = @($Addresses)
    if ($list.Count -eq 0) {
        return (New-NtSection -Name 'Sweep' -State 'skipped' -Reason 'No addresses to sweep.')
    }
    if (@($Ports).Count -eq 0) { $Ports = Get-NtCommonPortList }

    $started = Get-Date
    $onLink = Test-NtRangeOnLink -Addresses $list -Context $Context

    $worker = {
        param($ip, $pingTimeout, $portTimeout, $ports, $doPorts, $doNames)

        $result = [pscustomobject]@{
            IP        = $ip
            Alive     = $false       # ICMP only - kept for compatibility
            IcmpOk    = $false
            TcpOk     = $false
            PortsTested = $false
            Responded = $false       # ICMP *or* TCP - the real question
            Ttl       = 0
            RttMs     = 0.0
            Hostname  = ''
            OpenPorts = @()
            Status    = ''
        }

        try {
            $ping = New-Object System.Net.NetworkInformation.Ping
            $buf  = New-Object byte[] 32
            $r = $ping.Send($ip, $pingTimeout, $buf)
            $result.Status = [string]$r.Status
            if ($r.Status -eq [System.Net.NetworkInformation.IPStatus]::Success) {
                $result.Alive = $true
                $result.IcmpOk = $true
                $result.RttMs = [double]$r.RoundtripTime
                try { if ($r.Options) { $result.Ttl = [int]$r.Options.Ttl } } catch {}
            }
            $ping.Dispose()
        } catch {
            $result.Status = $_.Exception.Message
        }

        if ($doNames -and ($result.IcmpOk -or $doPorts)) {
            try {
                $task = [System.Net.Dns]::GetHostEntryAsync($ip)
                if ($task.Wait(2000)) { $result.Hostname = [string]$task.Result.HostName }
            } catch {}
        }

        # Independent of ICMP. This used to be gated on $result.Alive, which is
        # set only by a successful ping - so every routed host that blocks
        # ICMP and serves HTTPS, SMB or RDP was reported as absent. That is
        # the default posture of a hardened Windows server.
        if ($doPorts) {
            $result.PortsTested = $true
            $found = [System.Collections.Generic.List[int]]::new()
            foreach ($p in @($ports)) {
                $client = $null
                try {
                    $client = New-Object System.Net.Sockets.TcpClient
                    # ConnectAsync: a failed connect completes immediately,
                    # where BeginConnect's wait handle was not signalled on
                    # failure at all - measured on this machine, even a
                    # bound-then-closed loopback port waited out the full
                    # timeout. In this loop that cost is paid per host, per
                    # port, across the whole sweep.
                    $task = $client.ConnectAsync($ip, [int]$p)
                    $done = $false
                    try { $done = $task.Wait([int]$portTimeout) } catch [System.AggregateException] { $done = $true }
                    if ($done -and -not $task.IsFaulted -and $client.Connected) { $found.Add([int]$p) }
                } catch {
                } finally {
                    if ($client) { try { $client.Close() } catch {} }
                }
            }
            $result.OpenPorts = [int[]]@($found)
            if ($found.Count -gt 0) { $result.TcpOk = $true }
        }
        $result.Responded = ($result.IcmpOk -or $result.TcpOk)

        return $result
    }

    $pool = [RunspaceFactory]::CreateRunspacePool(1, [math]::Max(1, $ThrottleLimit))
    $pool.Open()
    $jobs = [System.Collections.Generic.List[object]]::new()
    $results = [System.Collections.Generic.List[object]]::new()

    try {
        foreach ($ip in $list) {
            if ($Shared -and $Shared.Cancel) { break }
            $ps = [PowerShell]::Create()
            $ps.RunspacePool = $pool
            [void]$ps.AddScript($worker)
            [void]$ps.AddArgument($ip)
            [void]$ps.AddArgument($PingTimeoutMs)
            [void]$ps.AddArgument($PortTimeoutMs)
            [void]$ps.AddArgument([int[]]@($Ports))
            [void]$ps.AddArgument([bool]$ScanPorts)
            [void]$ps.AddArgument([bool]$ResolveNames)
            $jobs.Add([pscustomobject]@{ PS = $ps; Handle = $ps.BeginInvoke(); IP = $ip })
        }

        $done = 0
        foreach ($j in $jobs) {
            if ($Shared -and $Shared.Cancel) {
                try { $j.PS.Stop() } catch {}
                try { $j.PS.Dispose() } catch {}
                continue
            }
            try {
                $r = $j.PS.EndInvoke($j.Handle)
                foreach ($item in @($r)) { if ($item) { $results.Add($item) } }
            } catch {
            } finally {
                try { $j.PS.Dispose() } catch {}
            }
            $done++
            if ($Shared) {
                $Shared.Status = ('Swept {0} of {1} addresses...' -f $done, $jobs.Count)
                $Shared.Progress = [int](100 * $done / [math]::Max(1, $jobs.Count))
            }
        }
    } finally {
        try { $pool.Close(); $pool.Dispose() } catch {}
    }

    # ARP enrichment. On-link only - see Test-NtRangeOnLink for why.
    $arp = Get-NtArpTable
    $hosts = [System.Collections.Generic.List[object]]::new()
    $seen = @{}

    foreach ($r in @($results)) {
        $seen[$r.IP] = $true
        # Responded, not Alive. Alive is ICMP only, so a host proven by a
        # completed TCP handshake was dropped from the list entirely.
        if (-not $r.Responded) { continue }
        $mac = ''
        if ($onLink -and $arp.ContainsKey($r.IP)) { $mac = $arp[$r.IP].Mac }
        $disc = if ($r.IcmpOk -and $r.TcpOk) { 'ICMP+TCP' } elseif ($r.IcmpOk) { 'ICMP' } else { 'TCP' }
        $hosts.Add([pscustomobject]@{
            IP         = $r.IP
            Discovery  = $disc
            Ttl        = [int]$r.Ttl
            TtlReading = (Get-NtTtlReading -ObservedTtl ([int]$r.Ttl))
            RttMs      = [double]$r.RttMs
            Hostname   = [string]$r.Hostname
            Mac        = $mac
            Vendor     = ''
            OpenPorts  = [int[]]@($r.OpenPorts)
        })
    }

    $arpRecovered = 0
    if ($onLink) {
        # Windows Firewall drops inbound ICMP on the Public and Private profiles
        # by default, so a ping-only sweep misses most workgroup machines. A host
        # in the ARP cache answered ARP, and a host that answers ARP is alive.
        foreach ($ip in $list) {
            if ($seen.ContainsKey($ip)) {
                $already = @(@($hosts) | Where-Object { $_.IP -eq $ip })
                if ($already.Count -gt 0) { continue }
            }
            if (-not $arp.ContainsKey($ip)) { continue }
            # Only a state that PROVES life counts as a discovery. Every state
            # used to qualify, so a Stale entry from before the fault, or an
            # Unreachable entry recording a failed resolution, was listed as a
            # live host.
            $nstate = [string]$arp[$ip].State
            if (-not (Get-NtNeighbourConfidence -State $nstate).ProvesLife) { continue }
            $hosts.Add([pscustomobject]@{
                IP         = $ip
                Discovery  = ('ARP ({0})' -f $nstate)
                Ttl        = 0
                TtlReading = (Get-NtTtlReading -ObservedTtl 0)
                RttMs      = 0.0
                Hostname   = ''
                Mac        = $arp[$ip].Mac
                Vendor     = ''
                OpenPorts  = @()
                PortsTested = $false
            })
            $arpRecovered++
        }
    }

    # Vendor lookup once, for every MAC found.
    $macs = @(@($hosts) | Where-Object { $_.Mac } | ForEach-Object { $_.Mac })
    if ($macs.Count -gt 0) {
        $vendors = Get-NtOuiVendor -Macs $macs -NoLookup:$NoVendorLookup -Shared $Shared
        foreach ($h in $hosts) {
            if ($h.Mac -and $vendors.ContainsKey($h.Mac)) { $h.Vendor = [string]$vendors[$h.Mac] }
        }
    }

    $sorted = @($hosts | Sort-Object { ConvertTo-NtUInt32 $_.IP })
    $rows = [System.Collections.Generic.List[object]]::new()
    foreach ($h in $sorted) {
        $bits = [System.Collections.Generic.List[string]]::new()
        if ($h.Hostname) { $bits.Add($h.Hostname) }
        if ($h.Mac) { $bits.Add(('{0} {1}' -f (Format-NtMac $h.Mac), $h.Vendor)) }
        if (@($h.OpenPorts).Count -gt 0) { $bits.Add(('ports ' + (@($h.OpenPorts) -join ','))) }
        if ($h.Ttl -gt 0) { $bits.Add(('TTL {0}' -f $h.Ttl)) }
        $rows.Add((New-NtRow -Group 'Sweep' -Check $h.IP -Result ($bits -join ' | ') -Status 'ok' -Detail $h.TtlReading.Detail -Data $h))
    }

    $caveats = [System.Collections.Generic.List[string]]::new()
    if ($onLink) {
        $caveats.Add('The range is on a directly connected subnet, so hosts that ignore ICMP were recovered from the ARP cache.')
    } else {
        $caveats.Add('The range is OFF-LINK (routed). ARP cannot see routed hosts, so a host that silently drops ICMP is invisible here and will read as not responding. Absence from this list is not proof a host is down.')
    }
    if (-not $ScanPorts) { $caveats.Add('Port scanning was not requested, so open ports are not listed.') }

    # COVERAGE, not input count. Probed used to report $list.Count - the number
    # of addresses ASKED for - so a run cancelled after 18 of 50 still claimed
    # 50 probed, and every untested address read as a silent host.
    $actuallyProbed = @($results).Count
    $cancelled = ($Shared -and $Shared.Cancel)
    $notTested = [math]::Max(0, $list.Count - $actuallyProbed)
    if ($notTested -gt 0) {
        $caveats.Add(('Stopped after {0} of {1} addresses. The remaining {2} were NOT tested - they are absent from this list because nothing was sent to them, not because nothing answered.' -f $actuallyProbed, $list.Count, $notTested))
    }

    $data = [pscustomobject]@{
        Hosts        = [object[]]@($sorted)
        Requested    = $list.Count
        Probed       = $actuallyProbed
        NotTested    = $notTested
        Cancelled    = [bool]$cancelled
        Alive        = @($sorted).Count
        OnLink       = $onLink
        ArpRecovered = $arpRecovered
        PortsProbed  = [int[]]@($Ports)
    }

    $method = ('Parallel ICMP echo across {0} addresses at {1} concurrent probes' -f $actuallyProbed, $ThrottleLimit)
    if ($ScanPorts) { $method += (', plus a TCP connect scan of {0} ports on every address independently of ICMP' -f @($Ports).Count) }
    if ($onLink) { $method += ', plus ARP-cache recovery of hosts that ignore ICMP' }

    # A cancelled sweep is a PARTIAL result, not a measured one.
    $sweepState = 'measured'
    $sweepReason = ''
    if ($cancelled -or $notTested -gt 0) {
        $sweepState = 'skipped'
        $sweepReason = ('The sweep was stopped early: {0} of {1} addresses were tested. Treat this as a partial result - the untested addresses are unknown, not absent.' -f $actuallyProbed, $list.Count)
    }
    $section = New-NtSection -Name 'Sweep' -State $sweepState -Reason $sweepReason -Method $method -Rows @($rows) -Data $data -Caveats @($caveats) -StartedUtc $started -DurationSec ((Get-Date) - $started).TotalSeconds
    return $section
}

# =============================================================================
# 11. Path triage - the runbook's reusable ladder, automated
# =============================================================================
# Runbook section 4. Work outward; each rung isolates one segment.
#
# One deliberate difference from the runbook: the ladder RECORDS the first
# failure but does not stop there. A human stops because each rung costs time;
# this costs seconds, and rungs 5 to 7 are exactly what separates "the transport
# is broken" from "the transport is fine and one host has no return route" - the
# distinction that took hours to establish by hand.

function New-NtReport {
    param(
        [string]$Target = '',
        [string]$Peer = '',
        $Profile = $null
    )
    [pscustomobject]@{
        schema       = 'nettoolkit-report/1'
        version      = (Get-NtVersion)
        generatedUtc = (ConvertTo-NtIso8601 (Get-Date))
        computerName = $env:COMPUTERNAME
        userName     = $env:USERNAME
        elevated     = (Test-NtElevated)
        target       = $Target
        peer         = $Peer
        site         = $(if ($Profile) { [string]$Profile.site } else { '' })
        profile      = $Profile
        sections     = @()
        findings     = @()
        ladder       = @()
        verdict      = $null
        # complete | cancelled. A consumer must be able to tell a finished run
        # from an abandoned one WITHOUT inspecting the findings, because an
        # abandoned run's probes return "no reply" and look exactly like
        # failures.
        runState     = 'complete'
        # The device, as found: every name and address answer and who gave it,
        # the address chosen and why, and the one-line status.
        identity     = $null
        device       = $null
        # How the comparison host was obtained: given, profile, inventory,
        # probe, not-needed, or none.
        neighbour    = $null
    }
}

function New-NtRung {
    param(
        [int]$Number,
        [string]$Name,
        [ValidateSet('ok','warn','fail','skipped','info')][string]$Status,
        [string]$Result,
        [string]$Detail = ''
    )
    [pscustomobject]@{
        number = $Number
        name   = $Name
        status = $Status
        result = $Result
        detail = $Detail
    }
}

function Invoke-NtPathTriage {
    param(
        [string]$Target,
        [string]$Peer = '',
        # The destination network, if it is known - e.g. 10.50.40.0/23. Left
        # empty, subnet membership stays UNKNOWN rather than being guessed at
        # /24, because a selected route prefix is not necessarily the
        # destination's mask: it may be a default, a summary or a host route.
        [string]$DestinationCidr = '',
        [int[]]$Ports = @(),
        $Profile = $null,
        [int]$MaxHops = 20,
        [int]$PingCount = 4,
        [switch]$SkipTrace,
        [switch]$SkipGateway,
        [switch]$NoVendorLookup,
        [switch]$NoPortDiscovery,
        # Do not look for a comparison host automatically when none is given.
        [switch]$NoAutoNeighbour,
        $Shared = $null
    )

    if ([string]::IsNullOrWhiteSpace($Target)) {
        throw 'Invoke-NtPathTriage needs a target. Probing an empty target would silently test the local machine and report a confident answer about the wrong host.'
    }

    # Profile supplies whatever the caller did not, so the tool can be run by
    # someone who knows nothing about the site (runbook tooling item C).
    if ($Profile) {
        if (-not $Peer) {
            $t = @($Profile.targets | Where-Object { $_.ip -eq $Target } | Select-Object -First 1)
            if ($t.Count -gt 0 -and $t[0].peer) { $Peer = [string]$t[0].peer }
        }
        if (@($Ports).Count -eq 0) {
            $t = @($Profile.targets | Where-Object { $_.ip -eq $Target } | Select-Object -First 1)
            if ($t.Count -gt 0 -and $t[0].ports) { $Ports = [int[]]@($t[0].ports) }
        }
    }
    if (@($Ports).Count -eq 0) { $Ports = @(443, 445, 3389, 4433, 4443, 4444, 80, 22) }

    $report = New-NtReport -Target $Target -Peer $Peer -Profile $Profile
    # Set by the per-stage guards below. Stop used to set a flag that this
    # orchestrator never read, so every rung ran to completion regardless.
    $ntCancelled = $false
    $sections = [System.Collections.Generic.List[object]]::new()
    $ladder   = [System.Collections.Generic.List[object]]::new()

    # ---- Rung 0: frame the problem ----------------------------------------
    if ($Shared) { $Shared.Status = 'Reading local configuration...' }
    $ctx = Get-NtLocalContext
    $vpn = Get-NtVpnIndicators

    $ctxRows = [System.Collections.Generic.List[object]]::new()
    foreach ($a in @($ctx.Adapters | Where-Object { $_.Status -eq 'Up' -and @($_.Addresses).Count -gt 0 })) {
        $ips = @($a.Addresses | ForEach-Object { '{0}/{1}' -f $_.IPAddress, $_.PrefixLength })
        $ctxRows.Add((New-NtRow -Group 'Endpoint' -Check $a.InterfaceAlias -Result ($ips -join ', ') -Status 'info' -Detail ('{0}, DHCP {1}, gateway {2}' -f $a.InterfaceDescription, $a.Dhcp, $a.DefaultGateway) -Data $a))
    }
    $vpnStatus = if ($vpn.Suspected) { 'warn' } else { 'ok' }
    $ctxRows.Add((New-NtRow -Group 'Endpoint' -Check 'Alternate paths' -Result $(if ($vpn.Suspected) { 'PRESENT' } else { 'None' }) -Status $vpnStatus -Detail $vpn.Detail -Data $vpn))

    $sections.Add((New-NtSection -Name 'Endpoint' -State 'measured' -Method 'Get-NetIPInterface, Get-NetIPAddress, Get-NetAdapter and Get-NetRoute, joined by interface index.' -Rows @($ctxRows) -Data $ctx))

    # The full interface list, including the disconnected ones the summary above
    # deliberately hides. The route binding analysis is read against this.
    $sections.Add((Get-NtInterfaceInventory -Context $ctx))
    $ladder.Add((New-NtRung -Number 0 -Name 'Frame the problem' -Status $(if ($vpn.Suspected) { 'warn' } else { 'ok' }) -Result $(if ($vpn.Suspected) { 'Alternate path present' } else { 'Single path' }) -Detail $vpn.Detail))

    # ---- Identify the device ----------------------------------------------
    # The target may be a name, an address or a MAC. Every source is asked
    # separately and the address to test is CHOSEN, not taken from whichever
    # source Windows happened to consult first. This used to be a bare
    # GetHostAddresses call, which on a PC running Tailscale returned the
    # overlay address from the hosts file for a device sitting on the same LAN.
    if ($Shared -and $Shared.Cancel) { $ntCancelled = $true }
    $identity = Get-NtDeviceIdentity -Target $Target -Context $ctx -Ports $Ports -NoVendorLookup:$NoVendorLookup -Shared $Shared
    $targetIp = [string]$identity.ChosenAddress
    $idResult = if ($identity.ChosenAddress) {
        ('{0} ({1})' -f $identity.ChosenAddress, $(if ($identity.Candidates.Count -gt 0) { (@($identity.Candidates[0].Sources) -join ', ') } else { $identity.Kind }))
    } elseif ($identity.NotFound) { 'Nothing answered for this device' } else { 'No address found' }
    $idStatus = if ($identity.ChosenAddress) { if ($identity.Disagreement -or $identity.NoLease) { 'warn' } else { 'ok' } } else { 'fail' }
    $ladder.Add((New-NtRung -Number 0 -Name 'Identify device' -Status $idStatus -Result $idResult -Detail $(if ($identity.ChosenBecause) { ('Chosen because {0}.' -f $identity.ChosenBecause) } else { '' })))
    $report.identity = $identity

    if (-not $targetIp) {
        # Nothing answered for the name, or nobody has seen the MAC: there is
        # no address to route to, trace or scan. Probing the bare name again
        # cost 15 seconds of resolver timeouts to reach the same answer, and
        # probing an empty target would test this PC instead. Report what the
        # identity step found - plus whether this PC's own network works,
        # which is the first question when nothing can be found - and stop.
        if (-not $SkipGateway) {
            if ($Shared) { $Shared.Status = 'Nothing found - checking this PC''s own gateway...' }
            $gwSection = Get-NtGatewaySection -Context $ctx -NoVendorLookup:$NoVendorLookup -Shared $Shared
            $sections.Add($gwSection)
            $gwAlive = ($gwSection.data.Icmp.Success) -or ($gwSection.data.Mac) -or (@($gwSection.data.OpenPorts).Count -gt 0)
            $ladder.Add((New-NtRung -Number 2 -Name 'Local gateway' -Status $(if ($gwAlive) { 'ok' } else { 'fail' }) -Result $(if ($gwAlive) { 'Gateway responding' } else { 'Gateway silent on every channel' }) -Detail 'If the gateway answers, this PC''s own network is working and the device itself is the question.'))
        }
        $device = Get-NtDeviceStatus -Identity $identity
        $report.device = $device
        $devSections = @(Get-NtDeviceSections -Identity $identity -Status $device)
        for ($i = $devSections.Count - 1; $i -ge 0; $i--) { $sections.Insert(0, $devSections[$i]) }
        $report.sections = [object[]]@($sections)
        $report.ladder   = [object[]]@($ladder)
        $report.runState = $(if ($ntCancelled -or ($Shared -and $Shared.Cancel)) { 'cancelled' } else { 'complete' })
        $report.findings = [object[]]@(Get-NtDeviceFindings -Identity $identity -Status $device)
        $report.verdict  = Get-NtVerdict -Report $report
        return $report
    }

    # ---- Rung 1: endpoint reality check -----------------------------------
    if ($Shared -and $Shared.Cancel) { $ntCancelled = $true }
    if ($Shared) { $Shared.Status = 'Auditing routes...' }
    $routeSection = Get-NtRouteAudit -Context $ctx
    $sections.Add($routeSection)

    $selected = Resolve-NtSelectedRoute -Destination $targetIp
    $selRows = [System.Collections.Generic.List[object]]::new()
    if ($selected.Resolved) {
        $selStatus = 'ok'
        $selDetail = $selected.Detail
        if ($selected.IsPersistent -and -not $selected.IsDefaultRoute) {
            $selStatus = 'warn'
            $selDetail += ' This is a PERSISTENT route, added by hand or by script rather than by DHCP.'
        }
        $selRows.Add((New-NtRow -Group 'Selected route' -Check ('Route to {0}' -f $targetIp) -Result ('{0} via {1} on {2}' -f $selected.RoutePrefix, $selected.NextHop, $selected.InterfaceAlias) -Status $selStatus -Detail $selDetail -Data $selected))
        if ($selected.SourceAddress) {
            $selRows.Add((New-NtRow -Group 'Selected route' -Check 'Source address' -Result $selected.SourceAddress -Status 'info' -Detail 'This is the source address the packet LEAVES this machine with. If anything between here and the target translates it, the far end needs a return route for the translated address, not for this one.'))
        }
        # Is the chosen next hop actually usable? This is Fault A.
        $nhReach = Resolve-NtNextHopReachability -NextHop $selected.NextHop
        $nhStatus = switch ($nhReach.Verdict) {
            'OnLink'            { 'ok' }
            'DirectlyReachable' { 'ok' }
            'ViaRoute'          { 'ok' }
            'InterfaceDown'     { 'fail' }
            'ChainBroken'       { 'fail' }
            'Unreachable'       { 'fail' }
            default             { 'warn' }
        }
        $selRows.Add((New-NtRow -Group 'Selected route' -Check 'Next hop reachable' -Result $nhReach.Verdict -Status $nhStatus -Detail $nhReach.Detail -Data $nhReach))
        $selected | Add-Member -NotePropertyName NextHopReachability -NotePropertyValue $nhReach -Force
    } else {
        $selRows.Add((New-NtRow -Group 'Selected route' -Check ('Route to {0}' -f $targetIp) -Result 'No route' -Status 'fail' -Detail $selected.Detail -Data $selected))
    }
    $sections.Add((New-NtSection -Name 'Selected route' -State 'measured' -Method 'Find-NetRoute, which reports the route Windows will actually choose and the source address it will use.' -Rows @($selRows) -Data $selected))

    $r1status = 'ok'; $r1result = 'Route selected'
    if (-not $selected.Resolved) { $r1status = 'fail'; $r1result = 'No route to target' }
    elseif ($selected.NextHopReachability -and $selected.NextHopReachability.Verdict -in @('InterfaceDown','ChainBroken','Unreachable')) {
        $r1status = 'fail'; $r1result = 'Selected route has an unusable next hop'
    }
    $ladder.Add((New-NtRung -Number 1 -Name 'Endpoint reality check' -Status $r1status -Result $r1result -Detail $selected.Detail))

    # ---- Names (hosts file, DNS override) ---------------------------------
    if ($Shared -and $Shared.Cancel) { $ntCancelled = $true }
    if ($Shared) { $Shared.Status = 'Checking hosts file and name resolution...' }
    # A MAC is not a name: resolve the address it was found at instead.
    $nameSection = Get-NtNameResolutionSection -Target $(if ($identity.Kind -eq 'MAC') { $targetIp } else { $Target }) -Context $ctx
    $sections.Add($nameSection)

    # ---- ARP --------------------------------------------------------------
    if ($Shared -and $Shared.Cancel) { $ntCancelled = $true }
    if ($Shared) { $Shared.Status = 'Reading ARP table...' }
    $arpSection = Get-NtArpAudit -Context $ctx -Target $targetIp -NoVendorLookup:$NoVendorLookup
    $sections.Add($arpSection)

    # ---- Rung 2: local gateway --------------------------------------------
    $gwSection = $null
    if (-not $SkipGateway) {
        if ($Shared -and $Shared.Cancel) { $ntCancelled = $true }
        if ($Shared) { $Shared.Status = 'Inventorying the gateway...' }
        $gwSection = Get-NtGatewaySection -Context $ctx -NoVendorLookup:$NoVendorLookup -Shared $Shared
        $sections.Add($gwSection)
        $gwAlive = ($gwSection.data.Icmp.Success) -or ($gwSection.data.Mac) -or (@($gwSection.data.OpenPorts).Count -gt 0)
        $ladder.Add((New-NtRung -Number 2 -Name 'Local gateway' -Status $(if ($gwAlive) { 'ok' } else { 'fail' }) -Result $(if ($gwAlive) { 'Gateway responding' } else { 'Gateway silent on every channel' }) -Detail 'ARP resolution, an open management port, or an ICMP reply are each sufficient proof of life. Only all three failing is a fault.'))
    } else {
        $ladder.Add((New-NtRung -Number 2 -Name 'Local gateway' -Status 'skipped' -Result 'Skipped by request'))
    }

    # ---- Rung 4: next hop / transport handoff -----------------------------
    # Rung 3 in the runbook is the firewall log, which cannot be read from here.
    # It is represented in the escalation summary instead.
    $nextHopIp = ''
    if ($Profile -and $Profile.transport -and $Profile.transport.nextHop) { $nextHopIp = [string]$Profile.transport.nextHop }
    $nextHopTest = $null
    if ($nextHopIp) {
        if ($Shared) { $Shared.Status = ('Testing transport next hop {0}...' -f $nextHopIp) }
        $nextHopTest = Test-NtIcmp -Target $nextHopIp -Count $PingCount -Shared $Shared
        $ladder.Add((New-NtRung -Number 4 -Name 'Transport handoff' -Status $(if ($nextHopTest.Success) { 'ok' } else { 'fail' }) -Result ('{0}: {1}' -f $nextHopIp, $(if ($nextHopTest.Success) { 'reachable' } else { 'no reply' })) -Detail $nextHopTest.Detail))
    } else {
        $ladder.Add((New-NtRung -Number 4 -Name 'Transport handoff' -Status 'skipped' -Result 'No transport next hop known' -Detail 'Supply one in the site profile (transport.nextHop) to test the handoff to the inter-site transport separately from the target itself.'))
    }

    # ---- Rung 5: peer on the destination subnet ---------------------------
    # The runbook calls this the single most valuable test in the whole ladder.
    $peerTest = $null
    $peerPorts = @()
    $peerRoute = $null
    # $null, not $true. "No peer was given" is not "the peer is on the right
    # subnet" - defaulting to true fed the confident branches below.
    $peerSameSubnet = $null
    $peerNetBasis = ''

    # No neighbour given: find one. The technician should not have to know
    # what a comparison host is, let alone supply one - the first user of this
    # tool asked exactly that. Given explicitly, it is used as-is.
    $neighbour = [pscustomobject]@{ Peer = $Peer; How = $(if ($Peer) { 'given' } else { 'none' }); Detail = ''; Prefix = ''; AssumedPrefix = $false; Candidates = @(); Responders = @(); Tried = 0 }
    if (-not $Peer -and -not $NoAutoNeighbour -and (Test-NtIsIPv4 $targetIp)) {
        if ($Shared -and $Shared.Cancel) { $ntCancelled = $true }
        $neighbour = Find-NtNeighbour -TargetIp $targetIp -DestinationCidr $DestinationCidr -Profile $Profile -Context $ctx -Ports $Ports -Shared $Shared
        if ($neighbour.Peer) { $Peer = [string]$neighbour.Peer }
    }
    $report.neighbour = $neighbour
    $report.peer = $Peer

    if ($Peer) {
        # The entire "transport is proven, the fault is one host" inference
        # rests on the peer being on the DESTINATION subnet, so it is measured
        # against an explicit prefix when one is known and reported as UNKNOWN
        # when it is not. Resolve the peer first: it may be a hostname, and
        # splitting a hostname on '.' compared DNS labels as though they were
        # octets.
        $peerIp = $Peer
        if (-not (Test-NtIsIPv4 $Peer)) {
            try {
                $pr = @([System.Net.Dns]::GetHostAddresses($Peer) |
                        Where-Object { $_.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork })
                if ($pr.Count -gt 0) { $peerIp = $pr[0].ToString() }
            } catch { }
        }
        $sameNet = Test-NtSameNetwork -AddressA $peerIp -AddressB $targetIp -Cidr $DestinationCidr
        $peerSameSubnet = $sameNet.Same
        $peerNetBasis = $sameNet.Basis

        if ($Shared -and $Shared.Cancel) { $ntCancelled = $true }
        if ($Shared) { $Shared.Status = ('Testing peer host {0}...' -f $Peer) }
        $peerTest = Test-NtIcmp -Target $Peer -Count $PingCount -Shared $Shared

        # The peer must be tested the SAME way as the target or the comparison
        # is not a comparison. ICMP alone is the weaker half: Windows blocks
        # inbound echo by default, so a peer that serves the application port
        # perfectly well can look dead, and the engine would then conclude the
        # whole destination subnet was unreachable.
        $peerPorts = Get-NtPortScan -Target $Peer -Ports $Ports -TimeoutMs 1200 -Shared $Shared
        $peerRoute = Resolve-NtSelectedRoute -Destination $Peer
        $peerAlive = ($peerTest.Success) -or (@($peerPorts).Count -gt 0)
        $peerHow = if ($peerTest.Success -and @($peerPorts).Count -gt 0) {
            ('ICMP and TCP {0}' -f ((@($peerPorts) | ForEach-Object { $_.Port }) -join ','))
        } elseif (@($peerPorts).Count -gt 0) {
            ('TCP {0} only - it does not answer ICMP' -f ((@($peerPorts) | ForEach-Object { $_.Port }) -join ','))
        } elseif ($peerTest.Success) {
            'ICMP only - no probed port answered'
        } else { 'no reply on ICMP or any probed port' }

        # Three states. $null means the mask is unknown, which is neither
        # "same subnet" nor "different subnet" - and reporting it as either
        # would be the assumption this fix exists to remove.
        $peerDetail = ('Reached by {0}. {1}' -f $peerHow, $peerTest.Detail)
        if ($peerSameSubnet -eq $false) {
            $peerDetail += (' WARNING: {0} is not in the stated destination network, so it cannot prove anything about the target subnet. Choose a peer that shares it.' -f $Peer)
        } elseif ($null -eq $peerSameSubnet) {
            $peerDetail += (' NOTE: {0} Supply the destination network (for example 10.50.40.0/23) to turn this comparison into a control test rather than an assumption.' -f $peerNetBasis)
        } else {
            $peerDetail += (' {0}' -f $peerNetBasis)
        }
        if ($neighbour.How -in @('profile', 'inventory', 'probe')) {
            $peerDetail = ('{0} {1}' -f $neighbour.Detail, $peerDetail)
        }
        $rung5 = if (-not $peerAlive) { 'fail' } elseif ($peerSameSubnet -eq $true) { 'ok' } else { 'warn' }
        $howTag = if ($neighbour.How -in @('inventory', 'probe', 'profile')) { (' (found automatically: {0})' -f $neighbour.How) } else { '' }
        $ladder.Add((New-NtRung -Number 5 -Name 'Neighbour on target''s network' -Status $rung5 -Result ('{0}: {1}{2}' -f $Peer, $(if ($peerAlive) { 'reachable' } else { 'no reply' }), $howTag) -Detail $peerDetail))
    } elseif ($neighbour.How -eq 'not-needed') {
        $ladder.Add((New-NtRung -Number 5 -Name 'Neighbour on target''s network' -Status 'skipped' -Result 'Not needed - target is on this subnet' -Detail $neighbour.Detail))
    } elseif ($neighbour.Tried -gt 0) {
        $ladder.Add((New-NtRung -Number 5 -Name 'Neighbour on target''s network' -Status 'info' -Result ('None found ({0} addresses tried)' -f $neighbour.Tried) -Detail $neighbour.Detail))
    } else {
        $ladder.Add((New-NtRung -Number 5 -Name 'Neighbour on target''s network' -Status 'skipped' -Result 'No neighbour' -Detail $(if ($neighbour.Detail) { $neighbour.Detail } else { 'Automatic search was turned off or not possible, and none was given. A second host on the target''s network separates "the path is broken" from "one host has a problem".' })))
    }

    # ---- Rung 6: the target -----------------------------------------------
    if ($Shared -and $Shared.Cancel) { $ntCancelled = $true }
    if ($Shared) { $Shared.Status = ('Testing target {0}...' -f $targetIp) }
    $targetIcmp = Test-NtIcmp -Target $targetIp -Count $PingCount -Shared $Shared
    $targetPorts = Get-NtPortScan -Target $targetIp -Ports $Ports -TimeoutMs 1200 -Banners -Shared $Shared

    # If none of the requested ports answered, find out what the host IS
    # listening on rather than telling the operator to go and run netstat on it.
    # "Nothing on the ports you asked for" is a dead end; "nothing on those, but
    # it serves HTTP on 80" is an answer. Costs about a second now that the scan
    # runs in parallel, so it is worth doing unconditionally.
    $discovered = @()
    if (-not $NoPortDiscovery -and @($targetPorts).Count -eq 0) {
        $wider = @(@(Get-NtCommonPortList) + @(Get-NtGatewayPortList) | Sort-Object -Unique | Where-Object { @($Ports) -notcontains [int]$_ })
        if ($wider.Count -gt 0) {
            if ($Shared) { $Shared.Status = ('Nothing on the requested ports - checking {0} common ports on {1}...' -f $wider.Count, $targetIp) }
            $discovered = Get-NtPortScan -Target $targetIp -Ports $wider -TimeoutMs 1000 -Banners -Shared $Shared
        }
    }

    $tRows = [System.Collections.Generic.List[object]]::new()
    $tRows.Add((New-NtRow -Group 'Target' -Check ('ICMP to {0}' -f $targetIp) -Result $(if ($targetIcmp.Success) { ('{0}/{1} replies, {2} ms avg' -f $targetIcmp.Received, $targetIcmp.Sent, [math]::Round($targetIcmp.Rtt.Mean,1)) } else { 'No reply' }) -Status $(if ($targetIcmp.Success) { 'ok' } else { 'fail' }) -Detail $targetIcmp.Detail -Data $targetIcmp))
    foreach ($p in @($Ports)) {
        $hit = @(@($targetPorts) | Where-Object { $_.Port -eq [int]$p })
        if ($hit.Count -gt 0) {
            $tRows.Add((New-NtRow -Group 'Target' -Check ('{0}/tcp' -f $p) -Result $(if ($hit[0].Banner) { $hit[0].Banner } else { 'open' }) -Status 'ok' -Detail 'The service accepted a TCP connection, which proves a full round trip including a working return path.' -Data $hit[0]))
        } else {
            # The socket layer usually knows WHY, and it used to be discarded.
            # A refusal and a timeout point in opposite directions: the first
            # says a device is there and answered, the second says nothing
            # came back at all.
            $oc = $null
            if ($script:NtLastPortOutcomes -and $script:NtLastPortOutcomes.ContainsKey([int]$p)) { $oc = $script:NtLastPortOutcomes[[int]$p] }
            $res = 'closed or filtered'
            $det = 'No TCP handshake. A connect scan cannot tell a closed port from a filtered one.'
            if ($oc) {
                switch ([string]$oc.Outcome) {
                    'refused'     { $res = 'refused'; $det = ('Actively refused after {0} ms. Something sent a reset, so the packet REACHED a device that answered - this is not filtering and not a path problem. Usually nothing is listening on that port; an intermediary can also reset on the host''s behalf.' -f $oc.ElapsedMs) }
                    'timeout'     { $res = 'no response'; $det = ('Nothing came back within the timeout ({0} ms). Filtering, a path failure, or a host that is not there - a connect scan cannot separate those.' -f $oc.ElapsedMs) }
                    'unreachable' { $res = 'unreachable'; $det = ('The network reported {0} after {1} ms. That is a routing answer, not a service one.' -f $oc.SocketError, $oc.ElapsedMs) }
                    'error'       { $res = 'probe failed'; $det = ('The probe itself failed ({0}) - this says nothing about the target.' -f $oc.SocketError) }
                    default       { $res = 'closed or filtered' }
                }
            }
            $st = if ($res -eq 'probe failed') { 'info' } else { 'fail' }
            $tRows.Add((New-NtRow -Group 'Target' -Check ('{0}/tcp' -f $p) -Result $res -Status $st -Detail $det -Data $oc))
        }
    }
    foreach ($p in @($discovered)) {
        $tRows.Add((New-NtRow -Group 'Target' -Check ('{0}/tcp {1}' -f $p.Port, $p.Service) -Result $(if ($p.Banner) { $p.Banner } else { 'open' }) -Status 'info' -Detail 'Found by the wider sweep: this port was NOT in the list you asked for, but the host is serving it. That is what it is actually listening on.' -Data $p))
    }

    $openCount = @($targetPorts).Count
    $method = ('ICMP echo plus a TCP connect scan of {0} application port(s).' -f @($Ports).Count)
    if (@($discovered).Count -gt 0 -or ($openCount -eq 0 -and -not $NoPortDiscovery)) {
        $method += ' None of those answered, so a wider sweep of common service and management ports followed.'
    }
    $sections.Add((New-NtSection -Name 'Target' -State 'measured' -Method $method -Rows @($tRows) -Data ([pscustomobject]@{
        Target          = $targetIp
        Icmp            = $targetIcmp
        OpenPorts       = [object[]]@($targetPorts)
        DiscoveredPorts = [object[]]@($discovered)
        Probed          = [int[]]@($Ports)
    })))

    $r6status = 'fail'; $r6result = 'Unreachable on ICMP and every probed port'
    if ($targetIcmp.Success -and $openCount -gt 0) { $r6status = 'ok'; $r6result = 'Reachable' }
    elseif ($openCount -gt 0) { $r6status = 'warn'; $r6result = 'Ports open, ICMP filtered' }
    elseif ($targetIcmp.Success) { $r6status = 'warn'; $r6result = 'Pings, but no probed port is open' }
    $ladder.Add((New-NtRung -Number 6 -Name 'Target host' -Status $r6status -Result $r6result))

    # The device card, now that the chosen address has been probed properly.
    # It opens the report: "is it there, and what is it" comes before "why".
    $device = Get-NtDeviceStatus -Identity $identity -TargetIcmp $targetIcmp -TargetPorts @($targetPorts) -Discovered @($discovered)
    $report.device = $device
    $devSections = @(Get-NtDeviceSections -Identity $identity -Status $device -Neighbour $neighbour)
    for ($i = $devSections.Count - 1; $i -ge 0; $i--) { $sections.Insert(0, $devSections[$i]) }

    # ---- Target vs peer, dimension by dimension ---------------------------
    # "One host works, its neighbour does not" is only useful if both were asked
    # the same questions. Laid out side by side, the rows that MATCH are the
    # valuable ones: identical route and identical source address rule the
    # workstation out as the difference between the two hosts.
    $diffSection = $null
    $routeSame = $false
    $sourceSame = $false
    if ($Peer -and $peerRoute) {
        $dRows = [System.Collections.Generic.List[object]]::new()

        $mkCmp = {
            param([string]$Dimension, [string]$TargetValue, [string]$PeerValue, [string]$SameDetail, [string]$DiffDetail)
            $same = ($TargetValue -eq $PeerValue)
            $dRows.Add((New-NtRow -Group 'Target vs peer' -Check $Dimension -Result ('target: {0}  |  peer: {1}' -f $(if ($TargetValue) { $TargetValue } else { '(none)' }), $(if ($PeerValue) { $PeerValue } else { '(none)' })) -Status $(if ($same) { 'ok' } else { 'warn' }) -Detail $(if ($same) { $SameDetail } else { $DiffDetail })))
            return $same
        }

        $routeSame = & $mkCmp 'Selected route' ([string]$selected.RoutePrefix) ([string]$peerRoute.RoutePrefix) `
            'Windows picks the same route for both, so it is not steering them differently.' `
            'Windows picks a DIFFERENT route for each. That difference is on this workstation and is the first thing to explain.'

        $nhSame = & $mkCmp 'Next hop' ([string]$selected.NextHop) ([string]$peerRoute.NextHop) `
            'Both leave via the same next hop.' `
            'They leave via different next hops - the divergence starts here, on this machine.'

        $sourceSame = & $mkCmp 'Source address' ([string]$selected.SourceAddress) ([string]$peerRoute.SourceAddress) `
            'Both are sourced from the same address, so the far end sees the same client for each - before any translation along the path.' `
            'They are sourced from DIFFERENT addresses, so the far end sees a different client for each. That alone can explain why one is answered and the other is not.'

        $ifSame = & $mkCmp 'Interface' ([string]$selected.InterfaceAlias) ([string]$peerRoute.InterfaceAlias) `
            'Both leave by the same interface.' 'They leave by different interfaces.'

        $dRows.Add((New-NtRow -Group 'Target vs peer' -Check 'ICMP' -Result ('target: {0}  |  peer: {1}' -f $(if ($targetIcmp.Success) { 'reply' } else { 'no reply' }), $(if ($peerTest.Success) { 'reply' } else { 'no reply' })) -Status $(if ($targetIcmp.Success -eq $peerTest.Success) { 'ok' } else { 'warn' }) -Detail 'ICMP may be filtered independently of the application, so a difference here is weaker evidence than a difference in TCP.'))

        foreach ($p in @($Ports)) {
            $tOpen = (@(@($targetPorts) | Where-Object { $_.Port -eq [int]$p }).Count -gt 0)
            $pOpen = (@(@($peerPorts)   | Where-Object { $_.Port -eq [int]$p }).Count -gt 0)
            $detail = if ($tOpen -eq $pOpen) {
                'Both behave the same on this port.'
            } elseif ($pOpen) {
                'The peer accepts this port and the target does not, over the same route and from the same source. A completed handshake to the peer proves the forward path AND a working return path for that subnet, so the difference is at the target itself.'
            } else {
                'The target accepts this port and the peer does not - the peer may simply not run this service, which weakens it as a control.'
            }
            $dRows.Add((New-NtRow -Group 'Target vs peer' -Check ('TCP {0}' -f $p) -Result ('target: {0}  |  peer: {1}' -f $(if ($tOpen) { 'open' } else { 'no' }), $(if ($pOpen) { 'open' } else { 'no' })) -Status $(if ($tOpen -eq $pOpen) { 'ok' } else { 'warn' }) -Detail $detail))
        }

        $diffSection = New-NtSection -Name 'Target vs peer' -State 'measured' -Method 'The peer is probed with the same port list and route resolution as the target, so the two are directly comparable.' -Rows @($dRows) -Data ([pscustomobject]@{
            Peer            = $Peer
            PeerRoute       = $peerRoute
            PeerIcmp        = $peerTest
            PeerOpenPorts   = [object[]]@($peerPorts)
            RouteSame       = $routeSame
            NextHopSame     = $nhSame
            SourceSame      = $sourceSame
            InterfaceSame   = $ifSame
        }) -Caveats @(
            'Only the target is traced hop by hop, to keep the run short. If the routes above differ, trace the peer as well.'
        )
        $sections.Add($diffSection)
    }

    # ---- Traceroute -------------------------------------------------------
    $trace = $null
    if (-not $SkipTrace) {
        if ($Shared -and $Shared.Cancel) { $ntCancelled = $true }
        if ($Shared) { $Shared.Status = ('Tracing path to {0}...' -f $targetIp) }
        $trace = Invoke-NtTraceroute -Target $targetIp -MaxHops $MaxHops -ProbesPerHop 2 -ResolveNames -Shared $Shared
        $trRows = [System.Collections.Generic.List[object]]::new()
        foreach ($h in @($trace.Hops)) {
            $addr = if ($h.Address) { $h.Address } else { '*' }
            $label = $addr
            if ($h.Name) { $label = ('{0} ({1})' -f $addr, $h.Name) }
            $res = if ($h.Replies -gt 0) { ('{0} ms' -f $h.AvgMs) } else { 'no reply' }
            $st = if ($h.Replies -gt 0) { 'ok' } else { 'info' }
            $trRows.Add((New-NtRow -Group 'Path' -Check ('Hop {0}' -f $h.Hop) -Result ('{0} - {1}' -f $label, $res) -Status $st -Detail $h.Note -Data $h))
        }
        $sections.Add((New-NtSection -Name 'Path' -State 'measured' -Method 'ICMP echo with an increasing TTL, two probes per hop.' -Rows @($trRows) -Data $trace -Caveats @(
            'A silent hop is not a fault - many routers do not answer TTL expiry.',
            'Only the final hop TTL is a usable OS or hop-count fingerprint; intermediate replies are generated by the router itself.'
        )))
    }

    # ---- Rung 7: source address / translation -----------------------------
    $ladder.Add((New-NtRung -Number 7 -Name 'Source address seen by the far end' -Status 'info' -Result $(if ($selected.SourceAddress) { $selected.SourceAddress } else { 'unknown' }) -Detail 'This is the source address as it leaves THIS machine. Source NAT anywhere along the path cannot be observed from here - it has to be confirmed on the firewall.'))

    $report.sections = [object[]]@($sections)
    $report.ladder   = [object[]]@($ladder)

    # ---- Conclusions ------------------------------------------------------
    if ($Shared) { $Shared.Status = 'Drawing conclusions...' }
    $evidence = [pscustomobject]@{
        Context      = $ctx
        Vpn          = $vpn
        Target       = $Target
        TargetIp     = $targetIp
        Peer         = $Peer
        Profile      = $Profile
        Selected     = $selected
        RouteSection = $routeSection
        NameSection  = $nameSection
        ArpSection   = $arpSection
        GwSection    = $gwSection
        NextHopTest  = $nextHopTest
        PeerTest     = $peerTest
        PeerSameNet  = $peerSameSubnet
        PeerPorts    = [object[]]@($peerPorts)
        PeerRoute    = $peerRoute
        DiffSection  = $diffSection
        TargetIcmp   = $targetIcmp
        TargetPorts  = [object[]]@($targetPorts)
        Discovered   = [object[]]@($discovered)
        PortsProbed  = [int[]]@($Ports)
        Trace        = $trace
        Ladder       = [object[]]@($ladder)
        Identity     = $identity
        Device       = $device
        Neighbour    = $neighbour
    }
    # A CANCELLED RUN IS NOT A COMPLETED ONE.
    #
    # This orchestrator had no cancel checks at all, so Stop set a flag and
    # every rung ran to completion anyway - and the sub-probes made that
    # actively dangerous rather than merely slow. Test-NtIcmp breaks out of
    # its loop on cancel and returns Received = 0, which is Success = $false,
    # which is indistinguishable from "the host did not answer". So a
    # cancelled triage produced a full report of false negatives, and the GUI
    # announced "Triage complete."
    #
    # Conclusions are drawn only from a complete run. A partial one keeps every
    # observation it did gather - those are real - and states plainly that the
    # analysis was not performed.
    $wasCancelled = [bool]($ntCancelled -or ($Shared -and $Shared.Cancel))
    $report.runState = $(if ($wasCancelled) { 'cancelled' } else { 'complete' })
    if ($wasCancelled) {
        $report.findings = [object[]]@(
            New-NtFinding -Title 'This run was stopped before it finished - no conclusions were drawn' `
                -Severity 'info' -Confidence 'confirmed' `
                -Summary 'The checks below are whatever completed before Stop was pressed. No analysis was performed on them, because the probes that did not run return "no reply", which is indistinguishable from a genuine failure - reading conclusions off a partial run is how an untested host becomes a diagnosed one.' `
                -Evidence @('Ladder') `
                -Assumptions @('Any check showing no response may simply never have been sent.') `
                -Action 'Re-run without stopping to get an assessment.'
        )
        $report.verdict = [pscustomobject]@{
            Headline = 'Stopped before finishing - partial evidence, no assessment'
            Detail   = 'Rungs that did not run are absent, not failed.'
            Status   = 'cancelled'
        }
        return $report
    }
    $report.findings = [object[]]@(Get-NtConclusions -Evidence $evidence)
    $report.verdict  = Get-NtVerdict -Report $report
    return $report
}

# =============================================================================
# 12. Conclusion engine
# =============================================================================
# The reason this toolkit exists. Collecting evidence is easy; the hours in the
# original case went on drawing the wrong inference from evidence that was
# already on screen.
#
# Rules here are ordered so the most specific fires first, and each one states
# the evidence it rests on so the reader can disagree with it.
#
# One thing this engine will NOT do: claim to have seen source NAT. It cannot.
# Nothing on an endpoint can observe a translation performed downstream. Where
# the evidence pattern points that way it says so explicitly and hands over the
# firewall-side commands that WOULD show it.

function Get-NtConclusions {
    param($Evidence)

    $f = [System.Collections.Generic.List[object]]::new()
    $ev = $Evidence

    $targetLabel = if ($ev.Target -and $ev.Target -ne $ev.TargetIp) { ('{0} ({1})' -f $ev.Target, $ev.TargetIp) } else { [string]$ev.TargetIp }
    if ($ev.Identity -and $ev.Identity.Kind -eq 'MAC') { $targetLabel = ('{0} ({1})' -f $ev.Identity.MacTarget.MacFormatted, $ev.TargetIp) }
    # Three separate questions, which used to be one.
    #
    #   endpointResponded - did ANYTHING come back? A completed handshake on a
    #                       DISCOVERED port proves the host is up and the
    #                       return path works, even though the requested
    #                       service failed. This omitted $ev.Discovered, so a
    #                       host proven alive by discovery was still labelled
    #                       unreachable and fed into the "whole subnet is
    #                       unreachable" branch.
    #   requestedOk       - did the service the technician actually asked
    #                       about answer?
    #   $targetReachable  - kept as "the endpoint responded", because that is
    #                       what the branches below mean by it.
    $discoveredOpen = @($ev.Discovered).Count
    $requestedOk    = (@($ev.TargetPorts).Count -gt 0)
    $endpointResponded = ($ev.TargetIcmp.Success) -or $requestedOk -or ($discoveredOpen -gt 0)
    $targetReachable = $endpointResponded
    # A peer counts as reachable on EITHER signal. Requiring ICMP would call a
    # perfectly healthy Windows peer dead and then conclude the whole subnet was
    # unreachable - a critical-severity false positive from a default firewall.
    $peerPortsOpen = @($ev.PeerPorts).Count
    $peerReachable = ($ev.PeerTest -and $ev.PeerTest.Success) -or ($peerPortsOpen -gt 0)
    $peerTested = ($null -ne $ev.PeerTest)
    $peerProof = if ($ev.PeerTest -and $ev.PeerTest.Success -and $peerPortsOpen -gt 0) { 'ICMP and TCP' }
                 elseif ($peerPortsOpen -gt 0) { 'TCP' }
                 elseif ($ev.PeerTest -and $ev.PeerTest.Success) { 'ICMP' }
                 else { '' }
    $portsOpen = @($ev.TargetPorts).Count

    # --- 0. The device itself ---------------------------------------------
    # No lease, a name that points elsewhere, not found, moved. These come
    # first because they change what every later finding means: a device on
    # 169.254 has no path problem to find.
    foreach ($df in @(Get-NtDeviceFindings -Identity $ev.Identity -Status $ev.Device -TargetReachable $targetReachable)) { $f.Add($df) }
    # A name-vs-device disagreement caused by the hosts file is reported there,
    # with the line and who wrote it; the generic hosts findings below would
    # say the same thing twice.
    $hostsCoveredByDevice = [bool]($ev.Identity -and $ev.Identity.Disagreement -and $ev.Identity.NameAnswers -and
        (@(@($ev.Identity.NameAnswers.Answers) | Where-Object { [string]$_.Source -like 'hosts file*' }).Count -gt 0))

    # --- 1. Confounding variable: an alternate path is live -----------------
    if ($ev.Vpn.Suspected) {
        # Three different situations, which used to share one high-severity
        # banner that outranked every real finding beneath it.
        # Does the route Windows chose for THIS target go through one of them?
        # An on-link device reached over Wi-Fi while Tailscale idles alongside
        # is not a second-path problem, and a high banner saying it is buried
        # the actual answer about the device.
        $selAlias = if ($ev.Selected -and $ev.Selected.Resolved) { [string]$ev.Selected.InterfaceAlias } else { '' }
        $selViaVpn = $true
        if ($selAlias) {
            $selViaVpn = (@(@($ev.Vpn.Adapters) | Where-Object { ([string]$_).StartsWith($selAlias + ' (') }).Count -gt 0)
        }
        $selOnLink = [bool]($ev.Selected -and $ev.Selected.Resolved -and ([string]$ev.Selected.NextHop -in @('0.0.0.0', '')))
        if ($selAlias -and -not $selViaVpn) {
            $f.Add((New-NtFinding -Title ('A VPN or overlay adapter is up, but traffic to this target leaves by {0}' -f $selAlias) `
                -Severity 'low' -Confidence 'confirmed' -Summary $ev.Vpn.Detail `
                -Evidence @('Endpoint / Alternate paths', 'Selected route') `
                -Basis @(('Adapters up and matching a VPN or overlay: {0}' -f (@($ev.Vpn.Adapters) -join '; ')), ('Windows selected {0} via {1} on {2} for this target.' -f $ev.Selected.RoutePrefix, $ev.Selected.NextHop, $selAlias)) `
                -Assumptions @('The route was read once. A VPN that connects or pushes routes later can change it, and name resolution can still hand out an overlay address - see the Device section.') `
                -Action $(if ($selOnLink) { 'No action for this target: it is on this subnet and reached directly.' } else { 'Keep it in mind if results change between runs. The selected route is the authority for where this traffic goes.' })))
        }
        elseif ($ev.Vpn.Suspected) {
            # A VPN or overlay adapter really is up. This is the case the
            # warning was written for.
            #
            # The action deliberately does NOT say "disconnect it and re-run".
            # This tool is run through ScreenConnect Backstage, and the link
            # being suggested for disconnection may be carrying the session
            # issuing the suggestion.
            $f.Add((New-NtFinding -Title 'A VPN or overlay adapter is up - treat every result below as provisional' `
                -Severity 'high' -Confidence 'confirmed' -Summary $ev.Vpn.Detail `
                -Evidence @('Endpoint / Alternate paths') `
                -Basis @(('Adapters up and matching a VPN or overlay: {0}' -f ((@($ev.Vpn.Adapters) -join '; ')))) `
                -Assumptions @('Identified by adapter name and description. A client this tool does not recognise would not appear here, so this can miss one.') `
                -Action 'Re-test with the overlay down if you can, because a success over a second path proves nothing about the path you are fixing. CHECK FIRST whether your own remote session runs over it - in Backstage, disconnecting the wrong adapter ends the session.'))
        }
        elseif ($ev.Vpn.MultipleDefaults -and -not $ev.Vpn.DefaultsShareNextHop) {
            # Genuinely two ways off this machine, and worth knowing - but it
            # is a fact about the endpoint, not a reason to disbelieve the run.
            $f.Add((New-NtFinding -Title 'This machine has two default routes via different next hops' `
                -Severity 'medium' -Confidence 'confirmed' -Summary $ev.Vpn.Detail `
                -Evidence @('Endpoint / Alternate paths') `
                -Basis @('More than one default route, with more than one distinct next hop.') `
                -Action 'Confirm which one this target actually uses - the selected route below is the authority, not the route list. If it is not the one you expect, that is the finding.'))
        }
        elseif ($ev.Vpn.MultipleDefaults) {
            # Ethernet and Wi-Fi both up, both pointing at the same gateway.
            # Ordinary on any laptop, and previously reported at HIGH severity
            # as "an alternate path is live" - which is what both of the
            # supplied printer captures did.
            $f.Add((New-NtFinding -Title 'Two default routes, both via the same gateway' `
                -Severity 'info' -Confidence 'confirmed' -Summary $ev.Vpn.Detail `
                -Evidence @('Endpoint / Alternate paths') `
                -Basis @('Every default route resolves to the same next hop.') `
                -Action 'No action. Recorded so it is not mistaken for a second path off-site - a dual-homed machine reaching one gateway two ways is normal.'))
        }
    }

    # --- 2. Fault A: the selected route depends on an unusable next hop -----
    $sel = $ev.Selected
    if ($sel -and $sel.Resolved -and $sel.NextHopReachability) {
        $nh = $sel.NextHopReachability
        if ($nh.Verdict -in @('ChainBroken','Unreachable','InterfaceDown','ViaDefaultGateway')) {
            $isPrivateNh = Test-NtIsPrivateAddress $sel.NextHop
            $reallyBad = ($nh.Verdict -in @('ChainBroken','Unreachable','InterfaceDown')) -or ($nh.Verdict -eq 'ViaDefaultGateway' -and $isPrivateNh -and -not $sel.IsDefaultRoute)

            if ($reallyBad -and -not $sel.IsDefaultRoute) {
                $sev = 'critical'
                $title = ('Traffic to {0} is steered by a static route whose next hop is not reachable' -f $targetLabel)
                $summary = ('Windows selects {0} via {1}, but {1} is not usable from here: {2}' -f $sel.RoutePrefix, $sel.NextHop, $nh.Detail)
                if ($sel.IsPersistent) {
                    $summary += ' The route is PERSISTENT, so it survives reboots and rebuilds and will keep breaking this destination until it is removed.'
                }
                if ($nh.Verdict -eq 'InterfaceDown') {
                    $summary += ' This is the exact signature of the "it only works when the user connects to VPN" symptom: the next hop is only on-link while that interface is up.'
                }
                $cmds = [System.Collections.Generic.List[string]]::new()
                $cmds.Add((ConvertTo-NtRouteDeleteCommand -DestinationPrefix $sel.RoutePrefix -NextHop $sel.NextHop))
                $cmds.Add('route print -4')
                $f.Add((New-NtFinding -Title $title -Severity $sev -Confidence 'confirmed' -Summary $summary -Evidence @('Selected route / Next hop reachable', 'Route audit') -Action 'Remove the route and re-test. Then find out how it got there - if it was pushed by script or GPO, every other machine at this site is carrying it too.' -Commands @($cmds)))
            }
        }
    }
    if ($sel -and -not $sel.Resolved) {
        # A target that never resolved to an address was reaching this branch
        # and being reported as "Windows has no route at all for this
        # destination" - critical, confirmed. A name-resolution failure
        # presented as a routing fault sends a technician to the route table
        # to look for something that was never the problem.
        if ($sel.Reason -eq 'not-an-ipv4-address') {
            $f.Add((New-NtFinding -Title ('{0} could not be resolved to an address' -f $targetLabel) `
                -Severity 'high' -Confidence 'confirmed' `
                -Summary ('No route lookup was performed, because there was no address to look up. {0} This is a NAME RESOLUTION problem; the route table has not been implicated and should not be changed on the strength of it.' -f $sel.Detail) `
                -Evidence @('Selected route', 'Name resolution') `
                -Basis @('The target did not resolve to an IPv4 address.') `
                -Action 'Fix name resolution first, or re-run against the literal IP address. If the IP works and the name does not, the fault is DNS, the hosts file, or an NRPT rule - see the name resolution section.'))
        } else {
            $f.Add((New-NtFinding -Title ('No route to {0}' -f $targetLabel) `
                -Severity 'critical' -Confidence 'confirmed' `
                -Summary 'Windows has no route at all for this destination, not even a default route.' `
                -Evidence @('Selected route') `
                -Basis @('A route lookup was performed for this address and returned nothing.') `
                -Action 'Check that the adapter has a gateway and that the interface is up.'))
        }
    }

    # --- 3a. ACTIVE routes with an unusable next hop -----------------------
    # These are in the forwarding table, so they are steering traffic now.
    $activeBad = @()
    $persistOnlyBad = @()
    if ($ev.RouteSection -and $ev.RouteSection.data) {
        $activeBad = @(@($ev.RouteSection.data.Routes) | Where-Object { $_.InActiveTable -and $_.Status -eq 'fail' })
        $persistOnlyBad = @($ev.RouteSection.data.PersistentOnlyBad)
    }
    # Routes with their own, more specific finding below are excluded here.
    # Listing a DHCP-supplied route under "delete them" would directly
    # contradict the DHCP finding, which says not to.
    $otherBad = @($activeBad | Where-Object {
        (-not ($sel -and $_.DestinationPrefix -eq $sel.RoutePrefix)) -and
        ($_.BindingFlag -notin @('DhcpSupplied', 'MisboundNextHop'))
    })
    if ($otherBad.Count -gt 0) {
        $persistCount = @($otherBad | Where-Object { $_.Persistent }).Count
        $lines = @($otherBad | ForEach-Object { '{0} via {1}' -f $_.DestinationPrefix, $_.NextHop })
        $cmds = @($otherBad | Where-Object { $_.DeleteCommand } | ForEach-Object { $_.DeleteCommand })
        $routeWord = if ($otherBad.Count -eq 1) { 'route in the active forwarding table points' } else { 'routes in the active forwarding table point' }
        $summary = ('{0} other {1} at a next hop that is not reachable: {2}. These are installed, so they are steering traffic now.' -f $otherBad.Count, $routeWord, ($lines -join '; '))
        if ($persistCount -gt 0) {
            $persistWord = if ($persistCount -eq 1) { 'One of them is also persistent and will' } else { ('{0} of them are also persistent and will' -f $persistCount) }
            $summary += (' {0} survive a rebuild.' -f $persistWord)
        }
        $f.Add((New-NtFinding -Title 'Active static routes point at an unreachable next hop' -Severity 'high' -Confidence 'confirmed' -Summary $summary -Evidence @('Route audit') -Action 'Delete them and establish where they came from. Routes like these are usually pushed by a login script or GPO, which means the rest of the fleet has them too.' -Commands @($cmds)))
    }

    # --- 3b. Configured but NOT installed ----------------------------------
    # The distinction that matters most in this whole engine. A route sitting in
    # the persistent store that Windows has not installed is not carrying any
    # traffic, so it cannot be the cause of a fault happening now - however bad
    # its next hop looks. Reporting it as a live failure is how an investigation
    # ends up chasing configuration residue while the real fault sits elsewhere.
    if ($persistOnlyBad.Count -gt 0) {
        # The binding tells us which of these can ever matter, so say so per
        # route instead of sending the reader off to do an A/B capture for all
        # of them.
        $willActivate = @($persistOnlyBad | Where-Object { $_.BindingFlag -eq 'BoundToDisconnected' })
        $orphaned     = @($persistOnlyBad | Where-Object { $_.BindingFlag -eq 'OrphanedInterface' })

        $lines = @($persistOnlyBad | ForEach-Object {
            # $_ inside a switch refers to the switch's own subject, not the
            # pipeline item, so the route has to be captured first.
            $route = $_
            $suffix = switch ([string]$route.BindingFlag) {
                'BoundToDisconnected' { ' (bound to "{0}", {1} - will install when it connects)' -f $route.InterfaceAlias, $route.InterfaceKind }
                'OrphanedInterface'   { ' (bound to a missing interface - can never install)' }
                default               { '' }
            }
            ('{0} via {1}{2}' -f $route.DestinationPrefix, $route.NextHop, $suffix)
        })
        $cmds  = @($persistOnlyBad | Where-Object { $_.DeleteCommand } | ForEach-Object { $_.DeleteCommand })
        $routeWord = if ($persistOnlyBad.Count -eq 1) { 'route is' } else { 'routes are' }
        $summary = ('{0} persistent {1} configured with a next hop that could not be reached: {2}. They are NOT in the active forwarding table, so they are not steering traffic and are not the cause of any failure happening right now.' -f $persistOnlyBad.Count, $routeWord, ($lines -join '; '))

        $action = 'Do not treat these as the current fault.'
        if ($willActivate.Count -gt 0) {
            $aliases = (@($willActivate | ForEach-Object { $_.InterfaceAlias }) | Select-Object -Unique) -join ', '
            if ($willActivate.Count -eq 1) {
                $summary += (' One is bound to an interface that is merely disconnected ({0}), so it WILL be installed when that comes up and will change the path at that moment.' -f $aliases)
                $action   += (' The route bound to {0} is the one to watch: it activates when that adapter connects.' -f $aliases)
            } else {
                $summary += (' {0} of them are bound to interfaces that are merely disconnected ({1}), so they WILL be installed when those come up and will change the path at that moment.' -f $willActivate.Count, $aliases)
                $action   += (' The routes bound to {0} are the ones to watch: they activate when those adapters connect.' -f $aliases)
            }
        }
        if ($orphaned.Count -gt 0) {
            if ($orphaned.Count -eq 1) {
                $summary += ' One is bound to an interface index that no longer exists and therefore can never be installed at all - that one is inert.'
                $action   += ' The orphaned one can be deleted immediately; it cannot come back.'
            } else {
                $summary += (' {0} of them are bound to interface indexes that no longer exist and therefore can never be installed at all - those are inert.' -f $orphaned.Count)
                $action   += ' The orphaned ones can be deleted immediately; they cannot come back.'
            }
        }
        $summary += ' Either way, routes like these are usually pushed by a script or GPO, so the rest of the fleet probably carries them too.'
        $action += ' Then find out what installed them and audit the other machines.'

        $f.Add((New-NtFinding -Title 'Persistent routes present but not installed (configuration residue)' -Severity 'medium' -Confidence 'confirmed' -Summary $summary -Evidence @('Route audit', 'Interfaces') -Action $action -Commands @($cmds)))
    }

    # --- 3c. Routes supplied by DHCP ---------------------------------------
    $dhcpBad = @()
    if ($ev.RouteSection -and $ev.RouteSection.data) {
        $dhcpBad = @(@($ev.RouteSection.data.Routes) | Where-Object { $_.BindingFlag -eq 'DhcpSupplied' -and $_.NextHopStatus -eq 'fail' })
    }
    if ($dhcpBad.Count -gt 0) {
        $lines = @($dhcpBad | ForEach-Object { '{0} via {1}' -f $_.DestinationPrefix, $_.NextHop })
        $f.Add((New-NtFinding -Title 'A DHCP-supplied route has an unreachable next hop' -Severity 'medium' -Confidence 'confirmed' -Summary ('{0} was pushed to this machine by DHCP (option 121, classless static routes), not configured on it.' -f ($lines -join '; ')) -Evidence @('Route audit') -Action 'Do NOT delete this on the endpoint. It will delete cleanly, appear to fix the problem, and return at the next lease renewal - which is a very effective way to waste an afternoon. Correct option 121 in the DHCP scope instead, then release and renew to confirm.' -Commands @('ipconfig /release', 'ipconfig /renew', 'route print -4')))
    }

    # --- 3d. Installed but bound to the wrong interface --------------------
    $misbound = @()
    if ($ev.RouteSection -and $ev.RouteSection.data) {
        $misbound = @(@($ev.RouteSection.data.Routes) | Where-Object { $_.BindingFlag -eq 'MisboundNextHop' -and $_.InActiveTable })
    }
    if ($misbound.Count -gt 0) {
        $lines = @($misbound | ForEach-Object { '{0} via {1} on "{2}"' -f $_.DestinationPrefix, $_.NextHop, $_.InterfaceAlias })
        $f.Add((New-NtFinding -Title 'A route is installed against an interface that cannot reach its next hop' -Severity 'high' -Confidence 'confirmed' -Summary ('{0}. The interface is connected, so the route IS in the forwarding table - but the next hop is not on any subnet that interface holds, so traffic matching it goes nowhere.' -f ($lines -join '; ')) -Evidence @('Route audit', 'Interfaces') -Action 'This is almost always a route added by hand or by script while the wrong adapter was primary. Delete it and re-add it against the correct interface, or better, let the gateway own the route.' -Commands @(@($misbound | Where-Object { $_.DeleteCommand } | ForEach-Object { $_.DeleteCommand }))))
    }

    # --- 4. Hosts file overriding the target -------------------------------
    if ($ev.NameSection -and $ev.NameSection.data) {
        $hits = @(@($ev.NameSection.data.TargetHits) | Where-Object { -not $_.Commented })
        if ($hostsCoveredByDevice) { $hits = @() }
        # A hosts entry can only ever change NAME resolution. If the target was
        # given as a literal address there is no name to resolve, so an entry
        # that merely mentions that address is untidy, not causal. Calling it
        # critical sends the reader off to edit a file that cannot be involved.
        $targetIsName = ($ev.Target -and -not (Test-NtIsIPv4 ([string]$ev.Target)))
        if ($ev.Identity) { $targetIsName = ($ev.Identity.Kind -eq 'Name') }
        if ($hits.Count -gt 0 -and $targetIsName) {
            $lines = @($hits | ForEach-Object { 'line {0}: {1} -> {2}' -f $_.LineNumber, ($_.Names -join ' '), $_.IPAddress })
            $f.Add((New-NtFinding -Title 'The hosts file has an active entry for this target name' -Severity 'critical' -Confidence 'confirmed' -Summary ('The local hosts file resolves this name itself ({0}), overriding DNS. Nothing in DNS will change it, and it produces no log.' -f ($lines -join '; ')) -Evidence @('Name resolution') -Action 'Comment the entry out, flush the resolver cache, and re-test.' -Commands @('notepad %SystemRoot%\System32\drivers\etc\hosts', 'ipconfig /flushdns')))
        }
        elseif ($hits.Count -gt 0) {
            $lines = @($hits | ForEach-Object { 'line {0}: {1} -> {2}' -f $_.LineNumber, ($_.Names -join ' '), $_.IPAddress })
            $f.Add((New-NtFinding -Title 'Hosts file mentions this address (not a factor)' -Severity 'info' -Confidence 'confirmed' -Summary ('The hosts file contains {0}. Because the target was given as a literal IP address, no name resolution takes place and these entries CANNOT affect the traffic being tested. Recorded so the next person does not have to rule it out again.' -f ($lines -join '; ')) -Evidence @('Name resolution') -Action 'No action for this fault. Tidy the file separately if you wish.'))
        }
        $dupes = @()
        if ($ev.NameSection.data.Hosts) { $dupes = @($ev.NameSection.data.Hosts.Duplicates) }
        if ($dupes.Count -gt 0) {
            $dl = @($dupes | ForEach-Object { '{0} -> {1} on lines {2}' -f $_.Name, $_.IPAddress, (@($_.Lines) -join ', ') })
            $f.Add((New-NtFinding -Title 'Duplicate hosts file entries' -Severity 'info' -Confidence 'confirmed' -Summary ('The same mapping appears more than once: {0}. Windows uses the first match, so this changes nothing - but it usually means the file has been hand-edited repeatedly and is worth tidying.' -f ($dl -join '; ')) -Evidence @('Name resolution') -Action 'Tidy at your convenience. Not related to any fault reported here.'))
        }
        if ($ev.NameSection.data.Dns -and $ev.NameSection.data.Dns.Overridden -and -not $hostsCoveredByDevice) {
            $f.Add((New-NtFinding -Title 'Name resolution is being overridden locally' `
                -Severity 'high' -Confidence 'probable' `
                -Summary 'Normal resolution returns an address that DNS alone does not, and the hosts file carries an entry for this exact name - so something on this machine is redirecting it.' `
                -Evidence @('Name resolution') `
                -Basis @('Normal and DNS-only resolution disagree.', 'The hosts file contains an entry for this name.') `
                -Assumptions @('The two lookups were sequential, not simultaneous. A name behind a load balancer or geo-steered CDN can answer differently between queries for reasons that have nothing to do with this machine.') `
                -Action 'Check the hosts file and any NRPT rules, then re-test against the address DNS actually returns.'))
        }
    }

    # --- 4c. The profile's stated facts against what was measured ----------
    # A profile records what someone believed about a site. Where that differs
    # from what this machine can see, the difference is the finding - the
    # measurement wins, and the profile is not silently trusted or silently
    # ignored.
    if ($ev.Profile) {
        $pg = [string]$ev.Profile.gateway
        $ag = ''
        if ($ev.Context) { try { $ag = [string](Get-NtPrimaryGateway -Context $ev.Context) } catch { } }
        if ($pg -and $ag -and ($pg -ne $ag)) {
            $f.Add((New-NtFinding -Title 'This machine is not behind the gateway the site profile expects' `
                -Severity 'medium' -Confidence 'confirmed' `
                -Summary ('The "{0}" profile states the gateway is {1}, but this machine is using {2}. Either the profile is out of date, or this PC is not on the network the profile describes - and if it is the latter, every other assumption the profile supplies is suspect too.' -f $ev.Profile.site, $pg, $ag) `
                -Evidence @('Endpoint', 'Local gateway') `
                -Basis @(('Profile states gateway {0}.' -f $pg), ('This machine reports gateway {0}.' -f $ag)) `
                -Action 'Confirm which is right before relying on the profile''s peer, ports or NAT entries.'))
        }
        foreach ($c in @(Get-NtProfileCaveats -Profile $ev.Profile)) {
            if (-not $c.Unconfirmed) { continue }
            $f.Add((New-NtFinding -Title ('Site profile value "{0}" is marked unconfirmed' -f $c.Field) `
                -Severity 'info' -Confidence 'confirmed' `
                -Summary ('The profile itself flags this as an assumption rather than a verified fact: {0}' -f $c.Note) `
                -Evidence @('Site profile') `
                -Assumptions @('This value came from the profile, not from a measurement taken during this run.') `
                -Action 'Verify it on site and correct the profile, so the next person is not misled by it.'))
        }
    }

    # --- 5. On-link target and address resolution ---------------------------
    # Two ordering problems used to live here.
    #
    # First, the cache is read BEFORE the target is probed, so a perfectly
    # healthy host that simply had not been talked to recently produced a
    # critical/confirmed "does not answer ARP" - and a later successful ping
    # or TCP handshake never withdrew it. The review reproduced a report
    # asserting both that finding and confirmed reachability.
    #
    # Second, the gate was "no entry at all", so a STALE or UNREACHABLE entry
    # SUPPRESSED the finding. An Unreachable entry records a resolution
    # failure - exactly the case this is meant to catch.
    if ($ev.ArpSection -and $ev.ArpSection.data -and $ev.ArpSection.data.TargetOnLink) {
        $tEntry = $ev.ArpSection.data.TargetEntry
        $tState = ''
        if ($tEntry) { $tState = [string]$tEntry.State }
        $resolved = $false
        if ($tEntry) {
            $resolved = (Get-NtNeighbourConfidence -State $tState).ProvesLife
        }
        if ($targetReachable) {
            # Traffic got through. Whatever the cache said is now moot, and
            # saying so explicitly stops the next person re-checking it.
            if (-not $resolved) {
                $f.Add((New-NtFinding -Title 'Address resolution looked incomplete, but the target answered anyway' `
                    -Severity 'info' -Confidence 'confirmed' `
                    -Summary ('The neighbour cache showed {0} for this target when it was read, which was BEFORE any probe was sent. The target then responded, so address resolution is working and the cache state was simply not current.' -f $(if ($tState) { 'state ' + $tState } else { 'no entry' })) `
                    -Evidence @('ARP and layer 2', 'Target') `
                    -Basis @('The target responded to at least one probe.') `
                    -Action 'No action. Recorded so the earlier row is not mistaken for a fault.'))
            }
        } elseif (-not $resolved) {
            $detail = if ($tState) {
                ('The neighbour entry for this target is in state {0}, which records a failed or unconfirmed resolution rather than a present host, and nothing answered when probed.' -f $tState)
            } else {
                'No neighbour entry exists for this target and nothing answered when probed, so address resolution did not complete during this test.'
            }
            $f.Add((New-NtFinding -Title 'Address resolution did not complete for this on-link target' `
                -Severity 'high' -Confidence 'probable' `
                -Summary ('{0} A host must answer address resolution to be reachable at all, so this points at the device or the switch port rather than at routing - it is powered off, unplugged, or on a different VLAN than its address suggests.' -f $detail) `
                -Evidence @('ARP and layer 2', 'Target') `
                -Basis @($detail) `
                -Assumptions @('Address resolution was observed only for the duration of this run. A device that is merely slow to respond, or one behind a switch still learning, can look the same.') `
                -Action 'Check power and link on the device itself, and confirm the switch port VLAN. This is not a routing problem and no routing change will fix it.'))
        }
    }

    # --- 6. The decision table (runbook section 2, "one host works, its
    #        neighbour does not") ------------------------------------------
    # Unknown is NOT "yes". This read ($null -or value) mapped an unmeasured
    # subnet relationship straight onto "the peer is on the destination
    # subnet", which is the assumption the confident branches below rest on.
    $peerSameNet = ($ev.PeerSameNet -eq $true)
    $peerNetUnknown = ($null -eq $ev.PeerSameNet)
    if ($peerTested -and $peerReachable -and -not $targetReachable -and $peerNetUnknown) {
        $f.Add((New-NtFinding -Title 'The comparison host answered, but its role is unverified' `
            -Severity 'medium' -Confidence 'confirmed' `
            -Summary ('{0} responded and {1} did not. Whether that is meaningful depends on {0} being in the SAME destination network as {1}, and the remote mask cannot be seen from this machine - they may be in different /25s, or in the same /23.' -f $ev.Peer, $targetLabel) `
            -Evidence @('Peer rung 5') `
            -Basis @(('{0} responded.' -f $ev.Peer), ('{0} did not respond.' -f $targetLabel)) `
            -Assumptions @('The two hosts are assumed to share a destination network. That was not established.') `
            -Action 'Supply the destination network (for example 10.50.40.0/23) and re-run. A comparison host on the destination network tests remote access; one on your own network only tests local access, and the difference decides what this result means.'))
    }
    elseif ($peerTested -and $peerReachable -and -not $targetReachable -and $ev.PeerSameNet -eq $false) {
        # The peer answered, but it is not on the target's subnet, so it proves
        # nothing about that subnet. Saying so is more useful than a confident
        # conclusion drawn from the wrong evidence.
        $f.Add((New-NtFinding -Title 'The peer host is not on the destination subnet' -Severity 'medium' -Confidence 'confirmed' -Summary ('{0} responded, but it does not share a subnet with {1}. The "transport is proven" inference needs a peer on the DESTINATION network - this one only proves its own path works.' -f $ev.Peer, $targetLabel) -Evidence @('Peer rung 5') -Action 'Re-run with a peer that shares the destination subnet. Until then the transport cannot be ruled in or out.'))
    }
    elseif ($peerTested -and $peerReachable -and -not $targetReachable) {
        # The prose has to match the confidence. This branch is now gated on
        # the four comparability measurements and reports at 'probable', but
        # the wording still said the transport was "PROVEN" and the fault was
        # "specific to this one host" - the exact overclaim the gate was added
        # to stop. What is proven is that the workstation treats them
        # identically; where the fault lies is still a hypothesis.
        $summary = ('{0} on the destination network answers on {1}, and {2} answers on nothing. Both were reached over the same route, the same next hop, the same interface and the same source address, so this workstation is treating them identically - nothing here explains the difference. That puts the target host, its return path, or a policy that singles it out as the places to look.' -f $ev.Peer, $peerProof, $targetLabel)
        if ($peerProof -eq 'TCP') {
            $summary += ' The peer was proven by a completed TCP handshake rather than by ping, which is the stronger of the two: a handshake requires the packet to arrive AND the reply to find its way back.'
        }
        $action = 'Work the per-host candidates in this order: (1) the return route on the target host - especially if anything along the path performs source NAT, because then the host needs a route for the TRANSLATED address, not for this client subnet; (2) a host firewall rule scoped to "Local subnet", which silently excludes remote subnets; (3) the application bound to a specific interface rather than 0.0.0.0.'
        $cmds = [System.Collections.Generic.List[string]]::new()
        $srcNote = if ($ev.Selected.SourceAddress) { $ev.Selected.SourceAddress } else { 'your client subnet' }
        $cmds.Add(('On the target host: route print -4 | findstr {0}' -f (($srcNote -split '\.')[0..1] -join '.')))
        $cmds.Add('On the target host: netstat -ano | findstr LISTENING')
        $cmds.Add('On the target host: check inbound firewall rule scopes for "Local subnet"')

        if ($ev.Profile -and $ev.Profile.knownNat) {
            foreach ($nat in @($ev.Profile.knownNat)) {
                $summary += (' The site profile records a known translation ({0}: {1} -> {2}), so the far end will see traffic sourced from {2} and needs a return route for THAT address.' -f $nat.rule, $nat.from, $nat.to)
                $cmds.Add(('On the target host: route print -4 | findstr {0}' -f $nat.to))
            }
            $action += (' Note on the fix: adding a /32 return route for the translated address on the server works, but it is a workaround - it has to be repeated on every server this site needs to reach. Removing the source NAT so the far end sees the real client subnet is the cleaner permanent answer, subject to confirming nothing else depends on the translation.')
        }
        # Only claim "the fault is this host" when the comparison actually was
        # like-for-like. This branch used to assert "same subnet, same
        # transport, same rules" and stamp it 'confirmed' without reading any
        # of the four measurements that establish it - producing, in the
        # review's own reproduction, both this finding AND "this workstation
        # treats the target and the peer differently" in one report.
        #
        # Note the confidence: 'probable', not 'confirmed'. The OBSERVATION is
        # confirmed - one answered, the other did not. Which host or policy is
        # at fault is a hypothesis until a discriminating test settles it.
        $cmp = Get-NtPeerComparability -Evidence $ev
        if ($cmp.Comparable) {
            $f.Add((New-NtFinding -Title 'The fault looks specific to this host, not to the path' `
                -Severity 'high' -Confidence 'probable' -Summary $summary `
                -Evidence @('Target', 'Peer rung 5', 'Target vs peer') `
                -Basis (@($cmp.Basis) + @(('{0} answered on {1}; {2} answered on nothing.' -f $ev.Peer, $peerProof, $targetLabel))) `
                -Assumptions $cmp.Assumptions `
                -Action $action -Commands @($cmds)))
        } else {
            $why = if (@($cmp.Differences).Count -gt 0) { (@($cmp.Differences) -join ' ') } else { 'The two hosts were not compared side by side, so it is not known whether they were treated the same way.' }
            $obs = ('{0} answered on {1} and {2} answered on nothing. That contrast is real, but the two were NOT reached the same way, so it does not isolate the fault to the target: {3}' -f $ev.Peer, $peerProof, $targetLabel, $why)
            $f.Add((New-NtFinding -Title 'One host answered and the other did not - but they were not tested like for like' `
                -Severity 'medium' -Confidence 'confirmed' -Summary $obs `
                -Evidence @('Target', 'Peer rung 5', 'Target vs peer') `
                -Basis @(('{0} answered on {1}.' -f $ev.Peer, $peerProof), ('{0} answered on nothing.' -f $targetLabel)) `
                -Assumptions @($cmp.Assumptions) `
                -Action ('Resolve the difference above before drawing a conclusion. Any of these remain open: target-specific firewall or ACL policy; the service not running or bound to one interface; destination-specific routing or NAT; a missing return route for the source address actually used; or the target simply being offline. ' + $action)))
        }
    }
    elseif ($peerTested -and -not $peerReachable -and -not $targetReachable -and ($peerSameNet -or $peerNetUnknown)) {
        # Two silent endpoints are two silent endpoints. Neither is known to
        # offer the ports that were probed, so "the whole subnet is
        # unreachable" is one explanation among several - and calling it
        # critical/probable made it the headline over every other finding.
        $f.Add((New-NtFinding -Title 'Neither tested endpoint responded - a shared path or policy problem is possible' `
            -Severity 'high' -Confidence 'possible' `
            -Summary ('Neither {0} nor {1} answered ICMP or any probed port. That is consistent with the prefix not being carried across the transport, or with no return path for this client subnet - but it is equally consistent with both hosts being off, both filtering these probes, or neither running the service that was probed. Two failures do not establish which.' -f $targetLabel, $ev.Peer) `
            -Evidence @('Target', 'Peer rung 5') `
            -Basis @(('{0} did not respond to ICMP or any probed port.' -f $targetLabel), ('{0} did not respond to ICMP or any probed port.' -f $ev.Peer)) `
            -Assumptions @(
                'Both endpoints are assumed to be powered on and to offer at least one of the probed services. Neither was confirmed.',
                'The comparison host was not service-verified, so it is not established as a working control.') `
            -Action 'Get one confirmed-working service on that subnet before escalating - a host you know answers, on a port you know it serves. If that also fails, the shared-path explanation is strong and worth taking to whoever owns the inter-site transport: ask whether this client subnet is advertised across the overlay and whether a return route exists for it. If it succeeds, the problem is narrower than the subnet. Testing from a second source PC also separates a source-side cause from a destination-side one.'))
    }
    elseif (-not $peerTested -and -not $targetReachable -and (Test-NtIsIPv4 ([string]$ev.TargetIp)) -and
            -not ($ev.Neighbour -and $ev.Neighbour.How -eq 'not-needed') -and
            -not ($ev.Identity -and ($ev.Identity.NotFound -or $ev.Identity.NoLease))) {
        # Only when the automatic search came up empty (or was turned off).
        # Not for an on-link target - ARP and the gateway already answer the
        # question - and not for a device that was not found or has no lease,
        # where there is no path question to settle.
        $nb = $ev.Neighbour
        $peerHint = ''
        if ($ev.TargetIp -match '^(\d+\.\d+\.\d+)\.\d+$') {
            $peerHint = (' For {0}, that is another address on {1}.x that you believe is working.' -f $ev.TargetIp, $Matches[1])
        }
        $searched = if ($nb -and [int]$nb.Tried -gt 0) { (' {0}' -f $nb.Detail) } else { '' }
        $f.Add((New-NtFinding -Title 'No working neighbour of the target could be found - the path cannot be separated from the host' `
            -Severity 'medium' -Confidence 'confirmed' `
            -Summary ('{0} is unreachable, and nothing else on its network answered either, so there is no way to tell a broken path from a single broken host.{1}' -f $targetLabel, $searched) `
            -Evidence @('Neighbour rung 5') `
            -Assumptions $(if ($nb -and $nb.AssumedPrefix) { @('The search assumed the target''s network is a /24. If it is larger or smaller, working neighbours may exist outside the addresses tried.') } else { @() }) `
            -Action ('If you know any other machine on the target''s network that should be working, put it in the "Neighbour" box and run again.{0} If it answers and the target does not, the network between here and there is proven and the fault is that one host. If it does not answer either, the problem is the path.' -f $peerHint)))
    }

    # How the comparison host was obtained, when the tool chose it. Every
    # finding above that names it rests on that choice.
    if ($peerTested -and $ev.Neighbour -and $ev.Neighbour.How -in @('inventory', 'probe')) {
        $f.Add((New-NtFinding -Title ('Neighbour {0} was chosen automatically' -f $ev.Peer) `
            -Severity 'info' -Confidence 'confirmed' `
            -Summary ([string]$ev.Neighbour.Detail) `
            -Evidence @('Neighbour rung 5', 'Device') `
            -Assumptions $(if ($ev.Neighbour.AssumedPrefix) { @(('Its network was assumed to be {0}; the real mask cannot be seen from here.' -f $ev.Neighbour.Prefix)) } else { @() }) `
            -Action 'If you know a better control - a machine on the same network running the same service - put it in the Neighbour box and run again.'))
    }

    # --- 6b. What the differential RULES OUT -------------------------------
    # Worth stating explicitly. Most of an investigation is spent eliminating
    # things, and an elimination that is never written down gets re-checked by
    # the next person - or, worse, quietly assumed to still be open.
    # Only meaningful when the peer really is on the target's subnet. Two hosts
    # on different subnets are SUPPOSED to resolve differently, and reporting
    # that as a divergence is noise.
    if ($ev.DiffSection -and $ev.DiffSection.data -and $peerSameNet) {
        $dd = $ev.DiffSection.data
        if ($dd.RouteSame -and $dd.SourceSame -and -not $targetReachable -and $peerReachable) {
            $f.Add((New-NtFinding -Title 'Client-side routing is ruled out as the difference' -Severity 'info' -Confidence 'confirmed' -Summary ('Windows selects the same route ({0}) and the same source address ({1}) for both {2} and {3}. The workstation is therefore treating them identically, and nothing on this machine explains why one answers and the other does not.' -f $dd.PeerRoute.RoutePrefix, $dd.PeerRoute.SourceAddress, $targetLabel, $ev.Peer) -Evidence @('Target vs peer') -Action 'Stop looking at this workstation. The difference is at the target host, on its return path, or in a policy that treats the two destinations differently.'))
        }
        elseif (-not $dd.RouteSame -or -not $dd.SourceSame) {
            $bits = [System.Collections.Generic.List[string]]::new()
            if (-not $dd.RouteSame)  { $bits.Add(('different routes ({0} vs {1})' -f $ev.Selected.RoutePrefix, $dd.PeerRoute.RoutePrefix)) }
            if (-not $dd.SourceSame) { $bits.Add(('different source addresses ({0} vs {1})' -f $ev.Selected.SourceAddress, $dd.PeerRoute.SourceAddress)) }
            $f.Add((New-NtFinding -Title 'This workstation treats the target and the peer differently' -Severity 'high' -Confidence 'confirmed' -Summary ('{0} and {1} are resolved with {2}. The divergence starts on this machine, so it must be explained before anything downstream is blamed.' -f $targetLabel, $ev.Peer, ($bits -join ' and ')) -Evidence @('Target vs peer', 'Route audit') -Action 'Work out which route is producing the difference and why it exists. A per-host or per-subnet static route is the usual answer.'))
        }
    }

    # --- 7. ICMP filtered but the service works ----------------------------
    if (-not $ev.TargetIcmp.Success -and $portsOpen -gt 0) {
        $ports = @(@($ev.TargetPorts) | ForEach-Object { $_.Port })
        # "Nothing to fix for users" was too strong: a completed handshake
        # proves transport, not that the application works. HTTPS answering
        # does not resolve an RDP complaint, and a TCP accept establishes
        # neither authentication, nor valid TLS, nor a working transaction.
        $f.Add((New-NtFinding -Title 'ICMP is filtered, but the requested port accepted a connection' `
            -Severity 'low' -Confidence 'confirmed' `
            -Summary ('{0} does not answer ping, but TCP {1} accepted a connection. A completed handshake proves the full round trip including the return path, so the transport is working.' -f $targetLabel, ($ports -join ', ')) `
            -Evidence @('Target') `
            -Basis @(('TCP {0} completed a handshake.' -f ($ports -join ', ')), 'ICMP echo was not answered.') `
            -Assumptions @('Transport only. A completed handshake does not establish that the application behind the port authenticates, serves valid TLS, or completes a transaction - if the user''s complaint is about the application rather than connectivity, it is still open.') `
            -Action 'Do not chase the failed ping - it is a filtering policy, not an outage. If the user still cannot use the service, test the application itself: the network layer is proven and the problem is above it.'))
    }

    # --- 7b. Host is up, but not listening where we looked -----------------
    # Without this the ladder shows a warn rung and the report says "no
    # findings", which reads as "nothing wrong" when the operator was asking
    # about a specific service.
    if ($portsOpen -eq 0 -and @($ev.PortsProbed).Count -gt 0 -and ($ev.TargetIcmp.Success -or $discoveredOpen -gt 0)) {
        $probed = (@($ev.PortsProbed) -join ', ')
        $found  = @($ev.Discovered)

        # Is the target this machine's own gateway? Then "nothing on your ports"
        # is not a finding at all - scanning your own edge device and being told
        # it does not serve SMB or RDP is noise dressed up as a fault.
        $gateways = @()
        if ($ev.Context) { $gateways = @($ev.Context.Gateways) }
        $targetIsGateway = ($gateways -contains [string]$ev.TargetIp)

        if ($found.Count -gt 0) {
            # We already know what it serves, so say so instead of sending the
            # operator off to run netstat on a host we just finished scanning.
            $list = @($found | ForEach-Object {
                $entry = $_
                if ($entry.Banner) { '{0}/tcp {1} ({2})' -f $entry.Port, $entry.Service, $entry.Banner }
                else { '{0}/tcp {1}' -f $entry.Port, $entry.Service }
            })
            $ports = (@($found | ForEach-Object { $_.Port }) -join ', ')

            if ($targetIsGateway) {
                $f.Add((New-NtFinding -Title ('{0} is this machine''s default gateway, serving {1}' -f $targetLabel, $ports) -Severity 'info' -Confidence 'confirmed' -Summary ('It answers ICMP and serves {0}. Application ports were not expected here: this is the edge device, not a server, and nothing about the result suggests a problem.' -f ($list -join '; ')) -Evidence @('Target', 'Gateway') -Action 'No action. The Gateway tab has the full management-plane inventory for this device.'))
            } else {
                $f.Add((New-NtFinding -Title ('{0} is listening on {1}, not on the ports you asked for' -f $targetLabel, $ports) -Severity 'medium' -Confidence 'confirmed' -Summary ('Nothing answered on {0}, but the host is serving: {1}. So it is up, reachable, and running something - just not what was probed.' -f $probed, ($list -join '; ')) -Evidence @('Target') -Action 'Re-run against a port it actually serves. If this turns out to be network kit rather than the application server, that is the whole explanation.'))
            }
        } elseif ($targetIsGateway) {
            $f.Add((New-NtFinding -Title ('{0} is this machine''s default gateway and answers ICMP' -f $targetLabel) -Severity 'info' -Confidence 'confirmed' -Summary ('It did not accept TCP on {0}, or on the wider sweep of common ports. A hardened edge device legitimately answers none of them from the LAN while routing perfectly well.' -f $probed) -Evidence @('Target', 'Gateway') -Action 'No action. Never infer device health from a port scan of the gateway - ARP resolution, working DHCP and working internet are the proof that matters.'))
        } else {
            $extra = ''
            if ($null -ne $ev.Discovered) { $extra = ' A wider sweep of common service and management ports found nothing open either, so it is not simply the wrong port number.' }
            $f.Add((New-NtFinding -Title ('{0} is up, but nothing is listening on the ports checked' -f $targetLabel) -Severity 'medium' -Confidence 'confirmed' -Summary ('The host answers ICMP, so it is powered on and the path works in both directions. No TCP handshake completed on {1}.{2} A connect scan cannot separate a closed port from a filtered one, so this is either the service being down or a host firewall.' -f $targetLabel, $probed, $extra) -Evidence @('Target') -Action 'Check the service is running on the target and that its host firewall permits this source subnet. On the target, netstat -ano | findstr LISTENING shows what it is bound to, including interfaces this scan cannot reach.'))
        }
    }

    # --- 8. Fully reachable ------------------------------------------------
    if ($ev.TargetIcmp.Success -and $portsOpen -gt 0) {
        # Only when the route to THIS target could have used the overlay; a
        # measured route by another interface is not an alternate path here.
        $vpnRisk = ($ev.Vpn.Suspected -and -not ($selAlias -and -not $selViaVpn))
        $f.Add((New-NtFinding -Title ('{0} is reachable' -f $targetLabel) -Severity 'info' -Confidence 'confirmed' -Summary ('Answers ICMP and accepted TCP on {0}. {1}' -f ((@($ev.TargetPorts) | ForEach-Object { $_.Port }) -join ', '), $ev.TargetIcmp.Detail) -Evidence @('Target') -Action $(if ($vpnRisk) { 'Re-test with the VPN disconnected before calling this fixed - with an alternate path live this result is not trustworthy.' } else { 'No action.' })))
    }

    # --- 9. Path dies at the local edge ------------------------------------
    if ($ev.Trace -and $ev.Trace.Ok -and -not $ev.Trace.Reached -and -not $targetReachable) {
        $last = Get-NtLastRespondingHop -Trace $ev.Trace
        $gw = Get-NtPrimaryGateway -Context $ev.Context
        if ($last) {
            $atEdge = ($last.Hop -le 2) -or ($last.Address -eq $gw)
            $summary = ('The last device to answer was {0} at hop {1}; nothing beyond it replied.' -f $last.Address, $last.Hop)
            $appliance = ''
            if ($ev.GwSection -and $ev.GwSection.data) { $appliance = [string]$ev.GwSection.data.Appliance }
            if ($atEdge) {
                $summary += ' The path stops at your own edge. A firewall log line reading "allowed" is not the end of the story here: an allowed and forwarded packet with no reply means the fault is downstream, and the NAT column in that same log row tells you what the far end actually sees.'
                $action = 'Read the firewall log for this destination and note the rule ID AND the NAT rule ID. Then capture on the transport interface to confirm the source address leaving the device.'
            } else {
                $summary += ' Intermediate routers commonly suppress TTL-expired replies, so a trace that stops short is weaker evidence than a failed peer test.'
                $action = 'Confirm with the peer-host test rather than relying on the trace. When escalating, give the last hop that ANSWERED as a reference point - not as a demarcation: routers routinely forward traffic while declining to answer TTL-expiry, so the silence after it does not locate the fault there.'
            }
            $f.Add((New-NtFinding -Title ('The path stops responding after {0}' -f $last.Address) -Severity 'medium' -Confidence 'probable' -Summary $summary -Evidence @('Path') -Action $action -Commands @(Get-NtVendorCommands -Appliance $appliance -Target $ev.TargetIp)))
        }
    }

    # --- 10. Path instability ----------------------------------------------
    if ($ev.TargetIcmp.Success -and -not $ev.TargetIcmp.TtlStable) {
        $f.Add((New-NtFinding -Title 'The reply TTL changed during the test' -Severity 'medium' -Confidence 'confirmed' -Summary $ev.TargetIcmp.Detail -Evidence @('Target') -Action 'Replies are arriving over more than one path, or the path changed mid-test. Check for a flapping route or an active failover on the transport before drawing any conclusion from the latency figures.'))
    }

    # --- 11. Known translation, recorded for the escalation ----------------
    if ($ev.Profile -and $ev.Profile.knownNat -and $targetReachable) {
        foreach ($nat in @($ev.Profile.knownNat)) {
            $f.Add((New-NtFinding -Title 'A source NAT is recorded for this path' -Severity 'info' -Confidence 'probable' -Summary ('The site profile records {0}: traffic from {1} is translated to {2}. The far end sees connections from {2}, so any return route it needs is for {2} and not for the client subnet.' -f $nat.rule, $nat.from, $nat.to) -Evidence @('Site profile') -Action 'Confirm on the firewall before relying on this - it comes from the profile, not from a measurement. Nothing on an endpoint can observe a translation performed downstream.'))
        }
    }

    # Order: worst first, and within a severity keep the order the rules fired.
    $rank = @{ 'critical' = 0; 'high' = 1; 'medium' = 2; 'low' = 3; 'info' = 4 }
    $i = 0
    $indexed = foreach ($item in $f) {
        [pscustomobject]@{ Item = $item; Rank = [int]$rank[$item.severity]; Seq = $i }
        $i++
    }
    return @(@($indexed) | Sort-Object Rank, Seq | ForEach-Object { $_.Item })
}

function Get-NtVerdict {
    # One line for the top of the report and the title bar of the GUI.
    param($Report)
    $findings = @($Report.findings)
    $worst = 'info'
    foreach ($sev in @('critical','high','medium','low')) {
        if (@($findings | Where-Object { $_.severity -eq $sev }).Count -gt 0) { $worst = $sev; break }
    }
    $firstFail = @(@($Report.ladder) | Where-Object { $_.status -eq 'fail' } | Select-Object -First 1)
    $headline = ''
    $top = @($findings | Where-Object { $_.severity -in @('critical','high') } | Select-Object -First 1)
    if ($top.Count -gt 0) { $headline = [string]$top[0].title }
    elseif ($findings.Count -gt 0) { $headline = [string]$findings[0].title }
    else { $headline = 'No findings.' }

    [pscustomobject]@{
        level        = $worst
        headline     = $headline
        firstFailure = $(if ($firstFail.Count -gt 0) { ('Rung {0} - {1}: {2}' -f $firstFail[0].number, $firstFail[0].name, $firstFail[0].result) } else { '' })
        findingCount = $findings.Count
    }
}

# =============================================================================
# 13. Inventory - IP and MAC history for cross-matching
# =============================================================================
# Keyed by MAC, because the MAC is the thing that identifies a device across
# address changes. IP is the thing that changes.
#
# Hosts with no MAC are kept in a SEPARATE collection. An off-link host can
# never yield a MAC from here, and inventing a placeholder key for it would
# quietly corrupt every cross-match that follows.

function Get-NtInventoryPaths {
    param([string]$ProjectDir = '', [string]$Site = '')
    $local = Join-Path (Get-NtDataDir) 'inventory.json'
    $proj = ''
    $dir = Get-NtProjectDir -Hint $ProjectDir
    if ($dir) {
        $invDir = Join-Path $dir 'inventory'
        $name = if ($Site) { ('{0}.json' -f (($Site -replace '[^\w\-\.]', '_').ToLower())) } else { 'all-sites.json' }
        $proj = Join-Path $invDir $name
    }
    [pscustomobject]@{ Local = $local; Project = $proj }
}

function New-NtInventory {
    param()
    [pscustomobject]@{
        schema        = 'nettoolkit-inventory/1'
        updatedUtc    = (ConvertTo-NtIso8601 (Get-Date))
        devices       = @()
        ipsWithoutMac = @()
        observations  = @()
    }
}

function Merge-NtInventory {
    # Pure function: takes an inventory and a set of observed hosts, returns the
    # merged inventory. Kept separate from file IO so it can be tested and so
    # the same merge serves both output files.
    param(
        $Inventory,
        $Hosts,
        [string]$Site = '',
        [string]$Source = '',
        [int]$MaxIpHistory = 25
    )
    if (-not $Inventory) { $Inventory = New-NtInventory }
    $now = ConvertTo-NtIso8601 (Get-Date)

    $devices = [System.Collections.Generic.List[object]]::new()
    foreach ($d in @($Inventory.devices)) { $devices.Add($d) }
    $noMac = [System.Collections.Generic.List[object]]::new()
    foreach ($n in @($Inventory.ipsWithoutMac)) { $noMac.Add($n) }

    $byMac = @{}
    foreach ($d in $devices) { if ($d.mac) { $byMac[[string]$d.mac] = $d } }
    $byIpNoMac = @{}
    foreach ($n in $noMac) { $byIpNoMac[('{0}|{1}' -f $n.ip, $n.site)] = $n }

    $runId = [guid]::NewGuid().ToString('N').Substring(0, 12)
    $newDevices = 0
    $newIps = 0

    foreach ($h in @($Hosts)) {
        $ip = [string]$h.IP
        if (-not $ip) { continue }
        $mac = ConvertTo-NtNormalMac ([string]$h.Mac)

        if (-not $mac) {
            # No MAC: routed host, or an on-link host whose ARP entry expired.
            $key = ('{0}|{1}' -f $ip, $Site)
            if ($byIpNoMac.ContainsKey($key)) {
                $e = $byIpNoMac[$key]
                $e.lastSeenUtc = $now
                $e.count = [int]$e.count + 1
                if ($h.Hostname -and -not $e.hostname) { $e.hostname = [string]$h.Hostname }
                if ($h.Ttl -gt 0) { $e.ttl = [int]$h.Ttl }
            } else {
                $entry = [pscustomobject]@{
                    ip           = $ip
                    site         = $Site
                    hostname     = [string]$h.Hostname
                    ttl          = [int]$h.Ttl
                    osClass      = $(if ($h.TtlReading) { [string]$h.TtlReading.OsClass } else { 'unknown' })
                    firstSeenUtc = $now
                    lastSeenUtc  = $now
                    count        = 1
                    reason       = 'No MAC available - the host is routed (off-link) or its ARP entry had expired.'
                }
                $noMac.Add($entry)
                $byIpNoMac[$key] = $entry
            }
            continue
        }

        if ($byMac.ContainsKey($mac)) {
            $dev = $byMac[$mac]
            $dev.lastSeenUtc = $now
            if ($h.Vendor -and ($dev.vendor -eq 'Unknown' -or -not $dev.vendor)) { $dev.vendor = [string]$h.Vendor }

            $ipList = [System.Collections.Generic.List[object]]::new()
            foreach ($x in @($dev.ips)) { $ipList.Add($x) }
            $hit = $null
            foreach ($x in $ipList) { if ($x.ip -eq $ip -and $x.site -eq $Site) { $hit = $x; break } }
            if ($hit) {
                $hit.lastSeenUtc = $now
                $hit.count = [int]$hit.count + 1
            } else {
                $ipList.Add([pscustomobject]@{ ip = $ip; site = $Site; firstSeenUtc = $now; lastSeenUtc = $now; count = 1 })
                $newIps++
            }
            # Keep the most recent history only; an old DHCP address from two
            # years ago adds noise, not signal.
            $trimmed = @($ipList | Sort-Object lastSeenUtc -Descending | Select-Object -First $MaxIpHistory)
            $dev.ips = [object[]]$trimmed

            $names = [System.Collections.Generic.List[string]]::new()
            foreach ($x in @($dev.hostnames)) { if ($x) { $names.Add([string]$x) } }
            if ($h.Hostname -and ($names -notcontains [string]$h.Hostname)) { $names.Add([string]$h.Hostname) }
            $dev.hostnames = [object[]]@($names)

            $ttls = [System.Collections.Generic.List[int]]::new()
            foreach ($x in @($dev.ttlObserved)) { $ttls.Add([int]$x) }
            if ($h.Ttl -gt 0 -and ($ttls -notcontains [int]$h.Ttl)) { $ttls.Add([int]$h.Ttl) }
            $dev.ttlObserved = [int[]]@($ttls)

            $ports = [System.Collections.Generic.List[int]]::new()
            foreach ($x in @($dev.portsSeen)) { $ports.Add([int]$x) }
            foreach ($p in @($h.OpenPorts)) { if ($ports -notcontains [int]$p) { $ports.Add([int]$p) } }
            $dev.portsSeen = [int[]]@(@($ports) | Sort-Object)

            $sites = [System.Collections.Generic.List[string]]::new()
            foreach ($x in @($dev.sites)) { if ($x) { $sites.Add([string]$x) } }
            if ($Site -and ($sites -notcontains $Site)) { $sites.Add($Site) }
            $dev.sites = [object[]]@($sites)
        } else {
            $dev = [pscustomobject]@{
                mac                 = $mac
                macFormatted        = (Format-NtMac $mac)
                vendor              = $(if ($h.Vendor) { [string]$h.Vendor } else { 'Unknown' })
                locallyAdministered = (Test-NtLocallyAdministered $mac)
                ips                 = @([pscustomobject]@{ ip = $ip; site = $Site; firstSeenUtc = $now; lastSeenUtc = $now; count = 1 })
                hostnames           = [object[]]@($(if ($h.Hostname) { @([string]$h.Hostname) } else { @() }))
                ttlObserved         = [int[]]@($(if ($h.Ttl -gt 0) { @([int]$h.Ttl) } else { @() }))
                osClass             = $(if ($h.TtlReading) { [string]$h.TtlReading.OsClass } else { 'unknown' })
                portsSeen           = [int[]]@($h.OpenPorts)
                sites               = [object[]]@($(if ($Site) { @($Site) } else { @() }))
                firstSeenUtc        = $now
                lastSeenUtc         = $now
            }
            $devices.Add($dev)
            $byMac[$mac] = $dev
            $newDevices++
        }
    }

    $obs = [System.Collections.Generic.List[object]]::new()
    foreach ($o in @($Inventory.observations)) { $obs.Add($o) }
    $obs.Add([pscustomobject]@{
        runId       = $runId
        utc         = $now
        scannerHost = $env:COMPUTERNAME
        site        = $Site
        source      = $Source
        hostCount   = @($Hosts).Count
    })
    # Cap the observation log so the file cannot grow without bound.
    $obsTrim = @($obs | Sort-Object utc -Descending | Select-Object -First 200)

    $Inventory.devices       = [object[]]@($devices)
    $Inventory.ipsWithoutMac = [object[]]@($noMac)
    $Inventory.observations  = [object[]]@($obsTrim)
    $Inventory.updatedUtc    = $now

    $Inventory | Add-Member -NotePropertyName lastMerge -NotePropertyValue ([pscustomobject]@{
        runId       = $runId
        newDevices  = $newDevices
        newIps      = $newIps
        hostsMerged = @($Hosts).Count
    }) -Force

    return $Inventory
}

function Update-NtInventory {
    # Merges an observation set into BOTH the per-machine store and the project
    # rollup. Two files on purpose: the ProgramData copy accumulates whatever
    # this machine has ever seen, and the project copy is the one that travels
    # between sites for cross-matching.
    param(
        $Hosts,
        [string]$Site = '',
        [string]$Source = '',
        [string]$ProjectDir = '',
        [switch]$LocalOnly
    )
    $paths = Get-NtInventoryPaths -ProjectDir $ProjectDir -Site $Site
    $written = [System.Collections.Generic.List[string]]::new()
    $result = $null

    foreach ($p in @($paths.Local, $paths.Project)) {
        if (-not $p) { continue }
        if ($LocalOnly -and $p -eq $paths.Project) { continue }
        $inv = Read-NtJsonFile -Path $p
        if (-not $inv) { $inv = New-NtInventory }
        $merged = Merge-NtInventory -Inventory $inv -Hosts $Hosts -Site $Site -Source $Source
        if (Write-NtJsonFile -Path $p -Object $merged -Depth 10) { $written.Add($p) }
        if (-not $result) { $result = $merged }
    }

    [pscustomobject]@{
        Written   = [object[]]@($written)
        Inventory = $result
        Summary   = $(if ($result) { $result.lastMerge } else { $null })
    }
}

function Get-NtInventoryMatches {
    # Cross-match findings. This is the payoff for keeping the history: a single
    # scan cannot tell you that the edge router was swapped, and two scans can.
    param($Inventory, $CurrentHosts = @())
    if (-not $Inventory) { return @() }
    $out = [System.Collections.Generic.List[object]]::new()

    # 1. Same IP, different MAC over time = the device at that address changed.
    $ipOwners = @{}
    foreach ($d in @($Inventory.devices)) {
        foreach ($x in @($d.ips)) {
            $key = ('{0}|{1}' -f $x.ip, $x.site)
            if (-not $ipOwners.ContainsKey($key)) { $ipOwners[$key] = [System.Collections.Generic.List[object]]::new() }
            $ipOwners[$key].Add([pscustomobject]@{ Device = $d; Seen = $x })
        }
    }
    foreach ($key in $ipOwners.Keys) {
        $owners = @($ipOwners[$key])
        if ($owners.Count -lt 2) { continue }
        $sorted = @($owners | Sort-Object { $_.Seen.lastSeenUtc } -Descending)
        $newest = $sorted[0]; $prev = $sorted[1]
        $parts = $key -split '\|'
        # "The hardware at that address changed", at HIGH severity, from two
        # observations of an IP-to-MAC pairing. A MAC is not a durable device
        # identity and an address is not owned by anything: DHCP hands the
        # same address to a different machine as a matter of routine, an HA
        # pair moves a virtual MAC between two chassis on failover, hypervisors
        # generate and regenerate MACs, and modern clients randomise them per
        # network by default. Every one of those produces this exact evidence
        # without any hardware being touched.
        #
        # So the OBSERVATION is reported - the pairing changed, which is true
        # and worth knowing - and the CONCLUSION is left to someone who can
        # check. Randomised MACs drop further still, because for them this is
        # the expected behaviour rather than a surprise.
        $randomised = ($newest.Device.locallyAdministered -or $prev.Device.locallyAdministered)
        $sevR = if ($randomised) { 'info' } else { 'medium' }
        $note = if ($randomised) {
            ' At least one of these MACs is locally administered, i.e. randomised - clients rotate those per network by design, so this is expected rather than notable.'
        } else {
            ' That is consistent with hardware being swapped, but equally with a DHCP lease moving to another machine, an HA pair failing over to its partner, or a virtual NIC being recreated. Check the lease and the switch port before concluding anything was replaced.'
        }
        $out.Add([pscustomobject]@{
            Kind    = 'DeviceAssociationChanged'
            Severity= $sevR
            Ip      = $parts[0]
            Site    = $parts[1]
            Summary = ('{0} is now answered by {1} ({2}), previously {3} ({4}).{5}' -f $parts[0], $newest.Device.macFormatted, $newest.Device.vendor, $prev.Device.macFormatted, $prev.Device.vendor, $note)
            Detail  = ('Last seen: {0} on {1}, {2} on {3}. This records an IP-to-MAC ASSOCIATION change observed across runs, not a verified device replacement.' -f $newest.Device.macFormatted, $newest.Seen.lastSeenUtc, $prev.Device.macFormatted, $prev.Seen.lastSeenUtc)
        })
    }

    # 2. One device on several addresses = moved, dual-homed, or DHCP churn.
    foreach ($d in @($Inventory.devices)) {
        $ips = @($d.ips)
        if ($ips.Count -lt 2) { continue }
        $sev = if ($d.locallyAdministered) { 'info' } else { 'medium' }
        $note = if ($d.locallyAdministered) { ' The MAC is locally administered (randomised), so multiple addresses are expected.' } else { '' }
        $out.Add([pscustomobject]@{
            Kind    = 'DeviceMoved'
            Severity= $sev
            Mac     = $d.macFormatted
            Summary = ('{0} ({1}) has held {2} addresses: {3}.{4}' -f $d.macFormatted, $d.vendor, $ips.Count, ((@($ips | Sort-Object lastSeenUtc -Descending | Select-Object -First 5) | ForEach-Object { $_.ip }) -join ', '), $note)
            Detail  = ('First seen {0}, last seen {1}.' -f $d.firstSeenUtc, $d.lastSeenUtc)
        })
    }

    # 3. One device seen at more than one site = a roaming laptop, or two sites
    #    sharing an address range and the inventory conflating them.
    foreach ($d in @($Inventory.devices)) {
        $sites = @($d.sites | Where-Object { $_ })
        if ($sites.Count -lt 2) { continue }
        $out.Add([pscustomobject]@{
            Kind    = 'MultiSite'
            Severity= 'info'
            Mac     = $d.macFormatted
            Summary = ('{0} ({1}) has been seen at {2} sites: {3}.' -f $d.macFormatted, $d.vendor, $sites.Count, ($sites -join ', '))
            Detail  = 'Normal for a laptop. If it is meant to be fixed infrastructure, the site labels are wrong or two sites reuse the same addresses.'
        })
    }

    # 4. Same MAC on two addresses in the CURRENT scan = live duplicate.
    if (@($CurrentHosts).Count -gt 0) {
        $macNow = @{}
        foreach ($h in @($CurrentHosts)) {
            $m = ConvertTo-NtNormalMac ([string]$h.Mac)
            if (-not $m) { continue }
            if (-not $macNow.ContainsKey($m)) { $macNow[$m] = [System.Collections.Generic.List[string]]::new() }
            $macNow[$m].Add([string]$h.IP)
        }
        foreach ($m in $macNow.Keys) {
            $ips = @($macNow[$m])
            if ($ips.Count -lt 2) { continue }
            $la = Test-NtLocallyAdministered $m
            $out.Add([pscustomobject]@{
                Kind    = 'LiveDuplicateMac'
                Severity= $(if ($la) { 'info' } else { 'medium' })
                Mac     = (Format-NtMac $m)
                Summary = ('{0} is answering for {1} addresses right now: {2}.' -f (Format-NtMac $m), $ips.Count, ($ips -join ', '))
                Detail  = $(if ($la) { 'Locally administered MAC - expected behaviour for a randomising device.' } else { 'A burned-in MAC on several live addresses is usually a router doing proxy ARP, or a genuine address conflict.' })
            })
        }
    }

    $rank = @{ 'high' = 0; 'medium' = 1; 'info' = 2 }
    return @(@($out) | Sort-Object { [int]$rank[[string]$_.Severity] })
}

# =============================================================================
# 14. Baselines - routes and traceroutes, then and now
# =============================================================================
# Runbook Trap 1: the question that should have been asked in the first five
# minutes was "when did this last work?". A saved baseline turns that from a
# memory test into a diff.

function Get-NtBaselinePath {
    # Keyed by site AND the machine that captured it.
    #
    # One file per site meant the second PC to press Save overwrote the first,
    # and a comparison then diffed this machine's routes against another
    # machine's - which produces differences that are real, meaningless, and
    # indistinguishable from a fault. A laptop and a desktop at one site do
    # not have the same route table and never did.
    param([string]$Site = 'default', [string]$ProjectDir = '', [string]$Computer = '')
    $dir = Join-Path (Get-NtProjectDir -Hint $ProjectDir) 'baselines'
    $siteKey = (($Site -replace '[^\w\-\.]', '_').ToLower())
    if (-not $Computer) { $Computer = $env:COMPUTERNAME }
    $pcKey = (([string]$Computer -replace '[^\w\-\.]', '_').ToLower())
    return (Join-Path $dir ('{0}__{1}.json' -f $siteKey, $pcKey))
}

function Get-NtBaselineLegacyPath {
    # The pre-per-machine filename, still read so existing baselines are not
    # orphaned by the change above.
    param([string]$Site = 'default', [string]$ProjectDir = '')
    $dir = Join-Path (Get-NtProjectDir -Hint $ProjectDir) 'baselines'
    return (Join-Path $dir ('{0}.json' -f (($Site -replace '[^\w\-\.]', '_').ToLower())))
}

function Save-NtBaseline {
    # Snapshots the route table and, optionally, the path to each named target.
    param(
        [string]$Site = 'default',
        [string[]]$TraceTargets = @(),
        [string]$ProjectDir = '',
        [string]$Note = '',
        [int]$MaxHops = 20,
        $Shared = $null
    )
    $table = Get-NtRouteTable
    $ctx = Get-NtLocalContext

    $routes = [System.Collections.Generic.List[object]]::new()
    foreach ($r in @($table.Active)) {
        if ($r.DestinationPrefix -match '^(224\.|255\.255\.255\.255|127\.)') { continue }
        if ($r.DestinationPrefix -match '/32$' -and $r.NextHop -eq '0.0.0.0') { continue }
        $persist = $false
        foreach ($p in @($table.Persistent)) {
            if ($p.DestinationPrefix -eq $r.DestinationPrefix -and $p.NextHop -eq $r.NextHop) { $persist = $true; break }
        }
        $routes.Add([pscustomobject]@{
            prefix     = [string]$r.DestinationPrefix
            nextHop    = [string]$r.NextHop
            ifAlias    = [string]$r.InterfaceAlias
            metric     = [int]$r.RouteMetric
            persistent = $persist
        })
    }

    $traces = [System.Collections.Generic.List[object]]::new()
    foreach ($t in @($TraceTargets | Where-Object { $_ })) {
        if ($Shared -and $Shared.Cancel) { break }
        $tr = Invoke-NtTraceroute -Target $t -MaxHops $MaxHops -ProbesPerHop 2 -Shared $Shared
        $hops = @(@($tr.Hops) | ForEach-Object {
            [pscustomobject]@{ hop = [int]$_.Hop; address = [string]$_.Address; avgMs = [double]$_.AvgMs }
        })
        $traces.Add([pscustomobject]@{
            target  = [string]$t
            reached = [bool]$tr.Reached
            hops    = [object[]]$hops
        })
    }

    $baseline = [pscustomobject]@{
        schema       = 'nettoolkit-baseline/1'
        site         = $Site
        savedUtc     = (ConvertTo-NtIso8601 (Get-Date))
        savedBy      = $env:USERNAME
        savedOn      = $env:COMPUTERNAME
        note         = $Note
        localPrefixes= [object[]]@($ctx.ConnectedPrefixes)
        gateway      = (Get-NtPrimaryGateway -Context $ctx)
        routes       = [object[]]@($routes)
        traces       = [object[]]@($traces)
    }

    $path = Get-NtBaselinePath -Site $Site -ProjectDir $ProjectDir
    $ok = Write-NtJsonFile -Path $path -Object $baseline -Depth 8
    $reason = ''
    if (-not $ok) {
        $reason = ('Could not write the baseline to {0}. Check that the folder exists and is writable - on a locked-down machine ProgramData or the project folder may not be.' -f $path)
    }
    return [pscustomobject]@{ Ok = $ok; Path = $path; Reason = $reason; Baseline = $baseline }
}

function Compare-NtBaseline {
    # Diffs the saved snapshot against now. Route changes answer "what appeared
    # since this last worked"; trace changes answer "where did the path move".
    param(
        [string]$Site = 'default',
        [string]$ProjectDir = '',
        $Baseline = $null,
        [string[]]$TraceTargets = @(),
        [int]$MaxHops = 20,
        $Shared = $null
    )
    $path = Get-NtBaselinePath -Site $Site -ProjectDir $ProjectDir
    if (-not $Baseline) { $Baseline = Read-NtJsonFile -Path $path }
    if (-not $Baseline) {
        # Older baselines were written per-site rather than per-machine.
        $legacy = Get-NtBaselineLegacyPath -Site $Site -ProjectDir $ProjectDir
        $Baseline = Read-NtJsonFile -Path $legacy
        if ($Baseline) { $path = $legacy }
    }
    if (-not $Baseline) {
        return (New-NtSection -Name 'Baseline comparison' -State 'skipped' -Reason ('No baseline has been saved for site "{0}" from {1} yet ({2}). Save one while things are known good - and save it from the machine you intend to compare against.' -f $Site, $env:COMPUTERNAME, $path))
    }
    # Comparing this machine's routes against another machine's produces
    # differences that are real, meaningless, and look exactly like a fault.
    $contextCaveats = [System.Collections.Generic.List[string]]::new()
    if ($Baseline.savedOn -and ([string]$Baseline.savedOn -ne $env:COMPUTERNAME)) {
        $contextCaveats.Add(('This baseline was captured on {0}, and this is {1}. Two machines do not have the same route table, so differences below may simply be the difference between the two PCs rather than a change over time.' -f $Baseline.savedOn, $env:COMPUTERNAME))
    }
    $nowGw = ''
    try { $nowGw = [string](Get-NtPrimaryGateway -Context (Get-NtLocalContext)) } catch { }
    if ($Baseline.gateway -and $nowGw -and ([string]$Baseline.gateway -ne $nowGw)) {
        $contextCaveats.Add(('The baseline was captured behind gateway {0} and this machine is now behind {1}. It may be on a different network entirely, which makes a route diff meaningless.' -f $Baseline.gateway, $nowGw))
    }

    $rows = [System.Collections.Generic.List[object]]::new()
    $table = Get-NtRouteTable

    $nowRoutes = @{}
    foreach ($r in @($table.Active)) {
        if ($r.DestinationPrefix -match '^(224\.|255\.255\.255\.255|127\.)') { continue }
        if ($r.DestinationPrefix -match '/32$' -and $r.NextHop -eq '0.0.0.0') { continue }
        $nowRoutes[('{0}|{1}' -f $r.DestinationPrefix, $r.NextHop)] = $r
    }
    $thenRoutes = @{}
    foreach ($r in @($Baseline.routes)) {
        $thenRoutes[('{0}|{1}' -f $r.prefix, $r.nextHop)] = $r
    }

    $added = 0; $removed = 0
    foreach ($k in $nowRoutes.Keys) {
        if ($thenRoutes.ContainsKey($k)) { continue }
        $r = $nowRoutes[$k]
        $added++
        $rows.Add((New-NtRow -Group 'Route diff' -Check ('{0} via {1}' -f $r.DestinationPrefix, $r.NextHop) -Result 'ADDED since baseline' -Status 'warn' -Detail ('This route did not exist when the baseline was saved on {0}. If the fault started after that date, start here.' -f $Baseline.savedUtc) -Data $r))
    }
    foreach ($k in $thenRoutes.Keys) {
        if ($nowRoutes.ContainsKey($k)) { continue }
        $r = $thenRoutes[$k]
        $removed++
        $rows.Add((New-NtRow -Group 'Route diff' -Check ('{0} via {1}' -f $r.prefix, $r.nextHop) -Result 'REMOVED since baseline' -Status 'warn' -Detail 'This route existed at baseline time and is gone now.' -Data $r))
    }
    if ($added -eq 0 -and $removed -eq 0) {
        $rows.Add((New-NtRow -Group 'Route diff' -Check 'Route table' -Result 'Unchanged' -Status 'ok' -Detail ('Identical to the baseline saved {0}.' -f $Baseline.savedUtc)))
    }

    # Trace comparison, for whichever targets the baseline holds.
    $targets = @($TraceTargets | Where-Object { $_ })
    if ($targets.Count -eq 0) { $targets = @(@($Baseline.traces) | ForEach-Object { [string]$_.target }) }
    $traceDiffs = [System.Collections.Generic.List[object]]::new()

    foreach ($t in $targets) {
        if ($Shared -and $Shared.Cancel) { break }
        $old = @(@($Baseline.traces) | Where-Object { $_.target -eq $t } | Select-Object -First 1)
        if ($old.Count -eq 0) { continue }
        $new = Invoke-NtTraceroute -Target $t -MaxHops $MaxHops -ProbesPerHop 2 -Shared $Shared

        $oldHops = @($old[0].hops)
        $newHops = @($new.Hops)
        $max = [math]::Max($oldHops.Count, $newHops.Count)
        $changed = 0
        $detail = [System.Collections.Generic.List[string]]::new()

        for ($i = 0; $i -lt $max; $i++) {
            $o = if ($i -lt $oldHops.Count) { [string]$oldHops[$i].address } else { '' }
            $n = if ($i -lt $newHops.Count) { [string]$newHops[$i].Address } else { '' }
            if ($o -eq $n) { continue }
            # A hop that was silent then and silent now is not a change.
            if (-not $o -and -not $n) { continue }
            $changed++
            $detail.Add(('hop {0}: was {1}, now {2}' -f ($i + 1), $(if ($o) { $o } else { 'no reply' }), $(if ($n) { $n } else { 'no reply' })))
        }

        if ($changed -eq 0) {
            $rows.Add((New-NtRow -Group 'Path diff' -Check $t -Result 'Path unchanged' -Status 'ok' -Detail ('{0} hops, same addresses as the baseline.' -f $newHops.Count)))
        } else {
            $rows.Add((New-NtRow -Group 'Path diff' -Check $t -Result ('{0} hop(s) differ' -f $changed) -Status 'warn' -Detail ($detail -join '; ')))
        }
        $traceDiffs.Add([pscustomobject]@{ target = $t; changed = $changed; details = [object[]]@($detail) })
    }

    $data = [pscustomobject]@{
        BaselinePath = $path
        SavedUtc     = [string]$Baseline.savedUtc
        RoutesAdded  = $added
        RoutesRemoved= $removed
        TraceDiffs   = [object[]]@($traceDiffs)
    }
    return (New-NtSection -Name 'Baseline comparison' -State 'measured' `
        -Method ('Compared against the baseline saved for site "{0}" on {1} by {2}.' -f $Site, $Baseline.savedUtc, $(if ($Baseline.savedOn) { $Baseline.savedOn } else { 'an unrecorded machine' })) `
        -Caveats @($contextCaveats.ToArray()) -Rows @($rows) -Data $data)
}

# =============================================================================
# 15. Site profiles
# =============================================================================
# Runbook tooling item C: a small per-site file so the triage can be run by
# anyone, without them having to know the site's transport, its known-good peer,
# or which addresses are translated.

function Get-NtProfileDir {
    param([string]$ProjectDir = '')
    return (Join-Path (Get-NtProjectDir -Hint $ProjectDir) 'profiles')
}

function Get-NtSiteProfileList {
    param([string]$ProjectDir = '')
    $dir = Get-NtProfileDir -ProjectDir $ProjectDir
    if (-not (Test-Path -LiteralPath $dir)) { return @() }
    $out = [System.Collections.Generic.List[object]]::new()
    foreach ($f in @(Get-ChildItem -LiteralPath $dir -Filter '*.json' -ErrorAction SilentlyContinue)) {
        if ($f.BaseName -like '_*') { continue }   # _template.json and friends
        $p = Read-NtJsonFile -Path $f.FullName
        if (-not $p) { continue }
        $p | Add-Member -NotePropertyName _path -NotePropertyValue $f.FullName -Force
        $out.Add($p)
    }
    return @($out)
}

function Get-NtSiteProfile {
    # By name, or by matching this machine's connected subnets against each
    # profile's lanSubnets. Auto-selection is what makes the tool usable by
    # someone who has never seen the site before.
    param(
        [string]$Name = '',
        [string]$ProjectDir = '',
        $Context = $null
    )
    $all = @(Get-NtSiteProfileList -ProjectDir $ProjectDir)
    if ($all.Count -eq 0) { return $null }

    if ($Name) {
        foreach ($p in $all) {
            if ([string]$p.site -eq $Name) { return $p }
            if ([IO.Path]::GetFileNameWithoutExtension([string]$p._path) -eq $Name) { return $p }
        }
        return $null
    }

    if (-not $Context) { $Context = Get-NtLocalContext }
    foreach ($p in $all) {
        foreach ($subnet in @($p.lanSubnets)) {
            foreach ($a in @($Context.Adapters)) {
                foreach ($addr in @($a.Addresses)) {
                    if (Test-NtIpInPrefix -IPAddress ([string]$addr.IPAddress) -Prefix ([string]$subnet)) {
                        return $p
                    }
                }
            }
        }
    }
    return $null
}

function Get-NtProfileCaveats {
    # A site profile is a set of STATED FACTS, not measurements, and some of
    # them are explicitly flagged as guesses. The convention in these files is
    # a "_<field>" key holding commentary about "<field>" - and the original
    # case's site profile says, in as many words, that its application port is
    # UNCONFIRMED. None of that reached the operator, so an assumption was
    # presented with exactly the same authority as a measurement.
    param($Profile)
    $out = [System.Collections.Generic.List[object]]::new()
    if (-not $Profile) { return $out.ToArray() }

    $walk = {
        param($Node, [string]$Path)
        if ($null -eq $Node) { return }
        if ($Node -is [System.Management.Automation.PSCustomObject]) {
            foreach ($prop in $Node.PSObject.Properties) {
                $name = [string]$prop.Name
                if ($name -like '_*' -and $name -ne '_readme') {
                    foreach ($line in @($prop.Value)) {
                        $text = [string]$line
                        if (-not $text) { continue }
                        $out.Add([pscustomobject]@{
                            Field       = ('{0}{1}' -f $Path, $name.TrimStart('_'))
                            Note        = $text
                            # The file's OWN convention is the literal word
                            # UNCONFIRMED - see the _readme in the shipped
                            # profile. Matching loosely on 'assum' flagged a
                            # note reading "Assuming IPsec cost real time on
                            # the original case", which describes a past
                            # mistake rather than declaring this value a
                            # guess. A caveat system that cries wolf gets
                            # ignored, which costs more than it saves.
                            Unconfirmed = [bool]($text -match '(?i)\bunconfirmed\b|\bnot stated\b|\bnot recorded\b')
                        })
                    }
                } elseif ($prop.Value -is [System.Management.Automation.PSCustomObject] -or $prop.Value -is [System.Object[]]) {
                    foreach ($child in @($prop.Value)) {
                        & $walk $child ('{0}{1}.' -f $Path, $name)
                    }
                }
            }
        }
    }
    & $walk $Profile ''
    return $out.ToArray()
}

function Test-NtSiteProfile {
    # Validates a profile and says what is missing. A profile with no peer is
    # still useful; a profile with a malformed subnet is a trap.
    param($Profile)
    $problems = [System.Collections.Generic.List[string]]::new()
    $warnings = [System.Collections.Generic.List[string]]::new()

    if (-not $Profile) {
        $problems.Add('No profile supplied.')
        return [pscustomobject]@{ Ok = $false; Problems = [object[]]@($problems); Warnings = @() }
    }
    if (-not $Profile.site) { $problems.Add('site is missing.') }
    foreach ($s in @($Profile.lanSubnets)) {
        if ($s -notmatch '^\d+\.\d+\.\d+\.\d+/\d+$') { $problems.Add(('lanSubnets entry "{0}" is not CIDR notation.' -f $s)) }
    }
    if ($Profile.gateway -and -not (Test-NtIsIPv4 ([string]$Profile.gateway))) { $problems.Add(('gateway "{0}" is not an IPv4 address.' -f $Profile.gateway)) }
    if (@($Profile.targets).Count -eq 0) { $warnings.Add('No targets defined - you will have to type the destination each time.') }
    foreach ($t in @($Profile.targets)) {
        if (-not $t.ip) { $problems.Add('A target has no ip.') }
        if (-not $t.peer) { $warnings.Add(('Target {0} has no neighbour listed. One is searched for automatically, but a known-working machine on the same network is the better control.' -f $t.ip)) }
    }
    if (-not $Profile.transport -or -not $Profile.transport.nextHop) {
        $warnings.Add('No transport.nextHop - the handoff to the inter-site transport cannot be tested separately.')
    }
    [pscustomobject]@{
        Ok       = (@($problems).Count -eq 0)
        Problems = [object[]]@($problems)
        Warnings = [object[]]@($warnings)
    }
}

# =============================================================================
# 16. Escalation summary
# =============================================================================
# Runbook tooling item D. The pattern that worked on the real case: state what
# you PROVED works, with numbers; state the single thing that does not; give the
# last known-good date; ask specific questions. Leading with proof pre-empts the
# reflexive "must be your network".

function New-NtEscalationSummary {
    param(
        $Report,
        [string]$LastKnownGood = '',
        [string]$TicketRef = '',
        [string]$ContactNote = ''
    )
    if (-not $Report) { return '' }
    $sb = [System.Text.StringBuilder]::new()
    $nl = [Environment]::NewLine

    $add = {
        param([string]$Text = '')
        [void]$sb.AppendLine($Text)
    }

    & $add ('INTER-SITE REACHABILITY - DEMARCATION SUMMARY')
    & $add ('=============================================')
    & $add ''
    if ($TicketRef) { & $add ('Ticket        : {0}' -f $TicketRef) }
    & $add ('Site          : {0}' -f $(if ($Report.site) { $Report.site } else { 'not specified' }))
    & $add ('Tested from   : {0} ({1})' -f $Report.computerName, $(
        $ep = @($Report.sections | Where-Object { $_.name -eq 'Endpoint' } | Select-Object -First 1)
        if ($ep.Count -gt 0) { (@($ep[0].data.ConnectedPrefixes) -join ', ') } else { 'unknown' }
    ))
    & $add ('Destination   : {0}' -f $Report.target)
    # Which device, at which address, and how that address was established -
    # the far end needs to know the name was not simply trusted.
    if ($Report.device) {
        $idn = $Report.identity
        $how = ''
        if ($idn -and $idn.ChosenAddress) {
            $cc = @(@($idn.Candidates) | Where-Object { $_.Address -eq $idn.ChosenAddress } | Select-Object -First 1)
            if ($cc.Count -gt 0) { $how = (' - address from {0}' -f (@($cc[0].Sources) -join ', ')) }
            if ($idn.MacFormatted) { $how += (', MAC {0}' -f $idn.MacFormatted) }
        }
        & $add ('Device        : {0}{1}' -f $Report.device.Headline, $how)
    }
    & $add ('Tested at     : {0}' -f $Report.generatedUtc)
    if ($LastKnownGood) { & $add ('Last known good: {0}' -f $LastKnownGood) }
    & $add ''

    # --- What is proven to work -------------------------------------------
    & $add 'PROVEN WORKING'
    & $add '--------------'
    $proven = [System.Collections.Generic.List[string]]::new()

    $ep = @($Report.sections | Where-Object { $_.name -eq 'Endpoint' } | Select-Object -First 1)
    $gw = @($Report.sections | Where-Object { $_.name -eq 'Gateway' } | Select-Object -First 1)
    if ($gw.Count -gt 0 -and $gw[0].data) {
        $g = $gw[0].data
        if ($g.Mac) { $proven.Add(('Local segment: the gateway {0} answers ARP as {1} ({2}).' -f $g.Gateway, (Format-NtMac $g.Mac), $g.Vendor)) }
        if ($g.Icmp -and $g.Icmp.Success) {
            $proven.Add(('Gateway ICMP: {0}/{1} replies, {2} ms average, TTL {3}.' -f $g.Icmp.Received, $g.Icmp.Sent, [math]::Round($g.Icmp.Rtt.Mean,1), ($g.Icmp.Ttls -join '/')))
        }
        if (@($g.OpenPorts).Count -gt 0) {
            $proven.Add(('Gateway management plane: TCP {0} open.' -f ((@($g.OpenPorts) | ForEach-Object { $_.Port }) -join ', ')))
        }
    }

    $ladder = @($Report.ladder)
    $r4 = @($ladder | Where-Object { $_.number -eq 4 -and $_.status -eq 'ok' })
    if ($r4.Count -gt 0) { $proven.Add(('Transport handoff: {0}' -f $r4[0].result)) }
    $r5 = @($ladder | Where-Object { $_.number -eq 5 -and $_.status -eq 'ok' })
    if ($r5.Count -gt 0) {
        $proven.Add(('A DIFFERENT host on the destination subnet is reachable from here: {0}. This proves the prefix is carried across the transport AND that a return path exists for our source address.' -f $r5[0].result))
    }

    $sel = @($Report.sections | Where-Object { $_.name -eq 'Selected route' } | Select-Object -First 1)
    if ($sel.Count -gt 0 -and $sel[0].data -and $sel[0].data.SourceAddress) {
        $proven.Add(('Traffic leaves this machine sourced from {0} via {1}.' -f $sel[0].data.SourceAddress, $sel[0].data.NextHop))
    }

    if ($proven.Count -eq 0) { & $add '  (nothing above the local endpoint could be proven)' }
    foreach ($p in $proven) { & $add ('  * {0}' -f $p) }
    & $add ''

    # --- The single thing that does not work ------------------------------
    & $add 'NOT WORKING'
    & $add '-----------'
    $tgt = @($Report.sections | Where-Object { $_.name -eq 'Target' } | Select-Object -First 1)
    if ($tgt.Count -gt 0 -and $tgt[0].data) {
        $t = $tgt[0].data
        if ($t.Icmp -and -not $t.Icmp.Success) {
            $probeWord = if ([int]$t.Icmp.Sent -eq 1) { 'probe' } else { 'probes' }
            & $add ('  * {0} does not answer ICMP ({1} {2} sent, none returned).' -f $t.Target, $t.Icmp.Sent, $probeWord)
        }
        $closed = @()
        foreach ($p in @($t.Probed)) {
            $hit = @(@($t.OpenPorts) | Where-Object { $_.Port -eq [int]$p })
            if ($hit.Count -eq 0) { $closed += $p }
        }
        if ($closed.Count -gt 0) { & $add ('  * {0} does not accept TCP on {1}.' -f $t.Target, ($closed -join ', ')) }
        if (@($t.OpenPorts).Count -gt 0) { & $add ('  * (TCP {0} IS open - the service is partially reachable.)' -f ((@($t.OpenPorts) | ForEach-Object { $_.Port }) -join ', ')) }
    }

    $path = @($Report.sections | Where-Object { $_.name -eq 'Path' } | Select-Object -First 1)
    if ($path.Count -gt 0 -and $path[0].data) {
        $last = Get-NtLastRespondingHop -Trace $path[0].data
        if ($last -and -not $path[0].data.Reached) {
            & $add ('  * The trace stops getting replies after {0} at hop {1}. That is the last hop that ANSWERED,' -f $last.Address, $last.Hop)
            & $add '    which is not the same as where the traffic stops - many routers forward while'
            & $add '    declining to answer TTL-expiry, and tunnels hide their interior hops entirely.'
        }
    }
    & $add ''

    # --- What has been eliminated -----------------------------------------
    # An elimination that is never written down gets re-checked by the next
    # person, or quietly assumed to still be open. Both waste the same hours.
    $ruledOut = [System.Collections.Generic.List[string]]::new()
    foreach ($finding in @($Report.findings | Where-Object { $_.severity -eq 'info' })) {
        if ($finding.title -like '*ruled out*' -or $finding.title -like '*not a factor*') {
            $ruledOut.Add([string]$finding.summary)
        }
    }
    $diff = @($Report.sections | Where-Object { $_.name -eq 'Target vs peer' } | Select-Object -First 1)
    if ($diff.Count -gt 0 -and $diff[0].data) {
        if ($diff[0].data.RouteSame -and $diff[0].data.SourceSame) {
            $ruledOut.Add(('This workstation selects the same route and the same source address for {0} and {1}, so client-side routing is not the difference between them.' -f $Report.target, $Report.peer))
        }
    }
    if (@($Report.findings | Where-Object { $_.title -like 'Persistent routes present but not installed*' }).Count -gt 0) {
        $ruledOut.Add('The persistent routes on this machine are not installed in the active forwarding table, so they are not carrying traffic and are not the cause of the current fault.')
    }
    if ($ruledOut.Count -gt 0) {
        & $add 'RULED OUT'
        & $add '---------'
        foreach ($item in $ruledOut) { & $add ('  * {0}' -f $item) }
        & $add ''
    }

    # --- Conclusions -------------------------------------------------------
    & $add 'ASSESSMENT'
    & $add '----------'
    foreach ($f in @($Report.findings | Where-Object { $_.severity -in @('critical','high','medium') })) {
        & $add ('  [{0}] {1}' -f $f.severity.ToUpper(), $f.title)
        & $add ('      {0}' -f $f.summary)
    }
    if (@($Report.findings | Where-Object { $_.severity -in @('critical','high','medium') }).Count -eq 0) {
        & $add '  No fault could be localised from this endpoint.'
    }
    & $add ''

    # --- Specific questions ------------------------------------------------
    & $add 'QUESTIONS FOR THE FAR END / VENDOR'
    & $add '----------------------------------'
    $srcAddr = ''
    if ($sel.Count -gt 0 -and $sel[0].data) { $srcAddr = [string]$sel[0].data.SourceAddress }
    $peerAnswered = (@($ladder | Where-Object { $_.number -eq 5 -and $_.status -eq 'ok' }).Count -gt 0)
    $peerFailed   = (@($ladder | Where-Object { $_.number -eq 5 -and $_.status -eq 'fail' }).Count -gt 0)

    $q = [System.Collections.Generic.List[string]]::new()
    $q.Add(('What source address does {0} actually see for connections from us? If any device in the path performs source NAT, the return route it needs is for THAT address, not for our client subnet.' -f $Report.target))

    # Only claim the neighbour-answers contrast when a neighbour actually did.
    if ($peerAnswered) {
        $q.Add(('Does {0} have a return route covering {1}? A neighbouring host on the same subnet does - that is why it answers and this one does not.' -f $Report.target, $(if ($srcAddr) { $srcAddr } else { 'our source subnet' })))
        $q.Add('Is the host firewall on the target scoped to "Local subnet" for the relevant rule? That silently excludes every remote subnet.')
        $q.Add('Is the application bound to 0.0.0.0 or to one specific interface?')

        # The sharpest question available when a translation is known: the peer
        # is subject to the SAME NAT and answers anyway, so whatever it has,
        # the target is missing. Asking it this way usually gets a real answer
        # instead of "must be your network".
        $peerName = ''
        try { $peerName = [string]$Report.peer } catch {}
        if ($peerName -and $Report.profile -and $Report.profile.knownNat) {
            foreach ($nat in @($Report.profile.knownNat)) {
                $q.Add(('Why does {0} work despite the same source NAT to {1}? Does it already have a return route for {1}, or is it handled differently by the cloud network? Whatever it has, {2} appears to be missing.' -f $peerName, $nat.to, $Report.target))
            }
        }
    } elseif ($peerFailed) {
        $q.Add(('Is our subnet {0} advertised across the transport at all? Nothing on the destination subnet responds, not just this one host.' -f (@($Report.sections | Where-Object { $_.name -eq 'Endpoint' } | Select-Object -First 1).data.ConnectedPrefixes -join ', ')))
        $q.Add('Does a return route exist for our source address anywhere on the far side?')
    } else {
        $q.Add(('Does {0} have a return route covering {1}?' -f $Report.target, $(if ($srcAddr) { $srcAddr } else { 'our source subnet' })))
        $q.Add('Is the host firewall on the target scoped to "Local subnet" for the relevant rule? That silently excludes every remote subnet.')
    }
    if ($LastKnownGood) { $q.Add(('What changed on or around {0}? Config push, firmware, patching, GPO?' -f $LastKnownGood)) }
    else { $q.Add('When did this last work, and what changed in that window?') }
    $i = 1
    foreach ($item in $q) { & $add ('  {0}. {1}' -f $i, $item); $i++ }
    & $add ''

    # --- Commands to run on the edge device --------------------------------
    # The site profile's declared firewall beats live banner detection: the box
    # that performs the translation is often not the LAN default gateway, and a
    # profile is a stated fact where a banner is an inference.
    $appliance = ''
    if ($Report.profile -and $Report.profile.firewall -and $Report.profile.firewall.vendor) {
        $appliance = [string]$Report.profile.firewall.vendor
        if ($Report.profile.firewall.model) { $appliance = ('{0} {1}' -f $appliance, $Report.profile.firewall.model) }
    }
    if (-not $appliance -and $gw.Count -gt 0 -and $gw[0].data) { $appliance = [string]$gw[0].data.Appliance }
    & $add 'TO CONFIRM ON THE EDGE DEVICE'
    & $add '-----------------------------'
    foreach ($c in @(Get-NtVendorCommands -Appliance $appliance -Target $Report.target)) {
        & $add ('  {0}' -f $c)
    }
    & $add ''

    if ($ContactNote) {
        & $add 'NOTES'
        & $add '-----'
        & $add ('  {0}' -f $ContactNote)
        & $add ''
    }

    # Matched on the VPN title only. The old title string no longer exists, so
    # this would have silently stopped caveating an escalation that genuinely
    # needed it - a renamed finding taking a consumer with it.
    $vpnWarn = @($Report.findings | Where-Object { $_.title -like 'A VPN or overlay adapter is up*' })
    # Provisional only when the route to the target could have used it; when
    # the selected route was measured to leave by another interface, say that.
    $vpnProvisional = @($vpnWarn | Where-Object { $_.severity -eq 'high' })
    if ($vpnProvisional.Count -gt 0) {
        & $add '!! CAVEAT: a VPN or overlay adapter was connected during this test, so these'
        & $add '!! results are provisional. Re-run with it disconnected before escalating.'
        & $add ''
    } elseif ($vpnWarn.Count -gt 0) {
        & $add '!! NOTE: a VPN or overlay adapter was connected during this test, but the route'
        & $add '!! to the target did not use it. Worth re-confirming with it disconnected.'
        & $add ''
    }

    & $add ('Generated by NetToolkit {0} on {1}.' -f (Get-NtVersion), $Report.generatedUtc)
    return $sb.ToString()
}

# =============================================================================
# 17. Remediation - opt-in only
# =============================================================================
# Nothing in this file changes the machine except this function, and it does
# nothing unless it is called with an explicit action list. Default runs are
# read-only, which is what makes the tool safe to point at customer kit.

function Invoke-NtRemediation {
    param(
        [ValidateSet('DeleteRoute','FlushArp','FlushDns','FlushNetbios','CommentHostsLine')]
        [string]$Action,
        [string]$Prefix = '',
        [string]$NextHop = '',
        [string]$IPAddress = '',
        [int]$LineNumber = 0,
        [string]$HostsPath = '',
        [switch]$Confirm
    )
    $result = [pscustomobject]@{
        Action    = $Action
        Ok        = $false
        Performed = $false
        Command   = ''
        Output    = ''
        Backup    = ''
        Message   = ''
    }

    if (-not $Confirm) {
        $result.Message = 'Refused: -Confirm was not supplied. This function never acts implicitly.'
        return $result
    }

    $needsAdmin = @('DeleteRoute','FlushArp','CommentHostsLine')
    if ($Action -in $needsAdmin -and -not (Test-NtElevated)) {
        $result.Message = ('Refused: {0} needs administrator rights and this process is not elevated.' -f $Action)
        return $result
    }

    switch ($Action) {
        'DeleteRoute' {
            if (-not $Prefix) { $result.Message = 'Refused: no prefix supplied.'; return $result }
            $cmd = ConvertTo-NtRouteDeleteCommand -DestinationPrefix $Prefix -NextHop $NextHop
            $result.Command = $cmd
            try {
                $args = @($cmd -split '\s+' | Select-Object -Skip 1)
                $out = & route.exe @args 2>&1 | Out-String
                $result.Output = $out.Trim()
                $result.Performed = $true
                $result.Ok = ($LASTEXITCODE -eq 0)
                if (-not $result.Ok) { $result.Message = ('route.exe exited {0}.' -f $LASTEXITCODE) }
            } catch {
                $result.Message = $_.Exception.Message
            }
        }
        'FlushArp' {
            $result.Command = $(if ($IPAddress) { ('Remove-NetNeighbor -IPAddress {0}' -f $IPAddress) } else { 'Remove-NetNeighbor (all IPv4)' })
            try {
                if ($IPAddress) { Remove-NetNeighbor -IPAddress $IPAddress -Confirm:$false -ErrorAction Stop }
                else { Remove-NetNeighbor -AddressFamily IPv4 -Confirm:$false -ErrorAction Stop }
                $result.Performed = $true; $result.Ok = $true
            } catch { $result.Message = $_.Exception.Message }
        }
        'FlushDns' {
            $result.Command = 'Clear-DnsClientCache'
            try { Clear-DnsClientCache -ErrorAction Stop; $result.Performed = $true; $result.Ok = $true }
            catch { $result.Message = $_.Exception.Message }
        }
        'FlushNetbios' {
            $result.Command = 'nbtstat -R'
            try {
                $out = & nbtstat.exe -R 2>&1 | Out-String
                $result.Output = $out.Trim(); $result.Performed = $true; $result.Ok = $true
            } catch { $result.Message = $_.Exception.Message }
        }
        'CommentHostsLine' {
            if ($LineNumber -le 0) { $result.Message = 'Refused: no line number supplied.'; return $result }
            $path = if ($HostsPath) { $HostsPath } else { Join-Path $env:SystemRoot 'System32\drivers\etc\hosts' }
            if (-not (Test-Path -LiteralPath $path)) { $result.Message = ('Refused: {0} does not exist.' -f $path); return $result }
            $result.Command = ('comment out line {0} of {1}' -f $LineNumber, $path)
            try {
                $lines = @(Get-Content -LiteralPath $path -ErrorAction Stop)
                if ($LineNumber -gt $lines.Count) { $result.Message = 'Refused: line number is past the end of the file.'; return $result }
                $existing = [string]$lines[$LineNumber - 1]
                if ($existing.TrimStart().StartsWith('#')) {
                    $result.Message = 'Nothing to do: that line is already commented out.'
                    $result.Ok = $true
                    return $result
                }
                # Back up before touching it, every time.
                $backup = ('{0}.nettoolkit-{1}.bak' -f $path, (Get-Date -Format 'yyyyMMdd-HHmmss'))
                Copy-Item -LiteralPath $path -Destination $backup -Force -ErrorAction Stop
                $result.Backup = $backup

                $lines[$LineNumber - 1] = ('# {0}   # commented out by NetToolkit {1}' -f $existing, (Get-Date -Format 'yyyy-MM-dd HH:mm'))
                Set-Content -LiteralPath $path -Value $lines -Encoding ASCII -ErrorAction Stop
                $result.Performed = $true; $result.Ok = $true
                $result.Output = ('was: {0}' -f $existing)
            } catch { $result.Message = $_.Exception.Message }
        }
    }
    return $result
}

# =============================================================================
# 18. A/B state capture - proving what a VPN actually changes
# =============================================================================
# The decisive experiment from the case notes, and the one thing a single
# snapshot can never answer.
#
# A persistent route that is not installed is harmless TODAY. The open question
# is whether Windows installs it when a VPN or another interface comes up - and
# the only way to find out is to look twice, with the state changed in between.
#
# The second thing this catches is subtler and was the actual mechanism in the
# original case: the VPN changed the SOURCE ADDRESS the far end saw, which is
# invisible in a route table diff unless you go looking for it.

function New-NtStateSnapshot {
    # Everything that can change when a link comes up or goes down, plus the
    # resolved path to each target of interest.
    param(
        [string[]]$Targets = @(),
        [string]$Label = '',
        $Shared = $null
    )
    if ($Shared) { $Shared.Status = ('Capturing state {0}...' -f $Label) }

    $table = Get-NtRouteTable
    $ctx   = Get-NtLocalContext
    $vpn   = Get-NtVpnIndicators

    $active = [System.Collections.Generic.List[object]]::new()
    foreach ($r in @($table.Active)) {
        $dp = [string]$r.DestinationPrefix
        if ($dp -match '^(224\.|255\.255\.255\.255|127\.)') { continue }
        if ($dp -match '/32$' -and $r.NextHop -eq '0.0.0.0') { continue }
        $active.Add([pscustomobject]@{
            prefix  = $dp
            nextHop = [string]$r.NextHop
            ifAlias = [string]$r.InterfaceAlias
            metric  = [int]$r.RouteMetric
        })
    }
    $persist = [System.Collections.Generic.List[object]]::new()
    foreach ($r in @($table.Persistent)) {
        $persist.Add([pscustomobject]@{
            prefix  = [string]$r.DestinationPrefix
            nextHop = [string]$r.NextHop
            ifAlias = [string]$r.InterfaceAlias
            metric  = [int]$r.RouteMetric
        })
    }

    $adapters = [System.Collections.Generic.List[object]]::new()
    foreach ($a in @($ctx.Adapters | Where-Object { $_.Status -eq 'Up' })) {
        $adapters.Add([pscustomobject]@{
            alias       = [string]$a.InterfaceAlias
            description = [string]$a.InterfaceDescription
            addresses   = [object[]]@(@($a.Addresses) | ForEach-Object { [string]$_.IPAddress })
        })
    }

    $tgt = [System.Collections.Generic.List[object]]::new()
    foreach ($t in @($Targets | Where-Object { $_ })) {
        if ($Shared -and $Shared.Cancel) { break }
        $sel = Resolve-NtSelectedRoute -Destination $t -RouteTable $table
        $tgt.Add([pscustomobject]@{
            target         = [string]$t
            resolved       = [bool]$sel.Resolved
            routePrefix    = [string]$sel.RoutePrefix
            nextHop        = [string]$sel.NextHop
            interfaceAlias = [string]$sel.InterfaceAlias
            sourceAddress  = [string]$sel.SourceAddress
            isDefaultRoute = [bool]$sel.IsDefaultRoute
            isPersistent   = [bool]$sel.IsPersistent
        })
    }

    [pscustomobject]@{
        schema           = 'nettoolkit-snapshot/1'
        label            = $Label
        capturedUtc      = (ConvertTo-NtIso8601 (Get-Date))
        computerName     = $env:COMPUTERNAME
        vpnSuspected     = [bool]$vpn.Suspected
        vpnAdapters      = [object[]]@($vpn.Adapters)
        vpnDetail        = [string]$vpn.Detail
        defaultRouteCount= @($ctx.DefaultRoutes).Count
        adapters         = [object[]]@($adapters)
        activeRoutes     = [object[]]@($active)
        persistentRoutes = [object[]]@($persist)
        targets          = [object[]]@($tgt)
    }
}

function Compare-NtStateSnapshot {
    # Rows are ordered by how much they PROVE, not by category. The first two
    # kinds are the ones that settle an argument; everything below is context.
    param($Before, $After)

    if (-not $Before -or -not $After) {
        return (New-NtSection -Name 'State comparison' -State 'skipped' -Reason 'Two snapshots are required. Capture A, change the VPN or link state, then capture B.')
    }

    $rows = [System.Collections.Generic.List[object]]::new()
    $proofs = [System.Collections.Generic.List[string]]::new()
    # Changes that are NOT a proof of causation but ARE changes. Route adds
    # and removals, metric moves, adapters appearing and the default-route
    # count all produced a ROW and nothing else, so the verdict beneath a
    # visible list of differences could still read "nothing changed".
    $otherChanges = [System.Collections.Generic.List[string]]::new()

    $beforeActive = @{}
    # Interface included, for the same reason as Get-NtRouteKey: two
    # interfaces routinely hold the same prefix via the same gateway.
    foreach ($r in @($Before.activeRoutes)) { $beforeActive[('{0}|{1}|{2}' -f $r.prefix, $r.nextHop, $r.ifAlias)] = $r }
    $afterActive = @{}
    foreach ($r in @($After.activeRoutes)) { $afterActive[('{0}|{1}|{2}' -f $r.prefix, $r.nextHop, $r.ifAlias)] = $r }

    # --- 1. Persistent routes that became ACTIVE. The smoking gun. ---------
    $beforePersist = @{}
    foreach ($r in @($Before.persistentRoutes)) { $beforePersist[('{0}|{1}|{2}' -f $r.prefix, $r.nextHop, $r.ifAlias)] = $r }

    $activated = 0
    foreach ($key in $afterActive.Keys) {
        if ($beforeActive.ContainsKey($key)) { continue }
        if (-not $beforePersist.ContainsKey($key)) { continue }
        $r = $afterActive[$key]
        $activated++
        $rows.Add((New-NtRow -Group 'State diff' -Check ('{0} via {1}' -f $r.prefix, $r.nextHop) -Result 'PERSISTENT ROUTE BECAME ACTIVE' -Status 'fail' -Detail ('This route existed only in the persistent store in snapshot "{0}" and is installed in the forwarding table in snapshot "{1}", on {2}. That is direct proof that the state change installs it and alters the path.' -f $Before.label, $After.label, $r.ifAlias) -Data $r))
    }
    if ($activated -gt 0) {
        $proofs.Add(('{0} persistent route(s) became active - the state change DOES install them.' -f $activated))
    }

    # --- 2. Source address changed. The mechanism nobody looks for. --------
    $srcChanged = 0
    foreach ($ta in @($After.targets)) {
        $tb = @(@($Before.targets) | Where-Object { $_.target -eq $ta.target } | Select-Object -First 1)
        if ($tb.Count -eq 0) { continue }
        if ([string]$tb[0].sourceAddress -eq [string]$ta.sourceAddress) { continue }
        $srcChanged++
        # What changed is the LOCAL source address. What the far end sees is
        # a different question: a source NAT anywhere along the path can map
        # both of these to one address, in which case the far end sees no
        # change at all. This asserted what a machine it has never contacted
        # can see.
        $rows.Add((New-NtRow -Group 'State diff' -Check ('Local source address for {0}' -f $ta.target) -Result ('{0}  ->  {1}' -f $tb[0].sourceAddress, $ta.sourceAddress) -Status 'warn' -Detail 'The address this machine will SEND FROM has changed. Whether the far end sees a different client depends on NAT along the path - if something translates both to one address, the far end sees no change at all. Where there is no translation, and the far end treats the two source networks differently (a firewall rule, an ACL, or a missing return route), that alone explains why one state works and the other does not. Confirm on the firewall which address actually arrives.' -Data $ta))
    }
    if ($srcChanged -gt 0) {
        $proofs.Add(('The LOCAL source address changed for {0} target(s). What the far end actually sees depends on NAT along the path and cannot be observed from this machine.' -f $srcChanged))
    }

    # --- 3. Selected route changed per target ------------------------------
    foreach ($ta in @($After.targets)) {
        $tb = @(@($Before.targets) | Where-Object { $_.target -eq $ta.target } | Select-Object -First 1)
        if ($tb.Count -eq 0) { continue }
        $b = $tb[0]
        if ([string]$b.routePrefix -eq [string]$ta.routePrefix -and [string]$b.nextHop -eq [string]$ta.nextHop) {
            $rows.Add((New-NtRow -Group 'State diff' -Check ('Route to {0}' -f $ta.target) -Result 'unchanged' -Status 'ok' -Detail ('Still {0} via {1} on {2}. The state change did not alter how this machine routes to this target.' -f $ta.routePrefix, $ta.nextHop, $ta.interfaceAlias)))
            continue
        }
        $rows.Add((New-NtRow -Group 'State diff' -Check ('Route to {0}' -f $ta.target) -Result ('{0} via {1}  ->  {2} via {3}' -f $b.routePrefix, $b.nextHop, $ta.routePrefix, $ta.nextHop) -Status 'fail' -Detail ('The selected route changed, and with it the interface ({0} -> {1}). This is the workstation choosing a different path, not the network behaving differently.' -f $b.interfaceAlias, $ta.interfaceAlias) -Data $ta))
        $proofs.Add(('The selected route to {0} changed.' -f $ta.target))
    }

    # --- 4. Any other route added or removed -------------------------------
    foreach ($key in $afterActive.Keys) {
        if ($beforeActive.ContainsKey($key)) { continue }
        if ($beforePersist.ContainsKey($key)) { continue }   # already reported above
        $r = $afterActive[$key]
        $rows.Add((New-NtRow -Group 'State diff' -Check ('{0} via {1}' -f $r.prefix, $r.nextHop) -Result 'route added' -Status 'warn' -Detail ('Appeared in the active table on {0}. It was not in the persistent store beforehand, so something installed it dynamically.' -f $r.ifAlias) -Data $r))
        $otherChanges.Add(('a route to {0} via {1} was added on {2}' -f $r.prefix, $r.nextHop, $r.ifAlias))
    }
    foreach ($key in $beforeActive.Keys) {
        if ($afterActive.ContainsKey($key)) { continue }
        $r = $beforeActive[$key]
        $rows.Add((New-NtRow -Group 'State diff' -Check ('{0} via {1}' -f $r.prefix, $r.nextHop) -Result 'route removed' -Status 'warn' -Detail ('Present in snapshot "{0}" and gone in "{1}".' -f $Before.label, $After.label) -Data $r))
        $otherChanges.Add(('the route to {0} via {1} was removed' -f $r.prefix, $r.nextHop))
    }

    # --- 4b. A route that stayed but changed METRIC ------------------------
    # Where two routes match one destination the metric decides which Windows
    # uses, so a metric move can shift traffic without anything being added or
    # removed. It was not compared at all.
    foreach ($key in $afterActive.Keys) {
        if (-not $beforeActive.ContainsKey($key)) { continue }
        $ra = $afterActive[$key]; $rb = $beforeActive[$key]
        if ([int]$ra.metric -eq [int]$rb.metric) { continue }
        $rows.Add((New-NtRow -Group 'State diff' -Check ('Metric for {0} via {1}' -f $ra.prefix, $ra.nextHop) -Result ('{0}  ->  {1}' -f $rb.metric, $ra.metric) -Status 'warn' -Detail 'The route is still present but its metric changed. Where two routes match the same destination, the metric decides which one Windows uses - so this can move traffic without any route being added or removed.' -Data $ra))
        $otherChanges.Add(('the metric on {0} via {1} changed from {2} to {3}' -f $ra.prefix, $ra.nextHop, $rb.metric, $ra.metric))
    }

    # --- 5. Adapters and default routes ------------------------------------
    $beforeAd = @{}
    foreach ($a in @($Before.adapters)) { $beforeAd[[string]$a.alias] = $a }
    $afterAd = @{}
    foreach ($a in @($After.adapters)) { $afterAd[[string]$a.alias] = $a }
    foreach ($alias in $afterAd.Keys) {
        if ($beforeAd.ContainsKey($alias)) { continue }
        $rows.Add((New-NtRow -Group 'State diff' -Check ('Adapter {0}' -f $alias) -Result 'came up' -Status 'info' -Detail ('{0} - {1}' -f $afterAd[$alias].description, ((@($afterAd[$alias].addresses)) -join ', '))))
        $otherChanges.Add(('the adapter "{0}" came up' -f $alias))
    }
    foreach ($alias in $beforeAd.Keys) {
        if ($afterAd.ContainsKey($alias)) { continue }
        $rows.Add((New-NtRow -Group 'State diff' -Check ('Adapter {0}' -f $alias) -Result 'went down' -Status 'info' -Detail ([string]$beforeAd[$alias].description)))
        $otherChanges.Add(('the adapter "{0}" went down' -f $alias))
    }
    if ([int]$Before.defaultRouteCount -ne [int]$After.defaultRouteCount) {
        $rows.Add((New-NtRow -Group 'State diff' -Check 'Default routes' -Result ('{0}  ->  {1}' -f $Before.defaultRouteCount, $After.defaultRouteCount) -Status 'warn' -Detail 'More than one default route means Windows is choosing between paths on metric alone, and the choice can change without warning.'))
        $otherChanges.Add(('the number of default routes changed from {0} to {1}' -f $Before.defaultRouteCount, $After.defaultRouteCount))
    }

    if ($rows.Count -eq 0) {
    if ($otherChanges.Count -gt 0 -and $proofs.Count -eq 0) {
        $rows.Add((New-NtRow -Group 'State diff' -Check 'Summary' -Result ('{0} change(s), none affecting a tested path' -f $otherChanges.Count) -Status 'warn' -Detail ('Configuration changed between the two captures: {0}. The selected route and source address for every tested target stayed the same, so none of it was shown to change how this machine reaches them.' -f ($otherChanges -join '; '))))
    }
        $rows.Add((New-NtRow -Group 'State diff' -Check 'Everything compared' -Result 'No differences' -Status 'ok' -Detail ('Routes, adapters, and the resolved path to every target are identical between "{0}" and "{1}". Whatever changed between the two captures, it did not change this machine routing.' -f $Before.label, $After.label)))
    }

    # Derived from EVERY comparison dimension. Driving it off $proofs alone
    # meant a capture listing added routes and an adapter coming up still
    # concluded that nothing had changed.
    if ($proofs.Count -gt 0) {
        $verdict = ($proofs -join ' ')
        if ($otherChanges.Count -gt 0) {
            $verdict += (' Also changed, without being shown to cause anything: {0}.' -f ($otherChanges -join '; '))
        }
    } elseif ($otherChanges.Count -gt 0) {
        # Configuration DID change - it just was not shown to affect the path
        # to any tested target. That distinction is the useful part.
        $verdict = ('The path this machine takes to every tested target is unchanged, but the configuration is not: {0}. None of that was shown to alter the route to a target, so treat it as context rather than cause.' -f ($otherChanges -join '; '))
    } else {
        $verdict = 'Nothing on this workstation changed between the two captures, so the difference in behaviour is not being produced here.'
    }

    $data = [pscustomobject]@{
        Before             = $Before
        After              = $After
        RoutesActivated    = $activated
        SourceChanged      = $srcChanged
        Proofs             = [object[]]@($proofs)
        OtherChanges       = [object[]]@($otherChanges.ToArray())
        AnyChange          = (($proofs.Count + $otherChanges.Count) -gt 0)
        Verdict            = $verdict
    }

    return (New-NtSection -Name 'State comparison' -State 'measured' -Method ('Snapshot "{0}" taken {1} compared with "{2}" taken {3}.' -f $Before.label, $Before.capturedUtc, $After.label, $After.capturedUtc) -Rows @($rows) -Data $data -Caveats @(
        'This compares THIS machine only. A change at the far end between the two captures would not appear here.',
        'Capture both snapshots close together, and change only one thing in between, or the comparison proves nothing.'
    ))
}

# =============================================================================
# 19. Current source - what this machine looks like from outside, right now
# =============================================================================
# The source address is the fact the whole inter-site case turned on, and it
# changes silently the moment a VPN connects. Having it on screen at all times
# costs one route lookup and removes a whole class of "which network am I on?"
# mistakes - particularly in a remote session, where there is nothing else to
# tell you.

function Get-NtCurrentSource {
    # Deliberately cheap enough to poll: one Find-NetRoute (about 40 ms), which
    # is authoritative because it reports the route Windows would actually
    # choose, plus one route-table read to spot a second default route.
    #
    # -InterfaceMap lets a caller pass a cached index->kind map so the adapter
    # cmdlets are not re-run on every poll.
    param(
        [string]$Probe = '1.1.1.1',
        $InterfaceMap = $null
    )
    $out = [pscustomobject]@{
        Ok             = $false
        Address        = ''
        InterfaceIndex = 0
        InterfaceAlias = ''
        Kind           = ''
        Gateway        = ''
        DefaultRoutes  = 0
        MultiPath      = $false
        OnLink         = $false
        Probe          = $Probe    # WHICH destination this describes
        Label          = 'no route'
    }

    try {
        $found = @(Find-NetRoute -RemoteIPAddress $Probe -ErrorAction Stop)
        foreach ($item in $found) {
            if ($item.PSObject.Properties.Match('IPAddress').Count -and $item.IPAddress) {
                $out.Address = [string]$item.IPAddress
            }
            if ($item.PSObject.Properties.Match('InterfaceIndex').Count -and $item.InterfaceIndex) {
                $out.InterfaceIndex = [int]$item.InterfaceIndex
            }
            if ($item.PSObject.Properties.Match('NextHop').Count -and $item.NextHop -and $item.NextHop -ne '0.0.0.0') {
                $out.Gateway = [string]$item.NextHop
            }
        }
    } catch {
        # No route at all - a genuine state worth showing rather than hiding.
        return $out
    }
    if (-not $out.Address) { return $out }

    try {
        $defaults = @(Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction Stop)
        $out.DefaultRoutes = $defaults.Count
        $out.MultiPath = ($defaults.Count -gt 1)
    } catch {}

    if ($InterfaceMap -and $InterfaceMap.ContainsKey($out.InterfaceIndex)) {
        $rec = $InterfaceMap[$out.InterfaceIndex]
        $out.InterfaceAlias = [string]$rec.InterfaceAlias
        $out.Kind           = [string]$rec.Kind
    } else {
        try {
            $adapter = Get-NetAdapter -InterfaceIndex $out.InterfaceIndex -ErrorAction Stop | Select-Object -First 1
            if ($adapter) {
                $out.InterfaceAlias = [string]$adapter.Name
                $out.Kind = Get-NtLinkKind -Alias ([string]$adapter.Name) -Description ([string]$adapter.InterfaceDescription) -InterfaceType ([int]$adapter.InterfaceType) -PhysicalMediaType ([string]$adapter.PhysicalMediaType)
            }
        } catch {}
    }
    if (-not $out.Kind) { $out.Kind = 'Other' }

    $out.Ok = $true
    # No next hop means the destination is on-link - delivered directly, with
    # the gateway not involved at all. Saying "via <gateway>" there is wrong.
    $out.OnLink = [string]::IsNullOrWhiteSpace($out.Gateway)
    $out.Label = ('{0} {1}' -f $out.Address, $out.Kind)
    if ($out.OnLink) { $out.Label += ' direct' }

    # '+VPN' used to be appended whenever a SECOND DEFAULT ROUTE existed,
    # regardless of whether any VPN was present - so a laptop with Ethernet
    # and Wi-Fi up permanently displayed "+VPN" in the window title. The
    # marker now means what it says; multiple paths get their own marker.
    if ($out.Kind -eq 'VPN') { $out.Label += ' +VPN' }
    elseif ($out.MultiPath) { $out.Label += (' +{0} paths' -f $out.DefaultRoutes) }
    return $out
}

function Get-NtInterfaceKindMap {
    # Small index -> alias/kind map for the title poller. Separate from
    # Get-NtInterfaceStateMap because that one pulls a full local context.
    param()
    $map = @{}
    try {
        foreach ($adapter in @(Get-NetAdapter -ErrorAction Stop)) {
            $map[[int]$adapter.InterfaceIndex] = [pscustomobject]@{
                InterfaceIndex = [int]$adapter.InterfaceIndex
                InterfaceAlias = [string]$adapter.Name
                Kind           = (Get-NtLinkKind -Alias ([string]$adapter.Name) -Description ([string]$adapter.InterfaceDescription) -InterfaceType ([int]$adapter.InterfaceType) -PhysicalMediaType ([string]$adapter.PhysicalMediaType))
            }
        }
    } catch {}
    return $map
}

# =============================================================================
# 20. Device targeting - find a device by name, IP or MAC
# =============================================================================
# A technician starts with a DEVICE: a name off a ticket, an address, a MAC
# label on the back of a box. The questions are the same every time - is it
# there, what is it, what address does it really have, and why can't I reach
# it?
#
# Windows answers "what address is NAME" with ONE result from ONE source, in
# precedence order, and the tool used to take that at face value. Measured on
# the development LAN with Tailscale up: ping resolved "desktop01" through
# Tailscale's DNS to 100.64.0.34 and timed out, while DESKTOP01 was sitting on
# the same Wi-Fi at 192.168.1.81 and would have answered for itself if asked.
# So everything below asks every source separately and says who answered.
#
# The multicast protocols matter because they are answered by the DEVICE
# ITSELF, with whatever address it holds right now - including a 169.254
# address when it never got a DHCP lease - and because Windows Firewall allows
# them on every profile while dropping ping. They are also complementary:
# on the same LAN, one Windows PC answered only LLMNR, a NAS answered only
# mDNS, and a third answered both. NetBIOS covers estates where LLMNR is
# switched off by Group Policy, which is common hardening.

function ConvertTo-NtDnsQuestion {
    # One DNS-format question. The same wire format serves DNS, mDNS and LLMNR.
    #
    # Returns a single byte[] via -NoEnumerate. Assign it directly; do NOT wrap
    # the call in @(), which would produce an array containing one array.
    param(
        [string]$Name,
        [int]$Type = 1,
        [int]$Id = 0,
        [switch]$UnicastResponse    # mDNS "QU" bit: ask for a unicast reply
    )
    $pkt = [System.Collections.Generic.List[byte]]::new()
    $pkt.Add([byte](($Id -shr 8) -band 0xFF)); $pkt.Add([byte]($Id -band 0xFF))
    $pkt.AddRange([byte[]](0,0, 0,1, 0,0, 0,0, 0,0))
    foreach ($label in $Name.TrimEnd('.').Split('.')) {
        if (-not $label) { continue }
        $b = [Text.Encoding]::UTF8.GetBytes($label)
        if ($b.Length -gt 63) { $b = [byte[]]$b[0..62] }
        $pkt.Add([byte]$b.Length)
        $pkt.AddRange([byte[]]$b)
    }
    $pkt.Add(0)
    $class = 1
    if ($UnicastResponse) { $class = $class -bor 0x8000 }
    $pkt.Add([byte](($Type -shr 8) -band 0xFF)); $pkt.Add([byte]($Type -band 0xFF))
    $pkt.Add([byte](($class -shr 8) -band 0xFF)); $pkt.Add([byte]($class -band 0xFF))
    Write-Output -NoEnumerate ($pkt.ToArray())
}

function Read-NtDnsName {
    # DNS name decoding, including message-compression pointers. Bounds-checked
    # throughout: these bytes come off the network from whoever chose to reply.
    param([byte[]]$Buffer, [ref]$Position)
    $labels = [System.Collections.Generic.List[string]]::new()
    $pos = [int]$Position.Value
    $jumped = $false
    $guard = 0
    while ($guard++ -lt 128 -and $pos -lt $Buffer.Length) {
        $len = [int]$Buffer[$pos]
        if ($len -eq 0) { $pos++; break }
        if (($len -band 0xC0) -eq 0xC0) {
            if ($pos + 1 -ge $Buffer.Length) { break }
            $ptr = (($len -band 0x3F) -shl 8) -bor [int]$Buffer[$pos + 1]
            if (-not $jumped) { $Position.Value = $pos + 2 }
            $jumped = $true
            if ($ptr -ge $Buffer.Length) { break }
            $pos = $ptr
            continue
        }
        if ($pos + 1 + $len -gt $Buffer.Length) { break }
        $labels.Add([Text.Encoding]::UTF8.GetString($Buffer, $pos + 1, $len))
        $pos += $len + 1
    }
    if (-not $jumped) { $Position.Value = $pos }
    return ($labels -join '.')
}

function Read-NtDnsRecords {
    # Every resource record in a DNS-format message: answers, authority and
    # additional. A and PTR records are decoded; the rest are skipped cleanly.
    param([byte[]]$Buffer)
    $records = [System.Collections.Generic.List[object]]::new()
    if (-not $Buffer -or $Buffer.Length -lt 12) { return @() }
    try {
        $qd = ([int]$Buffer[4] -shl 8) -bor $Buffer[5]
        $total = ((([int]$Buffer[6] -shl 8) -bor $Buffer[7]) +
                  (([int]$Buffer[8] -shl 8) -bor $Buffer[9]) +
                  (([int]$Buffer[10] -shl 8) -bor $Buffer[11]))
        $pos = 12
        for ($i = 0; $i -lt $qd -and $pos -lt $Buffer.Length; $i++) {
            [void](Read-NtDnsName $Buffer ([ref]$pos))
            $pos += 4
        }
        for ($i = 0; $i -lt $total -and $pos -lt $Buffer.Length; $i++) {
            $name = Read-NtDnsName $Buffer ([ref]$pos)
            if ($pos + 10 -gt $Buffer.Length) { break }
            $type  = ([int]$Buffer[$pos] -shl 8) -bor $Buffer[$pos + 1]
            $rdlen = ([int]$Buffer[$pos + 8] -shl 8) -bor $Buffer[$pos + 9]
            $rd = $pos + 10
            if ($rd + $rdlen -gt $Buffer.Length) { break }
            $address = ''
            $target = ''
            if ($type -eq 1 -and $rdlen -eq 4) {
                $address = ('{0}.{1}.{2}.{3}' -f $Buffer[$rd], $Buffer[$rd + 1], $Buffer[$rd + 2], $Buffer[$rd + 3])
            } elseif ($type -eq 12) {
                $tp = $rd
                $target = Read-NtDnsName $Buffer ([ref]$tp)
            }
            $records.Add([pscustomobject]@{ Name = $name; Type = $type; Address = $address; Target = $target })
            $pos = $rd + $rdlen
        }
    } catch { }
    return @($records)
}

function ConvertTo-NtNetbiosName {
    # NetBIOS first-level encoding: 16 bytes (name padded to 15 + a suffix
    # byte), each nibble written as 'A'+nibble. Returns a single byte[].
    param([string]$Name = '', [int]$Suffix = 0, [switch]$Wildcard)
    $raw = New-Object byte[] 16
    if ($Wildcard) {
        $raw[0] = 0x2A          # "*" and fifteen NULs: the node-status query
    } else {
        $n = $Name.ToUpperInvariant()
        if ($n.Length -gt 15) { $n = $n.Substring(0, 15) }
        $b = [Text.Encoding]::ASCII.GetBytes($n.PadRight(15))
        [Array]::Copy($b, $raw, 15)
        $raw[15] = [byte]$Suffix
    }
    $enc = New-Object byte[] 34
    $enc[0] = 0x20
    for ($i = 0; $i -lt 16; $i++) {
        $enc[1 + 2 * $i] = [byte](0x41 + (([int]$raw[$i] -shr 4) -band 0x0F))
        $enc[2 + 2 * $i] = [byte](0x41 + ([int]$raw[$i] -band 0x0F))
    }
    $enc[33] = 0
    Write-Output -NoEnumerate $enc
}

function New-NtNetbiosQuery {
    # NBNS name query (NB) or node-status query (NBSTAT). Returns one byte[].
    param([string]$Name = '', [int]$Id = 0, [switch]$NodeStatus, [switch]$Broadcast)
    $flags = 0x0000
    if (-not $NodeStatus) { $flags = 0x0100 }             # recursion desired
    if ($Broadcast) { $flags = $flags -bor 0x0010 }
    $pkt = [System.Collections.Generic.List[byte]]::new()
    $pkt.Add([byte](($Id -shr 8) -band 0xFF)); $pkt.Add([byte]($Id -band 0xFF))
    $pkt.Add([byte](($flags -shr 8) -band 0xFF)); $pkt.Add([byte]($flags -band 0xFF))
    $pkt.AddRange([byte[]](0,1, 0,0, 0,0, 0,0))
    if ($NodeStatus) { [byte[]]$enc = ConvertTo-NtNetbiosName -Wildcard }
    else { [byte[]]$enc = ConvertTo-NtNetbiosName -Name $Name -Suffix 0 }
    $pkt.AddRange($enc)
    $qtype = if ($NodeStatus) { 0x21 } else { 0x20 }
    $pkt.AddRange([byte[]](0, $qtype, 0, 1))
    Write-Output -NoEnumerate ($pkt.ToArray())
}

function Read-NtNetbiosAddresses {
    # Addresses from a positive NBNS name-query response.
    param([byte[]]$Buffer, [int]$Id = -1)
    $out = [System.Collections.Generic.List[string]]::new()
    if (-not $Buffer -or $Buffer.Length -lt 12) { return @() }
    try {
        $rid = ([int]$Buffer[0] -shl 8) -bor $Buffer[1]
        if ($Id -ge 0 -and $rid -ne $Id) { return @() }
        if (([int]$Buffer[2] -band 0x80) -eq 0) { return @() }     # not a response
        if (([int]$Buffer[3] -band 0x0F) -ne 0) { return @() }     # negative response
        $qd = ([int]$Buffer[4] -shl 8) -bor $Buffer[5]
        $an = ([int]$Buffer[6] -shl 8) -bor $Buffer[7]
        $pos = 12
        for ($i = 0; $i -lt $qd; $i++) { [void](Read-NtDnsName $Buffer ([ref]$pos)); $pos += 4 }
        for ($i = 0; $i -lt $an -and $pos -lt $Buffer.Length; $i++) {
            [void](Read-NtDnsName $Buffer ([ref]$pos))
            if ($pos + 10 -gt $Buffer.Length) { break }
            $type  = ([int]$Buffer[$pos] -shl 8) -bor $Buffer[$pos + 1]
            $rdlen = ([int]$Buffer[$pos + 8] -shl 8) -bor $Buffer[$pos + 9]
            $rd = $pos + 10
            if ($type -eq 0x20) {
                for ($k = 0; $k + 6 -le $rdlen -and $rd + $k + 6 -le $Buffer.Length; $k += 6) {
                    $out.Add(('{0}.{1}.{2}.{3}' -f $Buffer[$rd + $k + 2], $Buffer[$rd + $k + 3], $Buffer[$rd + $k + 4], $Buffer[$rd + $k + 5]))
                }
            }
            $pos = $rd + $rdlen
        }
    } catch { }
    return @($out)
}

function Read-NtNetbiosNodeStatus {
    # Names and the adapter MAC a host reports in an NBSTAT response.
    param([byte[]]$Buffer)
    $out = [pscustomobject]@{ Names = @(); ComputerName = ''; Workgroup = ''; Mac = '' }
    if (-not $Buffer -or $Buffer.Length -lt 12) { return $out }
    try {
        $qd = ([int]$Buffer[4] -shl 8) -bor $Buffer[5]
        $pos = 12
        for ($i = 0; $i -lt $qd; $i++) { [void](Read-NtDnsName $Buffer ([ref]$pos)); $pos += 4 }
        [void](Read-NtDnsName $Buffer ([ref]$pos))
        if ($pos + 10 -gt $Buffer.Length) { return $out }
        $type = ([int]$Buffer[$pos] -shl 8) -bor $Buffer[$pos + 1]
        if ($type -ne 0x21) { return $out }
        $rd = $pos + 10
        $count = [int]$Buffer[$rd]
        $p = $rd + 1
        $names = [System.Collections.Generic.List[object]]::new()
        for ($i = 0; $i -lt $count -and $p + 18 -le $Buffer.Length; $i++) {
            $nm = ([Text.Encoding]::ASCII.GetString($Buffer, $p, 15)).Trim([char]0, ' ')
            $suffix = [int]$Buffer[$p + 15]
            $group = ((([int]$Buffer[$p + 16] -shl 8) -bor $Buffer[$p + 17]) -band 0x8000) -ne 0
            $names.Add([pscustomobject]@{ Name = $nm; Suffix = $suffix; Group = $group })
            if ($suffix -eq 0 -and -not $group -and -not $out.ComputerName) { $out.ComputerName = $nm }
            if ($suffix -eq 0 -and $group -and -not $out.Workgroup) { $out.Workgroup = $nm }
            $p += 18
        }
        if ($p + 6 -le $Buffer.Length) {
            $mac = (($Buffer[$p..($p + 5)] | ForEach-Object { '{0:X2}' -f $_ }) -join '')
            if ($mac -ne '000000000000') { $out.Mac = $mac }
        }
        $out.Names = [object[]]$names.ToArray()
    } catch { }
    return $out
}

function Invoke-NtUdpQueries {
    # Send a batch of UDP queries at once and collect every reply against ONE
    # deadline, so asking three protocols on two interfaces costs one timeout,
    # not six.
    #
    # Each query: LocalAddress, Remote (IPEndPoint), Bytes, and optionally
    # Multicast / Broadcast. Replies come back with the query that caused them.
    #
    # ReceiveAsync, never Receive([ref]$endpoint): PowerShell does not write the
    # endpoint back through that [ref], so every responder read 0.0.0.0 in the
    # prototype.
    param($Queries, [int]$TimeoutMs = 1200)
    $results = [System.Collections.Generic.List[object]]::new()
    $live = [System.Collections.Generic.List[object]]::new()
    $sw = [Diagnostics.Stopwatch]::StartNew()
    try {
        foreach ($q in @($Queries)) {
            $client = $null
            try {
                $local = [System.Net.IPAddress]::Parse([string]$q.LocalAddress)
                $client = [System.Net.Sockets.UdpClient]::new([System.Net.IPEndPoint]::new($local, 0))
                # SIO_UDP_CONNRESET off. Without this, one ICMP "port
                # unreachable" from a closed port makes every later receive on
                # the socket throw, and a unicast query to a host with no
                # responder would silently end the whole collection.
                try { [void]$client.Client.IOControl([int]-1744830452, [byte[]](0,0,0,0), $null) } catch { }
                if ($q.Multicast) {
                    # Pin the multicast to THIS interface. With a VPN or overlay
                    # up it would otherwise leave by whichever one Windows prefers.
                    $client.Client.SetSocketOption([System.Net.Sockets.SocketOptionLevel]::IP,
                        [System.Net.Sockets.SocketOptionName]::MulticastInterface, $local.GetAddressBytes())
                }
                if ($q.Broadcast) { $client.EnableBroadcast = $true }
                $bytes = [byte[]]$q.Bytes
                [void]$client.Send($bytes, $bytes.Length, $q.Remote)
                $live.Add([pscustomobject]@{ Query = $q; Client = $client; Task = $client.ReceiveAsync() })
            } catch {
                if ($client) { try { $client.Close() } catch { } }
            }
        }
        while ($live.Count -gt 0) {
            $remaining = $TimeoutMs - [int]$sw.ElapsedMilliseconds
            if ($remaining -le 0) { break }
            $tasks = [System.Threading.Tasks.Task[]]@($live | ForEach-Object { $_.Task })
            $idx = [System.Threading.Tasks.Task]::WaitAny($tasks, $remaining)
            if ($idx -lt 0) { break }
            $item = $live[$idx]
            if ($item.Task.Status -eq [System.Threading.Tasks.TaskStatus]::RanToCompletion) {
                $r = $item.Task.Result
                $results.Add([pscustomobject]@{
                    Query     = $item.Query
                    Buffer    = $r.Buffer
                    Responder = $r.RemoteEndPoint.Address.ToString()
                    Ms        = [int]$sw.ElapsedMilliseconds
                })
                # Keep listening: several devices may answer one multicast.
                try { $item.Task = $item.Client.ReceiveAsync() }
                catch { $live.RemoveAt($idx); try { $item.Client.Close() } catch { } }
            } else {
                $live.RemoveAt($idx)
                try { $item.Client.Close() } catch { }
            }
        }
    } finally {
        foreach ($item in $live) { try { $item.Client.Close() } catch { } }
    }
    return @($results)
}

function Get-NtQueryInterfaces {
    # Interfaces worth asking on: connected, a real link (not a VPN, a virtual
    # switch or loopback - multicast over a tunnel reaches nobody), and holding
    # an IPv4 address. Emits one object per interface; wrap the call in @().
    param($Context = $null)
    if (-not $Context) { $Context = Get-NtLocalContext }
    foreach ($ifc in @($Context.AllInterfaces)) {
        if ([string]$ifc.ConnectionState -ne 'Connected') { continue }
        if ([string]$ifc.InterfaceKind -notin @('WiFi', 'LAN', 'Other')) { continue }
        $addrs = @(@($ifc.Addresses) | Where-Object { $_.IPAddress -and ([string]$_.IPAddress) -notlike '127.*' })
        if ($addrs.Count -eq 0) { continue }
        $pref = @($addrs | Where-Object { ([string]$_.IPAddress) -notlike '169.254.*' } | Select-Object -First 1)
        $a = if ($pref.Count -gt 0) { $pref[0] } else { $addrs[0] }
        $broadcast = ''
        $ipInt = ConvertTo-NtUInt32 ([string]$a.IPAddress)
        $plen = [int]$a.PrefixLength
        if ($null -ne $ipInt -and $plen -ge 1 -and $plen -le 30) {
            $mask = [uint32]([uint32]::MaxValue -shl (32 - $plen))
            $broadcast = ConvertFrom-NtUInt32 ([uint32](($ipInt -band $mask) -bor (-bnot $mask -band [uint32]::MaxValue)))
        }
        [pscustomobject]@{
            Alias        = [string]$ifc.InterfaceAlias
            Index        = [int]$ifc.InterfaceIndex
            Kind         = [string]$ifc.InterfaceKind
            Address      = [string]$a.IPAddress
            PrefixLength = $plen
            Broadcast    = $broadcast
        }
    }
}

function Resolve-NtNameEverywhere {
    # Name -> address, from every source, reporting who answered each.
    #
    #   hosts file        - local override; never the device
    #   Windows resolver  - what ping and every application will actually use
    #   DNS               - may be stale, or an overlay's address
    #   mDNS/LLMNR/NetBIOS- the DEVICE ITSELF, with the address it holds now
    #
    # The multicast queries and the two lookups run concurrently against one
    # deadline, so the whole thing costs about a second and a half.
    param(
        [string]$Name,
        $Context = $null,
        [int]$TimeoutMs = 1200,
        [int]$DnsTimeoutMs = 2000
    )
    if (-not $Context) { $Context = Get-NtLocalContext }
    $full  = $Name.Trim().TrimEnd('.')
    $short = ($full -split '\.')[0]
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $answers = [System.Collections.Generic.List[object]]::new()

    # Start both lookups first so they overlap the multicast collection.
    # Resolve-DnsName has no usable timeout, so it runs in its own runspace and
    # is simply abandoned if it overruns.
    $resolverTask = $null
    try { $resolverTask = [System.Net.Dns]::GetHostEntryAsync($full) } catch { }
    $dnsPs = $null; $dnsAsync = $null
    try {
        $dnsPs = [PowerShell]::Create()
        [void]$dnsPs.AddScript({
            param($n)
            try {
                @(Resolve-DnsName -Name $n -Type A -DnsOnly -NoHostsFile -QuickTimeout -ErrorAction Stop |
                  Where-Object { $_.Type -eq 'A' } |
                  ForEach-Object { [pscustomobject]@{ Name = [string]$_.Name; Address = [string]$_.IPAddress } })
            } catch { @() }
        }).AddArgument($full)
        $dnsAsync = $dnsPs.BeginInvoke()
    } catch { $dnsPs = $null }

    # hosts file: a local override, recorded but never mistaken for the device.
    # One row per line, naming the product that wrote it when it sits in a
    # managed section.
    $hostsAddrs = [System.Collections.Generic.List[string]]::new()
    try {
        $hosts = Get-NtHostsFile
        foreach ($e in @($hosts.Entries | Where-Object { -not $_.Commented })) {
            if (-not (Test-NtIsIPv4 ([string]$e.IPAddress))) { continue }
            $matched = @(@($e.Names) | Where-Object { ($_ -ieq $full) -or (($full -notmatch '\.') -and ((($_ -split '\.')[0]) -ieq $short)) })
            if ($matched.Count -eq 0) { continue }
            $label = if ($e.Section) { ('hosts file (line {0}, {1}-managed)' -f $e.LineNumber, $e.Section) } else { ('hosts file (line {0})' -f $e.LineNumber) }
            $answers.Add([pscustomobject]@{
                Source = $label; Address = [string]$e.IPAddress
                NameMatched = [string]$matched[0]; Responder = ''; Interface = ''; Mac = ''; Ms = 0; SelfAnswer = $false
                HostsSection = [string]$e.Section
            })
            $hostsAddrs.Add([string]$e.IPAddress)
        }
    } catch { }

    # The device itself, on every usable interface.
    $ifaces = @(Get-NtQueryInterfaces -Context $Context)
    $queries = [System.Collections.Generic.List[object]]::new()
    $mdnsGroup  = [System.Net.IPEndPoint]::new([System.Net.IPAddress]::Parse('224.0.0.251'), 5353)
    $llmnrGroup = [System.Net.IPEndPoint]::new([System.Net.IPAddress]::Parse('224.0.0.252'), 5355)
    foreach ($if in $ifaces) {
        [byte[]]$qm = ConvertTo-NtDnsQuestion -Name ('{0}.local' -f $short) -Type 1 -UnicastResponse
        $queries.Add([pscustomobject]@{ Protocol = 'mDNS'; Interface = $if.Alias; LocalAddress = $if.Address; Remote = $mdnsGroup; Bytes = $qm; Multicast = $true; Broadcast = $false; Id = 0; Expect = ('{0}.local' -f $short) })

        $lid = Get-Random -Minimum 1 -Maximum 65535
        [byte[]]$ql = ConvertTo-NtDnsQuestion -Name $short -Type 1 -Id $lid
        $queries.Add([pscustomobject]@{ Protocol = 'LLMNR'; Interface = $if.Alias; LocalAddress = $if.Address; Remote = $llmnrGroup; Bytes = $ql; Multicast = $true; Broadcast = $false; Id = $lid; Expect = $short })

        if ($if.Broadcast -and $short.Length -le 15) {
            $nid = Get-Random -Minimum 1 -Maximum 65535
            [byte[]]$qn = New-NtNetbiosQuery -Name $short -Id $nid -Broadcast
            $queries.Add([pscustomobject]@{ Protocol = 'NetBIOS'; Interface = $if.Alias; LocalAddress = $if.Address; Remote = [System.Net.IPEndPoint]::new([System.Net.IPAddress]::Parse($if.Broadcast), 137); Bytes = $qn; Multicast = $false; Broadcast = $true; Id = $nid; Expect = $short })
        }
    }
    $replies = @(Invoke-NtUdpQueries -Queries $queries -TimeoutMs $TimeoutMs)

    foreach ($r in $replies) {
        $q = $r.Query
        switch ($q.Protocol) {
            'mDNS' {
                foreach ($rec in @(Read-NtDnsRecords $r.Buffer)) {
                    if ($rec.Type -eq 1 -and $rec.Address -and $rec.Name -ieq $q.Expect) {
                        $answers.Add([pscustomobject]@{ Source = 'mDNS'; Address = $rec.Address; NameMatched = $rec.Name; Responder = $r.Responder; Interface = $q.Interface; Mac = ''; Ms = $r.Ms; SelfAnswer = $true })
                    }
                }
            }
            'LLMNR' {
                if ($r.Buffer.Length -lt 2 -or ((([int]$r.Buffer[0] -shl 8) -bor $r.Buffer[1]) -ne $q.Id)) { continue }
                foreach ($rec in @(Read-NtDnsRecords $r.Buffer)) {
                    if ($rec.Type -eq 1 -and $rec.Address -and $rec.Name -ieq $q.Expect) {
                        $answers.Add([pscustomobject]@{ Source = 'LLMNR'; Address = $rec.Address; NameMatched = $rec.Name; Responder = $r.Responder; Interface = $q.Interface; Mac = ''; Ms = $r.Ms; SelfAnswer = $true })
                    }
                }
            }
            'NetBIOS' {
                foreach ($ip in @(Read-NtNetbiosAddresses $r.Buffer $q.Id)) {
                    $answers.Add([pscustomobject]@{ Source = 'NetBIOS'; Address = $ip; NameMatched = $short.ToUpperInvariant(); Responder = $r.Responder; Interface = $q.Interface; Mac = ''; Ms = $r.Ms; SelfAnswer = $true })
                }
            }
        }
    }

    # What Windows itself would pick - the same answer as ping's first line.
    # The canonical name says where it came from: NAME.local is mDNS, a bare
    # name is LLMNR or NetBIOS, anything with a suffix came from DNS. Note
    # NAME.corp.local is DNS: exactly one label before .local means mDNS.
    $resolverName = ''
    $resolverAddrs = @()
    if ($resolverTask) {
        try {
            $wait = [math]::Max(1, $DnsTimeoutMs - [int]$sw.ElapsedMilliseconds)
            if ($resolverTask.Wait($wait)) {
                $resolverName = [string]$resolverTask.Result.HostName
                $resolverAddrs = @($resolverTask.Result.AddressList |
                    Where-Object { $_.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork } |
                    ForEach-Object { $_.ToString() })
            }
        } catch { }
    }
    # The hosts file is consulted FIRST, so if every address the resolver gave
    # came from it, that is where the answer came from - whatever its suffix.
    # (A Tailscale entry carries a .ts.net suffix and would otherwise read as
    # DNS.)
    $fromHosts = ($resolverAddrs.Count -gt 0 -and @($resolverAddrs | Where-Object { $hostsAddrs -notcontains $_ }).Count -eq 0)
    $how = if ($fromHosts) { 'via hosts file' }
           elseif ($resolverName -match '^[^.]+\.local\.?$') { 'via mDNS' }
           elseif ($resolverName -match '\.') { 'via DNS' }
           elseif ($resolverName) { 'via LLMNR/NetBIOS' } else { '' }
    foreach ($a in $resolverAddrs) {
        $answers.Add([pscustomobject]@{ Source = ('Windows resolver ({0})' -f $how).Replace(' ()', ''); Address = $a; NameMatched = $resolverName; Responder = ''; Interface = ''; Mac = ''; Ms = [int]$sw.ElapsedMilliseconds; SelfAnswer = $false })
    }

    # DNS only.
    $dnsName = ''
    $dnsAddrs = @()
    if ($dnsPs -and $dnsAsync) {
        try {
            $wait = [math]::Max(1, $DnsTimeoutMs - [int]$sw.ElapsedMilliseconds)
            if ($dnsAsync.AsyncWaitHandle.WaitOne($wait)) {
                foreach ($d in @($dnsPs.EndInvoke($dnsAsync))) {
                    if (-not $d -or -not $d.Address) { continue }
                    $dnsName = [string]$d.Name
                    $dnsAddrs += [string]$d.Address
                    $answers.Add([pscustomobject]@{ Source = 'DNS'; Address = [string]$d.Address; NameMatched = [string]$d.Name; Responder = ''; Interface = ''; Mac = ''; Ms = [int]$sw.ElapsedMilliseconds; SelfAnswer = $false })
                }
                $dnsPs.Dispose()
            } else {
                # Abandon rather than block: stopping a pipeline stuck inside
                # a DNS call can itself hang.
                try { [void]$dnsPs.BeginStop($null, $null) } catch { }
            }
        } catch { }
    }

    # One row per source/address/responder. mDNS responders commonly repeat a
    # record in the answer and additional sections, and a device reachable on
    # two paths answers twice.
    $unique = [System.Collections.Generic.List[object]]::new()
    $rowKeys = @{}
    foreach ($a in $answers) {
        $k = ('{0}|{1}|{2}' -f $a.Source, $a.Address, $a.Responder)
        if ($rowKeys.ContainsKey($k)) { continue }
        $rowKeys[$k] = $true
        $unique.Add($a)
    }

    # MAC for any on-link responder, and whether each address is on one of
    # THIS machine's subnets. A multi-homed device lists every adapter over
    # NetBIOS - Hyper-V and VM switches included - and only an address on a
    # shared subnet is one this machine can reach directly.
    $arp = @{}
    try { $arp = Get-NtArpTable } catch { }
    foreach ($a in $unique) {
        if ($a.Responder -and $arp.ContainsKey($a.Responder)) { $a.Mac = [string]$arp[$a.Responder].Mac }
        $onLink = $false
        foreach ($p in @($Context.ConnectedPrefixes)) {
            if (Test-NtIpInPrefix -IPAddress ([string]$a.Address) -Prefix $p) { $onLink = $true; break }
        }
        $a | Add-Member -NotePropertyName OnLink -NotePropertyValue $onLink -Force
    }

    $self = @(@($unique) | Where-Object { $_.SelfAnswer } | ForEach-Object { $_.Address } | Select-Object -Unique)
    [pscustomobject]@{
        Query             = $full
        ShortName         = $short
        Answers           = [object[]]$unique.ToArray()
        SelfAddresses     = [object[]]$self
        ResolverName      = $resolverName
        ResolverVia       = $how
        ResolverAddresses = [object[]]$resolverAddrs
        DnsName           = $dnsName
        DnsAddresses      = [object[]]@($dnsAddrs | Select-Object -Unique)
        HostsAddresses    = [object[]]@($hostsAddrs | Select-Object -Unique)
        Interfaces        = [object[]]@($ifaces | ForEach-Object { $_.Alias })
        Answered          = ($unique.Count -gt 0)
        # EVERY address the device gave is self-assigned. One 169.254 among
        # several is a disconnected spare adapter, not a missing lease.
        NoLease           = ($self.Count -gt 0 -and @($self | Where-Object { $_ -notlike '169.254.*' }).Count -eq 0)
        DurationMs        = [int]$sw.ElapsedMilliseconds
    }
}

function Resolve-NtAddressEverywhere {
    # Address -> name, from every source that can answer it: DNS PTR, the
    # device's own mDNS and LLMNR responders, and NetBIOS node status - which
    # also carries the MAC the host reports, useful when it is not on-link.
    param([string]$Address, $Context = $null, [int]$TimeoutMs = 1200)
    if (-not (Test-NtIsIPv4 $Address)) { return $null }
    if (-not $Context) { $Context = Get-NtLocalContext }
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $names = [System.Collections.Generic.List[object]]::new()

    $ptrTask = $null
    try { $ptrTask = [System.Net.Dns]::GetHostEntryAsync($Address) } catch { }

    # Send from the address Windows would use to reach it.
    $local = ''
    try { $local = [string](Resolve-NtSelectedRoute -Destination $Address).SourceAddress } catch { }
    if (-not $local) {
        $first = @(Get-NtQueryInterfaces -Context $Context | Select-Object -First 1)
        if ($first.Count -gt 0) { $local = $first[0].Address }
    }

    $nb = [pscustomobject]@{ Names = @(); ComputerName = ''; Workgroup = ''; Mac = '' }
    if ($local) {
        $octets = $Address.Split('.'); [Array]::Reverse($octets)
        $rev = ('{0}.in-addr.arpa' -f ($octets -join '.'))
        $dest = [System.Net.IPAddress]::Parse($Address)
        [byte[]]$qm = ConvertTo-NtDnsQuestion -Name $rev -Type 12
        $lid = Get-Random -Minimum 1 -Maximum 65535
        [byte[]]$ql = ConvertTo-NtDnsQuestion -Name $rev -Type 12 -Id $lid
        $nid = Get-Random -Minimum 1 -Maximum 65535
        [byte[]]$qn = New-NtNetbiosQuery -NodeStatus -Id $nid
        $queries = @(
            [pscustomobject]@{ Protocol = 'mDNS';    LocalAddress = $local; Remote = [System.Net.IPEndPoint]::new($dest, 5353); Bytes = $qm; Id = 0 }
            [pscustomobject]@{ Protocol = 'LLMNR';   LocalAddress = $local; Remote = [System.Net.IPEndPoint]::new($dest, 5355); Bytes = $ql; Id = $lid }
            [pscustomobject]@{ Protocol = 'NetBIOS'; LocalAddress = $local; Remote = [System.Net.IPEndPoint]::new($dest, 137);  Bytes = $qn; Id = $nid }
        )
        foreach ($r in @(Invoke-NtUdpQueries -Queries $queries -TimeoutMs $TimeoutMs)) {
            if ($r.Query.Protocol -eq 'NetBIOS') {
                $nb = Read-NtNetbiosNodeStatus $r.Buffer
                if ($nb.ComputerName) {
                    $names.Add([pscustomobject]@{ Source = 'NetBIOS'; Name = $nb.ComputerName; Responder = $r.Responder; Ms = $r.Ms })
                }
            } else {
                foreach ($rec in @(Read-NtDnsRecords $r.Buffer)) {
                    if ($rec.Type -eq 12 -and $rec.Target) {
                        $names.Add([pscustomobject]@{ Source = $r.Query.Protocol; Name = $rec.Target; Responder = $r.Responder; Ms = $r.Ms })
                    }
                }
            }
        }
    }

    if ($ptrTask) {
        try {
            if ($ptrTask.Wait([math]::Max(1, $TimeoutMs - [int]$sw.ElapsedMilliseconds))) {
                $hn = [string]$ptrTask.Result.HostName
                if ($hn -and $hn -ne $Address) {
                    $names.Add([pscustomobject]@{ Source = 'DNS PTR'; Name = $hn; Responder = ''; Ms = [int]$sw.ElapsedMilliseconds })
                }
            }
        } catch { }
    }

    $arpMac = ''; $arpState = ''; $arpLife = $false
    try {
        $arp = Get-NtArpTable
        if ($arp.ContainsKey($Address)) {
            $arpMac = [string]$arp[$Address].Mac
            $arpState = [string]$arp[$Address].State
            $arpLife = [bool](Get-NtNeighbourConfidence -State $arpState).ProvesLife
        }
    } catch { }

    $best = ''
    foreach ($src in @('NetBIOS', 'mDNS', 'LLMNR', 'DNS PTR')) {
        $hit = @(@($names) | Where-Object { $_.Source -eq $src } | Select-Object -First 1)
        if ($hit.Count -gt 0) { $best = [string]$hit[0].Name; break }
    }
    [pscustomobject]@{
        Address       = $Address
        Names         = [object[]]$names.ToArray()
        ComputerName  = $best
        Workgroup     = [string]$nb.Workgroup
        NetbiosMac    = [string]$nb.Mac
        ArpMac        = $arpMac
        ArpState      = $arpState
        ArpProvesLife = $arpLife
        Mac           = $(if ($arpMac) { $arpMac } else { [string]$nb.Mac })
        DurationMs    = [int]$sw.ElapsedMilliseconds
    }
}

function Test-NtIsMacAddress {
    # aa-bb-cc-dd-ee-ff, aa:bb:cc:dd:ee:ff, aabb.ccdd.eeff or 12 bare hex digits.
    param([string]$Value)
    if (-not $Value) { return $false }
    $v = $Value.Trim()
    return ($v -match '^([0-9A-Fa-f]{2}[-:]){5}[0-9A-Fa-f]{2}$' -or
            $v -match '^[0-9A-Fa-f]{4}\.[0-9A-Fa-f]{4}\.[0-9A-Fa-f]{4}$' -or
            $v -match '^[0-9A-Fa-f]{12}$')
}

function Get-NtInventoryFiles {
    # Every inventory the lookup should consult: this machine's own, plus every
    # per-site rollup in the project folder.
    param([string]$ProjectDir = '')
    $files = [System.Collections.Generic.List[string]]::new()
    $local = Join-Path (Get-NtDataDir) 'inventory.json'
    if (Test-Path -LiteralPath $local) { $files.Add($local) }
    try {
        $invDir = Join-Path (Get-NtProjectDir -Hint $ProjectDir) 'inventory'
        if (Test-Path -LiteralPath $invDir) {
            foreach ($f in @(Get-ChildItem -LiteralPath $invDir -Filter '*.json' -ErrorAction SilentlyContinue)) { $files.Add($f.FullName) }
        }
    } catch { }
    return @($files.ToArray())
}

function Find-NtInventoryDevice {
    # What does the history know about this device? By hostname (short name,
    # case-insensitive), by MAC, or by address - across every inventory file.
    param([string]$Name = '', [string]$Mac = '', [string]$Ip = '', [string]$ProjectDir = '')
    $normMac = ''
    if ($Mac) { $normMac = ConvertTo-NtNormalMac $Mac }
    $short = ''
    if ($Name) { $short = ($Name.Trim() -split '\.')[0] }
    $byKey = @{}

    foreach ($file in @(Get-NtInventoryFiles -ProjectDir $ProjectDir)) {
        $inv = Read-NtJsonFile -Path $file
        if (-not $inv) { continue }
        foreach ($d in @($inv.devices)) {
            if (-not $d) { continue }
            $match = $false
            if ($normMac -and [string]$d.mac -eq $normMac) { $match = $true }
            if (-not $match -and $short) {
                foreach ($h in @($d.hostnames)) { if ($h -and ((([string]$h) -split '\.')[0]) -ieq $short) { $match = $true; break } }
            }
            if (-not $match -and $Ip) {
                foreach ($x in @($d.ips)) { if ([string]$x.ip -eq $Ip) { $match = $true; break } }
            }
            if (-not $match) { continue }
            $ips = @(@($d.ips) | Sort-Object { [string]$_.lastSeenUtc } -Descending)
            $key = ('MAC:{0}' -f $d.mac)
            $rec = [pscustomobject]@{
                Mac          = [string]$d.mac
                MacFormatted = (Format-NtMac ([string]$d.mac))
                Vendor       = [string]$d.vendor
                Hostnames    = [object[]]@($d.hostnames)
                LastIp       = $(if ($ips.Count -gt 0) { [string]$ips[0].ip } else { '' })
                LastSite     = $(if ($ips.Count -gt 0) { [string]$ips[0].site } else { '' })
                LastSeenUtc  = [string]$d.lastSeenUtc
                FirstSeenUtc = [string]$d.firstSeenUtc
                Ips          = [object[]]$ips
                File         = $file
            }
            if (-not $byKey.ContainsKey($key) -or [string]$byKey[$key].LastSeenUtc -lt $rec.LastSeenUtc) { $byKey[$key] = $rec }
        }
        foreach ($n in @($inv.ipsWithoutMac)) {
            if (-not $n) { continue }
            $match = ($Ip -and [string]$n.ip -eq $Ip) -or ($short -and $n.hostname -and ((([string]$n.hostname) -split '\.')[0]) -ieq $short)
            if (-not $match) { continue }
            $key = ('IP:{0}|{1}' -f $n.ip, $n.site)
            $rec = [pscustomobject]@{
                Mac = ''; MacFormatted = ''; Vendor = ''
                Hostnames = [object[]]@($(if ($n.hostname) { [string]$n.hostname }))
                LastIp = [string]$n.ip; LastSite = [string]$n.site
                LastSeenUtc = [string]$n.lastSeenUtc; FirstSeenUtc = [string]$n.firstSeenUtc
                Ips = @(); File = $file
            }
            if (-not $byKey.ContainsKey($key) -or [string]$byKey[$key].LastSeenUtc -lt $rec.LastSeenUtc) { $byKey[$key] = $rec }
        }
    }
    return @(@($byKey.Values) | Sort-Object LastSeenUtc -Descending)
}

function Resolve-NtMacTarget {
    # MAC -> where is it now? The live ARP table first, with each entry graded
    # (Reachable proves life; Stale only says it answered once), then the
    # inventory's history. If the best lead is an on-link address that is not
    # confirmed, one ping refreshes the neighbour entry and settles it.
    param([string]$Mac, $Context = $null, [string]$ProjectDir = '')
    if (-not $Context) { $Context = Get-NtLocalContext }
    $norm = ConvertTo-NtNormalMac $Mac
    $current = [System.Collections.Generic.List[object]]::new()
    $arp = Get-NtArpTable
    foreach ($k in @($arp.Keys)) {
        $e = $arp[$k]
        if ([string]$e.Mac -ne $norm) { continue }
        $conf = Get-NtNeighbourConfidence -State ([string]$e.State)
        $current.Add([pscustomobject]@{ IPAddress = [string]$e.IPAddress; State = [string]$e.State; ProvesLife = [bool]$conf.ProvesLife; Detail = [string]$conf.Detail })
    }
    $history = @(Find-NtInventoryDevice -Mac $norm -ProjectDir $ProjectDir)

    $live = @(@($current) | Where-Object { $_.ProvesLife })
    if ($live.Count -eq 0) {
        $lead = ''
        if ($current.Count -gt 0) { $lead = [string]$current[0].IPAddress }
        elseif ($history.Count -gt 0 -and $history[0].LastIp) { $lead = [string]$history[0].LastIp }
        if ($lead -and (Test-NtRangeOnLink -Addresses @($lead) -Context $Context)) {
            [void](Test-NtIcmp -Target $lead -Count 1 -TimeoutMs 700)
            try {
                $fresh = Get-NetNeighbor -IPAddress $lead -AddressFamily IPv4 -ErrorAction Stop | Select-Object -First 1
                if ($fresh -and (ConvertTo-NtNormalMac ([string]$fresh.LinkLayerAddress)) -eq $norm) {
                    $conf = Get-NtNeighbourConfidence -State ([string]$fresh.State)
                    $existing = @(@($current) | Where-Object { $_.IPAddress -eq $lead })
                    if ($existing.Count -gt 0) {
                        $existing[0].State = [string]$fresh.State
                        $existing[0].ProvesLife = [bool]$conf.ProvesLife
                        $existing[0].Detail = [string]$conf.Detail
                    } else {
                        $current.Add([pscustomobject]@{ IPAddress = $lead; State = [string]$fresh.State; ProvesLife = [bool]$conf.ProvesLife; Detail = [string]$conf.Detail })
                    }
                }
            } catch { }
            $live = @(@($current) | Where-Object { $_.ProvesLife })
        }
    }

    $best = ''; $bestSource = ''
    if ($live.Count -gt 0) { $best = [string]$live[0].IPAddress; $bestSource = ('ARP ({0})' -f $live[0].State) }
    elseif ($current.Count -gt 0) { $best = [string]$current[0].IPAddress; $bestSource = ('ARP ({0}, not confirmed)' -f $current[0].State) }
    elseif ($history.Count -gt 0 -and $history[0].LastIp) { $best = [string]$history[0].LastIp; $bestSource = ('inventory, last seen {0}' -f $history[0].LastSeenUtc) }

    [pscustomobject]@{
        Mac          = $norm
        MacFormatted = (Format-NtMac $norm)
        Current      = [object[]]$current.ToArray()
        History      = [object[]]$history
        BestAddress  = $best
        BestSource   = $bestSource
        ProvesLife   = ($live.Count -gt 0)
    }
}

function Get-NtDeviceIdentity {
    # One picture of the device from every angle, and the address to test.
    #
    # When sources disagree about the address, each distinct candidate is
    # probed and the one that answers wins; if none answers, the device's own
    # answer is preferred over DNS. The disagreement itself is kept, because
    # "the name points somewhere the device is not" is usually the finding.
    param(
        [string]$Target,
        $Context = $null,
        [int[]]$Ports = @(),
        [switch]$NoVendorLookup,
        [string]$ProjectDir = '',
        $Shared = $null
    )
    if (-not $Context) { $Context = Get-NtLocalContext }
    $t = $Target.Trim()
    $kind = if (Test-NtIsMacAddress $t) { 'MAC' } elseif (Test-NtIsIPv4 $t) { 'IP' } else { 'Name' }
    if (@($Ports).Count -eq 0) { $Ports = @(443, 445, 3389, 80, 22) }

    $cands = [ordered]@{}
    $addCand = {
        param([string]$Address, [string]$Source, [int]$Rank, [bool]$Self)
        if (-not (Test-NtIsIPv4 $Address)) { return }
        if (-not $cands.Contains($Address)) {
            $cands[$Address] = [pscustomobject]@{
                Address = $Address; Sources = [System.Collections.Generic.List[string]]::new()
                Rank = $Rank; SelfAnswered = $false; Probed = $false; Responds = $false; Icmp = $false; OpenPorts = @()
            }
        }
        $c = $cands[$Address]
        if ($c.Sources -notcontains $Source) { $c.Sources.Add($Source) }
        if ($Rank -lt $c.Rank) { $c.Rank = $Rank }
        if ($Self) { $c.SelfAnswered = $true }
    }

    $nameAnswers = $null; $reverse = $null; $macInfo = $null; $history = @()
    if ($Shared) { $Shared.Status = ('Identifying {0}...' -f $t) }
    switch ($kind) {
        'Name' {
            $nameAnswers = Resolve-NtNameEverywhere -Name $t -Context $Context
            foreach ($a in @($nameAnswers.Answers)) {
                # 1 the device's own address on a subnet shared with this PC;
                # 2 its other adapters (VM switches and the like, via NetBIOS);
                # 3 what Windows / DNS would use; 4 a hosts entry on its own.
                $rank = if ($a.SelfAnswer -and $a.OnLink) { 1 }
                        elseif ($a.SelfAnswer) { 2 }
                        elseif ($a.Source -like 'Windows resolver*' -or $a.Source -eq 'DNS') { 3 }
                        else { 4 }
                & $addCand $a.Address $a.Source $rank ([bool]$a.SelfAnswer)
            }
            $history = @(Find-NtInventoryDevice -Name $t -ProjectDir $ProjectDir)
            if ($cands.Count -eq 0 -and $history.Count -gt 0 -and $history[0].LastIp) {
                & $addCand $history[0].LastIp ('inventory, last seen {0}' -f $history[0].LastSeenUtc) 5 $false
            }
        }
        'IP' {
            & $addCand $t 'as entered' 0 $false
            $history = @(Find-NtInventoryDevice -Ip $t -ProjectDir $ProjectDir)
        }
        'MAC' {
            $macInfo = Resolve-NtMacTarget -Mac $t -Context $Context -ProjectDir $ProjectDir
            foreach ($c in @($macInfo.Current)) {
                & $addCand $c.IPAddress ('ARP ({0})' -f $c.State) $(if ($c.ProvesLife) { 1 } else { 3 }) $false
            }
            $history = @($macInfo.History)
            if ($history.Count -gt 0 -and $history[0].LastIp) {
                & $addCand $history[0].LastIp ('inventory, last seen {0}' -f $history[0].LastSeenUtc) 5 $false
            }
        }
    }

    # Probe only when there is a choice to make; the triage probes the chosen
    # address thoroughly afterwards anyway.
    $list = @($cands.Values)
    if ($list.Count -gt 1 -and -not ($Shared -and $Shared.Cancel)) {
        # All candidates at once, one timeout - probing them one after another
        # took seven seconds for a single multi-homed PC.
        #
        # The device's OTHER adapters (rank 2: Hyper-V and VM switches it
        # listed over NetBIOS) are skipped when it already has an address on a
        # subnet shared with this PC - they can never answer from here.
        # Whatever Windows would actually use is always included, so the
        # report can say whether the NAME's address works at all.
        $hasDirect = @($list | Where-Object { $_.Rank -le 1 }).Count -gt 0
        $toProbe = @($list | Where-Object { -not ($hasDirect -and $_.Rank -eq 2) } | Sort-Object Rank | Select-Object -First 6)
        if ($toProbe.Count -gt 0) {
            if ($Shared) { $Shared.Status = ('Probing {0} candidate address(es) for {1}...' -f $toProbe.Count, $t) }
            $probe = @{}
            foreach ($r in @(Test-NtReachableParallel -Addresses @($toProbe | ForEach-Object { $_.Address }) -Ports $Ports -TimeoutMs 900 -Context $Context)) {
                $probe[[string]$r.Address] = $r
            }
            foreach ($c in $toProbe) {
                $c.Probed = $true
                if ($probe.ContainsKey($c.Address)) {
                    $r = $probe[$c.Address]
                    # Present counts an ARP-proven host that ignores ICMP and
                    # every port: the device IS at that address.
                    $c.Responds  = [bool]$r.Present
                    $c.Icmp      = [bool]$r.Icmp
                    $c.OpenPorts = [object[]]@($r.OpenPorts)
                }
            }
        }
    }
    $ordered = @($list | Sort-Object Rank)
    $chosen = $null; $because = ''
    $responding = @($ordered | Where-Object { $_.Responds } | Select-Object -First 1)
    if ($responding.Count -gt 0) {
        $chosen = $responding[0]
        $because = ('it answered when probed ({0}), and the other candidate(s) did not' -f ($chosen.Sources -join ', '))
    } elseif ($ordered.Count -gt 0) {
        $chosen = $ordered[0]
        $because = if ($chosen.SelfAnswered) { 'the device gave this address itself' }
                   elseif ($ordered.Count -gt 1) { 'no candidate answered, so the most direct source was preferred' }
                   else { ('the only address found ({0})' -f ($chosen.Sources -join ', ')) }
    }

    # Disagreement: the device says one thing, the name lookup another.
    $disagree = $null
    if ($nameAnswers) {
        $selfSet  = @($nameAnswers.SelfAddresses)
        $otherSet = @(@($nameAnswers.ResolverAddresses) + @($nameAnswers.DnsAddresses) | Select-Object -Unique)
        if ($selfSet.Count -gt 0 -and $otherSet.Count -gt 0) {
            $overlap = @($selfSet | Where-Object { $otherSet -contains $_ })
            if ($overlap.Count -eq 0) {
                $working = @($ordered | Where-Object { $_.Responds } | ForEach-Object { $_.Address })
                $disagree = [pscustomobject]@{
                    SelfAddresses  = [object[]]$selfSet
                    OtherAddresses = [object[]]$otherSet
                    OtherName      = $(if ($nameAnswers.ResolverName) { $nameAnswers.ResolverName } else { $nameAnswers.DnsName })
                    Working        = [object[]]$working
                    ResolverUsesOther = (@($nameAnswers.ResolverAddresses | Where-Object { $selfSet -notcontains $_ }).Count -gt 0)
                }
            }
        }
    }

    $chosenIp = if ($chosen) { [string]$chosen.Address } else { '' }
    if ($chosenIp -and $kind -ne 'Name') {
        $reverse = Resolve-NtAddressEverywhere -Address $chosenIp -Context $Context
    }

    $names = [System.Collections.Generic.List[string]]::new()
    $addName = { param($n) if ($n -and ($names | Where-Object { $_ -ieq $n }).Count -eq 0) { $names.Add([string]$n) } }
    if ($nameAnswers) { foreach ($a in @($nameAnswers.Answers)) { if ($a.SelfAnswer -and $a.NameMatched) { & $addName $a.NameMatched } } }
    if ($reverse) { foreach ($n in @($reverse.Names)) { & $addName $n.Name } }
    foreach ($h in @($history)) { foreach ($n in @($h.Hostnames)) { & $addName $n } }

    $onLink = $false
    if ($chosenIp) { $onLink = Test-NtRangeOnLink -Addresses @($chosenIp) -Context $Context }

    $mac = ''
    $arpState = ''; $arpLife = $false
    if ($chosenIp) {
        try {
            $arp = Get-NtArpTable
            # Receiving a reply does not create an ARP entry here. Sending one
            # ping to an on-link address forces ARP resolution, which the
            # device answers even when its firewall drops the ping itself.
            if ($onLink -and -not $arp.ContainsKey($chosenIp)) {
                [void](Test-NtIcmp -Target $chosenIp -Count 1 -TimeoutMs 500)
                $arp = Get-NtArpTable
            }
            if ($arp.ContainsKey($chosenIp)) {
                $mac = [string]$arp[$chosenIp].Mac
                $arpState = [string]$arp[$chosenIp].State
                $arpLife = [bool](Get-NtNeighbourConfidence -State $arpState).ProvesLife
            }
        } catch { }
    }
    if (-not $mac -and $reverse -and $reverse.Mac) { $mac = [string]$reverse.Mac }
    if (-not $mac -and $macInfo) { $mac = [string]$macInfo.Mac }
    if (-not $mac -and $nameAnswers) {
        $hit = @(@($nameAnswers.Answers) | Where-Object { $_.Address -eq $chosenIp -and $_.Mac } | Select-Object -First 1)
        if ($hit.Count -gt 0) { $mac = [string]$hit[0].Mac }
    }
    $vendor = ''
    if ($mac) {
        try { $v = Get-NtOuiVendor -Macs @($mac) -NoLookup:$NoVendorLookup; if ($v.ContainsKey($mac)) { $vendor = [string]$v[$mac] } } catch { }
    }
    # A reverse-lookup reply from the device's own NetBIOS, mDNS or LLMNR
    # responder is a reply FROM the device - proof of life, exactly as a
    # multicast answer is for a name.
    $reverseSelf = $false
    if ($reverse) {
        $reverseSelf = (@(@($reverse.Names) | Where-Object { $_.Source -in @('NetBIOS', 'mDNS', 'LLMNR') -and $_.Responder -eq $chosenIp }).Count -gt 0)
    }

    $notFound = $false
    if ($kind -eq 'Name' -and $nameAnswers -and -not $nameAnswers.Answered) { $notFound = $true }
    if ($kind -eq 'MAC' -and $macInfo -and -not $macInfo.BestAddress) { $notFound = $true }

    [pscustomobject]@{
        Input         = $t
        Kind          = $kind
        ChosenAddress = $chosenIp
        ChosenBecause = $because
        Candidates    = [object[]]@($ordered | ForEach-Object {
                            [pscustomobject]@{ Address = $_.Address; Sources = [object[]]$_.Sources.ToArray(); SelfAnswered = $_.SelfAnswered; Probed = $_.Probed; Responds = $_.Responds; Icmp = $_.Icmp; OpenPorts = [object[]]$_.OpenPorts }
                        })
        NameAnswers   = $nameAnswers
        Reverse       = $reverse
        MacTarget     = $macInfo
        Names         = [object[]]$names.ToArray()
        Mac           = $mac
        MacFormatted  = $(if ($mac) { Format-NtMac $mac } else { '' })
        Vendor        = $vendor
        ArpState      = $arpState
        ArpProvesLife = $arpLife
        OnLink        = $onLink
        History       = [object[]]$history
        Disagreement  = $disagree
        SelfAnswered  = [bool](($nameAnswers -and @($nameAnswers.SelfAddresses).Count -gt 0) -or $reverseSelf)
        NoLease       = [bool]($nameAnswers -and $nameAnswers.NoLease)
        NotFound      = $notFound
    }
}

function Get-NtDeviceLabel {
    # The best short name for the device, for headlines.
    param($Identity)
    if (-not $Identity) { return '' }
    if ($Identity.Kind -eq 'Name') { return [string]$Identity.Input }
    if ($Identity.Reverse -and $Identity.Reverse.ComputerName) { return ('{0} ({1})' -f $Identity.Reverse.ComputerName, $Identity.ChosenAddress) }
    if ($Identity.Kind -eq 'MAC') { return [string]$Identity.MacTarget.MacFormatted }
    return [string]$Identity.Input
}

function Get-NtDeviceStatus {
    # The one-line answer to "is it there?", built from the identity and the
    # triage's own probes of the chosen address.
    param($Identity, $TargetIcmp = $null, $TargetPorts = @(), $Discovered = @())
    $label = Get-NtDeviceLabel -Identity $Identity
    $icmpOk = [bool]($TargetIcmp -and $TargetIcmp.Success)
    $tcpOk = (@($TargetPorts).Count + @($Discovered).Count) -gt 0
    # Without the triage's own probes, use what the identity step measured.
    if (-not $TargetIcmp) {
        $cc = @(@($Identity.Candidates) | Where-Object { $_.Address -eq $Identity.ChosenAddress -and $_.Probed } | Select-Object -First 1)
        if ($cc.Count -gt 0) {
            $icmpOk = [bool]$cc[0].Icmp
            $tcpOk = (@($cc[0].OpenPorts).Count -gt 0)
        }
    }
    $responds = $icmpOk -or $tcpOk
    $addr = [string]$Identity.ChosenAddress
    $out = [pscustomobject]@{ Code = ''; Headline = ''; Detail = ''; Level = 'info'; Label = $label }

    if ($Identity.NoLease) {
        $apipa = @(@($Identity.NameAnswers.SelfAddresses) | Where-Object { $_ -like '169.254.*' } | Select-Object -First 1)
        $out.Code = 'NoLease'; $out.Level = 'high'
        $out.Headline = ('{0} - ALIVE, NO DHCP LEASE' -f $label)
        $out.Detail = ('The device answered for itself with {0}, a self-assigned address. It is powered on and connected to this network, but it never got an address from DHCP - so nothing outside this segment can reach it, and it cannot reach them.' -f $apipa[0])
        return $out
    }
    if ($responds) {
        if ($Identity.Disagreement -and $Identity.Disagreement.ResolverUsesOther) {
            $out.Code = 'NamePointsElsewhere'; $out.Level = 'medium'
            $out.Headline = ('{0} - REACHABLE, BUT ITS NAME POINTS ELSEWHERE' -f $label)
            $via = [string]$Identity.NameAnswers.ResolverVia
            $out.Detail = ('The device answers at {0}, which is the address it gave for itself. Windows resolves the name to {1} ({2}{3}), so anything that connects by NAME goes somewhere else.' -f $addr, (@($Identity.Disagreement.OtherAddresses) -join ', '), $Identity.Disagreement.OtherName, $(if ($via) { ', ' + $via } else { '' }))
        } elseif (-not $icmpOk) {
            $out.Code = 'ReachablePingBlocked'; $out.Level = 'ok'
            $out.Headline = ('{0} - REACHABLE (PING BLOCKED)' -f $label)
            $out.Detail = ('{0} accepts TCP connections but ignores ping. That is a firewall setting, not a fault.' -f $addr)
        } else {
            $out.Code = 'Reachable'; $out.Level = 'ok'
            $out.Headline = ('{0} - REACHABLE' -f $label)
            $out.Detail = ('{0} answers ping and at least one TCP service.' -f $addr)
            if (-not $tcpOk) { $out.Detail = ('{0} answers ping. None of the ports tried accepted a connection.' -f $addr) }
        }
        return $out
    }
    if ($Identity.SelfAnswered -or $Identity.ArpProvesLife) {
        $how = if ($Identity.SelfAnswered) { 'it answered for itself by name' } else { ('its ARP entry is {0}' -f $Identity.ArpState) }
        $out.Code = 'AliveNotAnswering'; $out.Level = 'low'
        $out.Headline = ('{0} - ALIVE, BLOCKING PING AND THE PORTS TRIED' -f $label)
        $out.Detail = ('It is on this network at {0} - {1} - but it ignored ping and every port tried. Its firewall is blocking them, or the service is not running.' -f $addr, $how)
        return $out
    }
    if (@($Identity.History).Count -gt 0) {
        $h = $Identity.History[0]
        $out.Code = 'LastSeen'; $out.Level = 'medium'
        $out.Headline = ('{0} - NOT ANSWERING, LAST SEEN {1}' -f $label, $h.LastSeenUtc)
        $out.Detail = ('Nothing answered now. The inventory last recorded it at {0}{1} on {2}. It may be off, asleep, moved, or on another network.' -f $h.LastIp, $(if ($h.LastSite) { (' (site {0})' -f $h.LastSite) } else { '' }), $h.LastSeenUtc)
        return $out
    }
    if ($Identity.Kind -eq 'IP' -and -not $Identity.OnLink) {
        $out.Code = 'NotResponding'; $out.Level = 'high'
        $out.Headline = ('{0} - NOT RESPONDING' -f $label)
        $out.Detail = ('{0} is on another network and answered nothing that was tried. The ladder below separates a path problem from a host problem.' -f $addr)
        return $out
    }
    $out.Code = 'NotFound'; $out.Level = 'high'
    $out.Headline = ('{0} - NOT FOUND ON THIS NETWORK' -f $label)
    $out.Detail = 'Nothing answered - not DNS, not the device itself, not ARP. It is off, asleep, or on a different network or VLAN. Asking the device directly (mDNS, LLMNR, NetBIOS) only reaches this machine''s own subnet.'
    return $out
}

function Find-NtNeighbour {
    # Find a host next to the target that answers, so the ladder can tell a
    # broken path from a single broken host - without asking the technician
    # for one.
    #
    # Order: the site profile; not needed at all when the target is on-link;
    # addresses the inventory has seen near the target; then a small set of
    # likely addresses (.1, .254, .2, and the target's nearest neighbours),
    # probed in parallel and capped. It never sweeps a whole subnet.
    #
    # The destination network is only KNOWN if it is supplied. Otherwise the
    # candidates come from an ASSUMED /24, and that is reported: the chosen
    # host's subnet relationship stays unknown to the conclusion engine.
    param(
        [string]$TargetIp,
        [string]$DestinationCidr = '',
        $Profile = $null,
        $Context = $null,
        [int[]]$Ports = @(),
        [int]$MaxCandidates = 16,
        [string]$ProjectDir = '',
        $Shared = $null
    )
    $out = [pscustomobject]@{ Peer = ''; How = 'none'; Detail = ''; Prefix = ''; AssumedPrefix = $false; Candidates = @(); Responders = @(); Tried = 0 }
    if (-not (Test-NtIsIPv4 $TargetIp)) {
        $out.Detail = 'The target has no IPv4 address, so there is no network to find a neighbour on.'
        return $out
    }
    if (-not $Context) { $Context = Get-NtLocalContext }

    if ($Profile) {
        $t = @(@($Profile.targets) | Where-Object { $_.ip -eq $TargetIp } | Select-Object -First 1)
        if ($t.Count -gt 0 -and $t[0].peer) {
            $out.Peer = [string]$t[0].peer; $out.How = 'profile'
            $out.Detail = ('Taken from the site profile ({0}).' -f $Profile.site)
            return $out
        }
    }

    if (Test-NtRangeOnLink -Addresses @($TargetIp) -Context $Context) {
        $out.How = 'not-needed'
        $out.Detail = 'The target is on this machine''s own subnet, so layer 2 answers what a neighbour would: ARP shows whether it is present, and the gateway proves the segment. No comparison host is needed.'
        return $out
    }

    $len = 24
    if ($DestinationCidr -match '^(\d+\.\d+\.\d+\.\d+)/(\d+)$') {
        $givenLen = [int]$Matches[2]        # copy at once: a later -match would clobber $Matches
        if ($givenLen -ge 16 -and $givenLen -le 30) { $len = $givenLen } else { $DestinationCidr = '' }
    } else { $DestinationCidr = '' }
    $out.AssumedPrefix = (-not $DestinationCidr)
    $tInt = ConvertTo-NtUInt32 $TargetIp
    $mask = [uint32]([uint32]::MaxValue -shl (32 - $len))
    $net = [uint32]($tInt -band $mask)
    $bcast = [uint32]($net -bor (-bnot $mask -band [uint32]::MaxValue))
    $out.Prefix = ('{0}/{1}' -f (ConvertFrom-NtUInt32 $net), $len)

    $cands = [System.Collections.Generic.List[object]]::new()
    $seen = @{ $TargetIp = $true }
    $add = {
        param([uint32]$n, [string]$src)
        if ($n -le $net -or $n -ge $bcast) { return }
        $ip = ConvertFrom-NtUInt32 $n
        if ($seen.ContainsKey($ip)) { return }
        $seen[$ip] = $true
        $cands.Add([pscustomobject]@{ Address = $ip; Source = $src })
    }

    # Hosts the inventory has actually seen in this network, most recent first.
    $invHits = [System.Collections.Generic.List[object]]::new()
    foreach ($file in @(Get-NtInventoryFiles -ProjectDir $ProjectDir)) {
        $inv = Read-NtJsonFile -Path $file
        if (-not $inv) { continue }
        foreach ($d in @($inv.devices)) { foreach ($x in @($d.ips)) { if ($x -and $x.ip) { $invHits.Add([pscustomobject]@{ Ip = [string]$x.ip; Seen = [string]$x.lastSeenUtc }) } } }
        foreach ($n in @($inv.ipsWithoutMac)) { if ($n -and $n.ip) { $invHits.Add([pscustomobject]@{ Ip = [string]$n.ip; Seen = [string]$n.lastSeenUtc }) } }
    }
    foreach ($h in @($invHits | Sort-Object Seen -Descending)) {
        if ($cands.Count -ge 8) { break }
        $hi = ConvertTo-NtUInt32 $h.Ip
        if ($null -ne $hi -and (($hi -band $mask) -eq $net)) { & $add $hi 'inventory' }
    }

    # Likely addresses: the gateway-ish ends, then the target's neighbours.
    & $add ([uint32]($net + 1)) 'likely'
    & $add ([uint32]($bcast - 1)) 'likely'
    & $add ([uint32]($net + 2)) 'likely'
    # Fill to the cap. A target at .1 has no neighbours below it, and stopping
    # at +/-6 left only seven candidates for exactly the case that matters -
    # a server at the bottom of its subnet.
    for ($k = 1; $k -le 64 -and $cands.Count -lt $MaxCandidates; $k++) {
        if (($tInt + $k) -lt $bcast) { & $add ([uint32]($tInt + $k)) 'likely' }
        if ($cands.Count -lt $MaxCandidates -and $tInt -gt $k -and ($tInt - $k) -gt $net) { & $add ([uint32]($tInt - $k)) 'likely' }
    }
    $list = @($cands | Select-Object -First $MaxCandidates)
    $out.Candidates = [object[]]$list
    $out.Tried = $list.Count
    if ($list.Count -eq 0) {
        $out.Detail = 'No candidate addresses could be derived for the target''s network.'
        return $out
    }

    if ($Shared) { $Shared.Status = ('Looking for a neighbour of {0} ({1} addresses)...' -f $TargetIp, $list.Count) }
    $probePorts = @(@($Ports) | Select-Object -First 8)
    if ($probePorts.Count -eq 0) { $probePorts = @(443, 445, 3389, 80, 22) }
    # Every candidate and every port at once, one deadline.
    $hosts = @(Test-NtReachableParallel -Addresses @($list | ForEach-Object { $_.Address }) -Ports $probePorts -TimeoutMs 900 -Context $Context |
               Where-Object { $_.Responds } |
               ForEach-Object { [pscustomobject]@{ IP = $_.Address; OpenPorts = [int[]]@($_.OpenPorts); Discovery = $(if ($_.Icmp) { 'ICMP' } else { 'TCP' }) } })
    $out.Responders = [object[]]@($hosts | ForEach-Object { $_.IP })
    if ($hosts.Count -eq 0) {
        $note = if ($out.AssumedPrefix) { ' (assumed to be a /24 - the real mask cannot be seen from here)' } else { '' }
        $out.Detail = ('Probed {0} likely address(es) in {1}{2}; none answered ping or any of the target''s ports.' -f $list.Count, $out.Prefix, $note)
        return $out
    }

    # Best control: answers on the SAME port as the target's service, then any
    # TCP, then ping. Ties go to hosts the inventory knew, then the nearest.
    $scored = foreach ($h in $hosts) {
        $open = @($h.OpenPorts)
        $same = @($open | Where-Object { @($Ports) -contains $_ }).Count -gt 0
        $score = 0
        if ($same) { $score += 4 } elseif ($open.Count -gt 0) { $score += 2 }
        if ([string]$h.Discovery -like 'ICMP*') { $score += 1 }
        $src = [string](@($list | Where-Object { $_.Address -eq $h.IP } | Select-Object -First 1).Source)
        if ($src -eq 'inventory') { $score += 0.5 }
        $dist = [math]::Abs([double](ConvertTo-NtUInt32 $h.IP) - [double]$tInt)
        [pscustomobject]@{ Host = $h; Score = $score; Distance = $dist; Source = $src }
    }
    $best = @($scored | Sort-Object @{ Expression = 'Score'; Descending = $true }, Distance | Select-Object -First 1)[0]
    $out.Peer = [string]$best.Host.IP
    $out.How = if ($best.Source -eq 'inventory') { 'inventory' } else { 'probe' }
    $proof = if (@($best.Host.OpenPorts).Count -gt 0) { ('TCP {0}' -f (@($best.Host.OpenPorts) -join ',')) } else { 'ping' }
    $from = if ($out.How -eq 'inventory') { 'a host the inventory has seen on that network' } else { 'probing likely addresses' }
    $note = if ($out.AssumedPrefix) { (' Chosen from an ASSUMED /24 ({0}); whether it truly shares the target''s network cannot be seen from here.' -f $out.Prefix) } else { (' Chosen from the stated network {0}.' -f $out.Prefix) }
    $out.Detail = ('Found automatically by {0}: {1} answered on {2} ({3} of {4} candidates answered).{5}' -f $from, $out.Peer, $proof, $hosts.Count, $list.Count, $note)
    return $out
}

function ConvertTo-NtInventoryObservations {
    # Everything the identity learned that is worth remembering - the device's
    # own name against its MAC above all - in the shape Update-NtInventory takes.
    param($Identity)
    if (-not $Identity) { return @() }
    $obs = [System.Collections.Generic.List[object]]::new()
    $seen = @{}
    if ($Identity.NameAnswers) {
        foreach ($a in @($Identity.NameAnswers.Answers | Where-Object { $_.SelfAnswer -and $_.Responder })) {
            if ($seen.ContainsKey($a.Address)) { continue }
            $seen[$a.Address] = $true
            $obs.Add([pscustomobject]@{ IP = $a.Address; Mac = [string]$a.Mac; Vendor = ''; Hostname = [string]$Identity.NameAnswers.ShortName; Ttl = 0; OpenPorts = @(); TtlReading = $null })
        }
    }
    if ($Identity.ChosenAddress -and -not $seen.ContainsKey($Identity.ChosenAddress) -and ($Identity.Mac -or @($Identity.Names).Count -gt 0)) {
        $obs.Add([pscustomobject]@{ IP = $Identity.ChosenAddress; Mac = [string]$Identity.Mac; Vendor = [string]$Identity.Vendor; Hostname = [string](@($Identity.Names) | Select-Object -First 1); Ttl = 0; OpenPorts = @(); TtlReading = $null })
    }
    return @($obs.ToArray())
}

function Test-NtReachableParallel {
    # Is anything at these addresses? Every ping and every TCP connect for
    # every address is started at once and judged against ONE deadline.
    #
    # Invoke-NtSweep's worker tries a host's ports one after another, which is
    # right for a big sweep and wrong here: a single silent candidate costs
    # ping + ports x timeout. Measured at seven seconds to choose between two
    # addresses for one PC. This costs one timeout, however many addresses.
    #
    # A refused connect takes about two seconds to surface on Windows, so a
    # port that refuses within the deadline simply reads as not open - which
    # is all this needs to know. Presence proven by a Reachable ARP entry is
    # reported too, for on-link hosts that ignore ping and every port.
    param(
        [string[]]$Addresses,
        [int[]]$Ports = @(),
        [int]$TimeoutMs = 900,
        $Context = $null
    )
    $out = [System.Collections.Generic.List[object]]::new()
    $list = @($Addresses | Where-Object { Test-NtIsIPv4 $_ } | Select-Object -Unique)
    if ($list.Count -eq 0) { return @() }
    if (-not $Context) { $Context = Get-NtLocalContext }

    $pings = @{}
    $conns = [System.Collections.Generic.List[object]]::new()
    try {
        foreach ($a in $list) {
            try {
                $p = New-Object System.Net.NetworkInformation.Ping
                $pings[$a] = [pscustomobject]@{ Ping = $p; Task = $p.SendPingAsync($a, $TimeoutMs) }
            } catch { }
            foreach ($port in @($Ports)) {
                try {
                    $c = New-Object System.Net.Sockets.TcpClient
                    $conns.Add([pscustomobject]@{ Address = $a; Port = [int]$port; Client = $c; Task = $c.ConnectAsync($a, [int]$port) })
                } catch { }
            }
        }
        $tasks = [System.Threading.Tasks.Task[]]@(@($pings.Values | ForEach-Object { $_.Task }) + @($conns | ForEach-Object { $_.Task }))
        if ($tasks.Count -gt 0) {
            # WaitAll throws if any task faulted - a refused or unroutable
            # connect does exactly that - so the outcome is read per task below.
            try { [void][System.Threading.Tasks.Task]::WaitAll($tasks, $TimeoutMs + 150) } catch { }
        }

        $arp = @{}
        try { $arp = Get-NtArpTable } catch { }
        foreach ($a in $list) {
            $icmp = $false; $ttl = 0
            if ($pings.ContainsKey($a)) {
                $t = $pings[$a].Task
                if ($t.Status -eq [System.Threading.Tasks.TaskStatus]::RanToCompletion -and
                    $t.Result.Status -eq [System.Net.NetworkInformation.IPStatus]::Success) {
                    $icmp = $true
                    try { if ($t.Result.Options) { $ttl = [int]$t.Result.Options.Ttl } } catch { }
                }
            }
            $open = @($conns | Where-Object {
                $_.Address -eq $a -and $_.Task.Status -eq [System.Threading.Tasks.TaskStatus]::RanToCompletion -and $_.Client.Connected
            } | ForEach-Object { $_.Port } | Sort-Object -Unique)
            $arpLive = $false; $arpState = ''
            if ($arp.ContainsKey($a)) {
                $arpState = [string]$arp[$a].State
                $arpLive = [bool](Get-NtNeighbourConfidence -State $arpState).ProvesLife
            }
            $out.Add([pscustomobject]@{
                Address   = $a
                Icmp      = $icmp
                Ttl       = $ttl
                OpenPorts = [object[]]$open
                ArpLive   = $arpLive
                ArpState  = $arpState
                Responds  = ($icmp -or $open.Count -gt 0)
                Present   = ($icmp -or $open.Count -gt 0 -or $arpLive)
            })
        }
    } finally {
        foreach ($c in $conns) { try { $c.Client.Close() } catch { } }
        foreach ($p in $pings.Values) { try { $p.Ping.Dispose() } catch { } }
    }
    return @($out.ToArray())
}

# =============================================================================
# 22. Device report - sections and findings built from the identity
# =============================================================================
# The identity (section 20) is evidence; these turn it into what a technician
# reads: a status card, the list of who answered, and the conclusions that
# only a device-centred view can reach - no DHCP lease, a name that points
# somewhere the device is not, a device that has moved.

function Get-NtDeviceAnswerRows {
    # Every answer about the device as one flat list: which source was asked,
    # what came back, and who sent it. The Device tab's grid and the report's
    # "Name answers" section are both built from this.
    param($Identity)
    if (-not $Identity) { return @() }
    $rows = [System.Collections.Generic.List[object]]::new()
    if ($Identity.NameAnswers) {
        foreach ($a in @($Identity.NameAnswers.Answers)) {
            $by = if ($a.Responder) { [string]$a.Responder }
                  elseif ([string]$a.Source -like 'hosts file*') { 'this PC (hosts file)' }
                  elseif ([string]$a.Source -eq 'DNS') { 'DNS server' }
                  else { 'this PC (resolver)' }
            $rows.Add([pscustomobject]@{
                Source = [string]$a.Source; Answer = [string]$a.Address; Name = [string]$a.NameMatched
                AnsweredBy = $by; Interface = [string]$a.Interface
                Mac = $(if ($a.Mac) { Format-NtMac ([string]$a.Mac) } else { '' })
                Ms = [int]$a.Ms; Self = [bool]$a.SelfAnswer; Kind = 'name'
            })
        }
    }
    if ($Identity.Reverse) {
        $rv = $Identity.Reverse
        foreach ($n in @($rv.Names)) {
            $isSelf = [bool]($n.Responder -and [string]$n.Responder -eq [string]$rv.Address)
            $mac = ''
            if ($n.Source -eq 'NetBIOS' -and $rv.NetbiosMac) { $mac = Format-NtMac ([string]$rv.NetbiosMac) }
            $rows.Add([pscustomobject]@{
                Source = ('{0} (reverse)' -f $n.Source); Answer = [string]$n.Name; Name = [string]$rv.Address
                AnsweredBy = $(if ($n.Responder) { [string]$n.Responder } else { 'DNS server' }); Interface = ''
                Mac = $mac; Ms = [int]$n.Ms; Self = $isSelf; Kind = 'reverse'
            })
        }
        # A MAC target lists its ARP entries below; do not repeat them.
        if ($rv.ArpMac -and -not $Identity.MacTarget) {
            $rows.Add([pscustomobject]@{
                Source = 'ARP'; Answer = [string]$rv.Address; Name = ''
                AnsweredBy = ('neighbour cache ({0})' -f $rv.ArpState); Interface = ''
                Mac = (Format-NtMac ([string]$rv.ArpMac)); Ms = 0; Self = [bool]$rv.ArpProvesLife; Kind = 'arp'
            })
        }
    }
    if ($Identity.MacTarget) {
        foreach ($c in @($Identity.MacTarget.Current)) {
            $rows.Add([pscustomobject]@{
                Source = 'ARP'; Answer = [string]$c.IPAddress; Name = ''
                AnsweredBy = ('neighbour cache ({0})' -f $c.State); Interface = ''
                Mac = [string]$Identity.MacTarget.MacFormatted; Ms = 0; Self = [bool]$c.ProvesLife; Kind = 'arp'
            })
        }
    }
    foreach ($h in @(@($Identity.History) | Select-Object -First 5)) {
        if (-not $h) { continue }
        $rows.Add([pscustomobject]@{
            Source = 'Inventory'; Answer = [string]$h.LastIp; Name = (@($h.Hostnames) -join ', ')
            AnsweredBy = ('last seen {0}{1}' -f $h.LastSeenUtc, $(if ($h.LastSite) { (', site ' + $h.LastSite) } else { '' })); Interface = ''
            Mac = [string]$h.MacFormatted; Ms = 0; Self = $false; Kind = 'history'
        })
    }
    return @($rows.ToArray())
}

function Get-NtDeviceSelfAddresses {
    # The addresses the device gave for itself, split into the ones that
    # matter from here and the rest. A multi-homed PC lists every adapter over
    # NetBIOS - Hyper-V and VM switches included - and a headline reading
    # "answers at four addresses" when three of them are unreachable virtual
    # switches is noise. Primary: the ones that answered a probe, else the
    # ones on a subnet this PC shares, else all of them.
    param($Identity)
    $all = @()
    if ($Identity -and $Identity.NameAnswers) { $all = @($Identity.NameAnswers.SelfAddresses) }
    $working = @()
    if ($Identity -and $Identity.Disagreement) { $working = @(@($Identity.Disagreement.Working) | Where-Object { $all -contains $_ }) }
    $onLink = @()
    if ($Identity -and $Identity.NameAnswers) {
        $onLink = @(@($Identity.NameAnswers.Answers) | Where-Object { $_.SelfAnswer -and $_.OnLink } | ForEach-Object { [string]$_.Address } | Select-Object -Unique)
    }
    $primary = if ($working.Count -gt 0) { $working } elseif ($onLink.Count -gt 0) { $onLink } else { $all }
    [pscustomobject]@{
        Primary = [object[]]@($primary)
        Extra   = [object[]]@($all | Where-Object { @($primary) -notcontains $_ })
    }
}

function Get-NtDeviceSections {
    # The "Device" and "Name answers" sections that open every triage report.
    param($Identity, $Status, $Neighbour = $null)
    if (-not $Identity) { return @() }
    $lvl = @{ 'high' = 'fail'; 'medium' = 'warn'; 'low' = 'warn'; 'ok' = 'ok'; 'info' = 'info' }
    $rows = [System.Collections.Generic.List[object]]::new()

    if ($Status) {
        $st = if ($lvl.ContainsKey([string]$Status.Level)) { $lvl[[string]$Status.Level] } else { 'info' }
        $rows.Add((New-NtRow -Group 'Device' -Check 'Status' -Result ([string]$Status.Headline) -Status $st -Detail ([string]$Status.Detail) -Data $Status))
    }
    $kindText = switch ([string]$Identity.Kind) { 'Name' { 'a name' } 'IP' { 'an IP address' } 'MAC' { 'a MAC address' } default { [string]$Identity.Kind } }
    $rows.Add((New-NtRow -Group 'Device' -Check 'Entered as' -Result ('{0} ({1})' -f $Identity.Input, $kindText) -Status 'info'))
    $rows.Add((New-NtRow -Group 'Device' -Check 'Address tested' -Result $(if ($Identity.ChosenAddress) { [string]$Identity.ChosenAddress } else { '(none found)' }) -Status $(if ($Identity.ChosenAddress) { 'info' } else { 'fail' }) -Detail $(if ($Identity.ChosenBecause) { ('Chosen because {0}.' -f $Identity.ChosenBecause) } else { 'No source gave an address for this device.' })))
    if (@($Identity.Names).Count -gt 0) {
        $rows.Add((New-NtRow -Group 'Device' -Check 'Names' -Result (@($Identity.Names) -join ', ') -Status 'info' -Detail 'Names the device gave for itself, names found by reverse lookup, and names the inventory has recorded for it.'))
    }
    if ($Identity.MacFormatted) {
        $macDetail = if ($Identity.ArpState) {
            ('Neighbour cache state {0}: {1}' -f $Identity.ArpState, (Get-NtNeighbourConfidence -State ([string]$Identity.ArpState)).Detail)
        } elseif ($Identity.Reverse -and $Identity.Reverse.NetbiosMac) {
            'Reported by the device itself over NetBIOS - it is not in this PC''s neighbour cache, usually because it is on another subnet.'
        } else { '' }
        $rows.Add((New-NtRow -Group 'Device' -Check 'MAC' -Result ('{0}{1}' -f $Identity.MacFormatted, $(if ($Identity.Vendor) { ' (' + $Identity.Vendor + ')' } else { '' })) -Status 'info' -Detail $macDetail))
    }
    if ($Identity.ChosenAddress) {
        $rows.Add((New-NtRow -Group 'Device' -Check 'Network' -Result $(if ($Identity.OnLink) { 'This subnet (on-link)' } else { 'Another network (routed)' }) -Status 'info' -Detail $(if ($Identity.OnLink) { 'The device shares a subnet with this PC, so it is reached directly - no router is involved, and ARP shows whether it is physically present.' } else { 'Traffic to the device goes through a router, so the path and the far end''s return route both matter.' })))
    }
    $cands = @($Identity.Candidates)
    if ($cands.Count -gt 1) {
        foreach ($c in $cands) {
            $probe = if (-not $c.Probed) { 'not probed' }
                     elseif ($c.Responds) {
                         $how = @()
                         if ($c.Icmp) { $how += 'ping' }
                         if (@($c.OpenPorts).Count -gt 0) { $how += ('TCP ' + (@($c.OpenPorts) -join ',')) }
                         if ($how.Count -eq 0) { $how += 'ARP' }
                         ('answered ({0})' -f ($how -join ', '))
                     } else { 'did not answer' }
            if (-not $c.Probed -and $c.SelfAnswered) { $probe = 'not probed - another of its adapters' }
            $cst = if ($c.Probed -and $c.Responds) { 'ok' } elseif ($c.Probed) { 'warn' } else { 'info' }
            $rows.Add((New-NtRow -Group 'Device' -Check ('Candidate {0}' -f $c.Address) -Result $probe -Status $cst -Detail ('From: {0}.{1}' -f (@($c.Sources) -join ', '), $(if ($c.SelfAnswered) { ' The device gave this address itself.' } else { '' }))))
        }
    }
    if ($Identity.Disagreement) {
        $d = $Identity.Disagreement
        $ps = Get-NtDeviceSelfAddresses -Identity $Identity
        $rows.Add((New-NtRow -Group 'Device' -Check 'Name vs device' -Result ('device: {0}  |  name: {1}' -f (@($ps.Primary) -join ', '), (@($d.OtherAddresses) -join ', ')) -Status 'warn' -Detail ('The device answered for itself with one address; resolving its name ({0}{1}) gives another.{2}' -f $d.OtherName, $(if ($Identity.NameAnswers.ResolverVia) { ', ' + $Identity.NameAnswers.ResolverVia } else { '' }), $(if (@($ps.Extra).Count -gt 0) { (' It also listed ' + (@($ps.Extra) -join ', ') + ' for its other adapters.') } else { '' }))))
    }
    $hist = @($Identity.History)
    if ($hist.Count -gt 0) {
        $h = $hist[0]
        $older = @(@($h.Ips) | ForEach-Object { [string]$_.ip } | Where-Object { $_ -and $_ -ne $h.LastIp } | Select-Object -Unique)
        $rows.Add((New-NtRow -Group 'Device' -Check 'Inventory' -Result ('last seen {0} at {1}' -f $h.LastSeenUtc, $h.LastIp) -Status 'info' -Detail ('First seen {0}.{1}{2}' -f $h.FirstSeenUtc, $(if ($h.LastSite) { (' Site: ' + $h.LastSite + '.') } else { '' }), $(if ($older.Count -gt 0) { (' Earlier addresses: ' + ($older -join ', ') + '.') } else { '' }))))
    }
    if ($Neighbour) {
        $nres = switch ([string]$Neighbour.How) {
            'given'      { ('{0} (given)' -f $Neighbour.Peer) }
            'profile'    { ('{0} (from the site profile)' -f $Neighbour.Peer) }
            'inventory'  { ('{0} (found automatically)' -f $Neighbour.Peer) }
            'probe'      { ('{0} (found automatically)' -f $Neighbour.Peer) }
            'not-needed' { 'Not needed - on this subnet' }
            default      { if ([int]$Neighbour.Tried -gt 0) { ('None found ({0} tried)' -f $Neighbour.Tried) } else { 'None' } }
        }
        $rows.Add((New-NtRow -Group 'Device' -Check 'Neighbour used' -Result $nres -Status 'info' -Detail ([string]$Neighbour.Detail)))
    }
    $devSection = New-NtSection -Name 'Device' -State 'measured' -Method 'The target was identified from every source that can describe it - the device itself, DNS, the hosts file, the neighbour cache and the inventory - and the address to test was chosen by probing the candidates rather than taken from whichever source Windows consulted first.' -Rows @($rows) -Data $Status

    # Who answered.
    $aRows = [System.Collections.Generic.List[object]]::new()
    foreach ($r in @(Get-NtDeviceAnswerRows -Identity $Identity)) {
        $res = if ($r.Name -and $r.Kind -eq 'name') { ('{0}  ({1})' -f $r.Answer, $r.Name) } elseif ($r.Name) { ('{0}  ({1})' -f $r.Answer, $r.Name) } else { [string]$r.Answer }
        $det = ('Answered by {0}{1}{2}{3}.' -f $r.AnsweredBy,
                $(if ($r.Interface) { (' on ' + $r.Interface) } else { '' }),
                $(if ($r.Mac) { (', MAC ' + $r.Mac) } else { '' }),
                $(if ($r.Ms -gt 0) { (' in ' + $r.Ms + ' ms') } else { '' }))
        $det += switch ([string]$r.Kind) {
            'history' { ' A record of the past, not a live answer.' }
            'arp'     { $(if ($r.Self) { ' The cache entry is confirmed, which proves the device is present now.' } else { ' The cache entry is not confirmed, so it only shows the device was here at some point.' }) }
            default   { $(if ($r.Self) { ' This is the device answering for itself.' } else { ' This is a lookup, not the device - it can be stale or point at another path.' }) }
        }
        $aRows.Add((New-NtRow -Group 'Name answers' -Check ([string]$r.Source) -Result $res -Status $(if ($r.Self) { 'ok' } else { 'info' }) -Detail $det -Data $r))
    }
    $ifs = @()
    if ($Identity.NameAnswers) { $ifs = @($Identity.NameAnswers.Interfaces) }
    if ($aRows.Count -eq 0) {
        $aRows.Add((New-NtRow -Group 'Name answers' -Check 'No answers' -Result 'Nothing answered' -Status 'fail' -Detail $(if ($ifs.Count -gt 0) { ('Asked on {0}.' -f ($ifs -join ', ')) } else { 'No connected LAN or Wi-Fi interface was available to ask on.' })))
    }
    $method = switch ([string]$Identity.Kind) {
        'Name' { ('Asked separately and at once: the hosts file, the Windows resolver, DNS alone, mDNS ({0}.local to 224.0.0.251), LLMNR (224.0.0.252) and a NetBIOS broadcast, on {1}. One deadline for all of them.' -f $Identity.NameAnswers.ShortName, $(if ($ifs.Count -gt 0) { ($ifs -join ', ') } else { 'no interface' })) }
        'IP'   { 'Reverse lookups for the address: DNS PTR, and the device''s own mDNS, LLMNR and NetBIOS responders asked directly, plus the neighbour cache.' }
        'MAC'  { 'The neighbour (ARP) cache for that MAC, graded by state, then the inventory''s history.' }
        default { '' }
    }
    $ansSection = New-NtSection -Name 'Name answers' -State 'measured' -Method $method -Rows @($aRows) -Data ([pscustomobject]@{
        Interfaces = [object[]]$ifs
        DurationMs = $(if ($Identity.NameAnswers) { [int]$Identity.NameAnswers.DurationMs } else { 0 })
    }) -Caveats @(
        'mDNS, LLMNR and NetBIOS do not cross routers: a device on another subnet or VLAN can only be found through DNS or the inventory.',
        'Not every device runs every responder - many printers and embedded devices answer none, and Group Policy often disables LLMNR. Silence from one protocol is not absence.'
    )
    return @($devSection, $ansSection)
}

function Get-NtDeviceFindings {
    # Conclusions only a device-centred view can reach. Called by the
    # conclusion engine, and on its own when there is no address to test.
    param($Identity, $Status = $null, [bool]$TargetReachable = $false)
    if (-not $Identity) { return @() }
    $f = [System.Collections.Generic.List[object]]::new()
    $label = Get-NtDeviceLabel -Identity $Identity
    $code = if ($Status) { [string]$Status.Code } else { '' }
    $na = $Identity.NameAnswers

    # --- Alive, no DHCP lease ----------------------------------------------
    if ($Identity.NoLease) {
        $apipa = @($na.SelfAddresses)
        $who = @(@($na.Answers) | Where-Object { $_.SelfAnswer } | ForEach-Object { ('{0} answered {1} from {2}.' -f $_.Source, $_.Address, $_.Responder) } | Select-Object -Unique)
        $f.Add((New-NtFinding -Title ('{0} is switched on, but never got an address from DHCP' -f $label) `
            -Severity 'high' -Confidence 'confirmed' `
            -Summary ('The device answered for itself with {0}. An address in 169.254.x.x is one Windows assigns itself when no DHCP server answers. So the device is powered on and plugged into this network, but nothing beyond this segment can reach it and it cannot reach anything - which is why it looks offline.' -f ($apipa -join ', ')) `
            -Evidence @('Device', 'Name answers') `
            -Basis (@($who) + @('Every address the device gave for itself is in 169.254.0.0/16.')) `
            -Assumptions @('The DHCP failure is inferred from the self-assigned address; the DHCP server itself was not queried.') `
            -Action 'Find out why DHCP did not answer this device: is the DHCP server up, is the scope full, and is the switch port in the right VLAN? A port in the wrong VLAN has no DHCP server to answer. Then renew on the device.' `
            -Commands @('On the device: ipconfig /renew', 'On the DHCP server: Get-DhcpServerv4ScopeStatistics   (PercentageInUse near 100 = scope full)', 'On the switch: check the port''s VLAN against a working PC''s port')))
    }

    # --- The name and the device disagree ----------------------------------
    $dis = $Identity.Disagreement
    if ($dis -and -not $Identity.NoLease) {
        $ps = Get-NtDeviceSelfAddresses -Identity $Identity
        $selfA = @($ps.Primary); $otherA = @($dis.OtherAddresses)
        $hostsRows = @(@($na.Answers) | Where-Object { [string]$_.Source -like 'hosts file*' -and $otherA -contains $_.Address })
        $managed = @($hostsRows | Where-Object { $_.HostsSection } | ForEach-Object { [string]$_.HostsSection } | Select-Object -Unique)
        $dnsHas = (@(@($na.DnsAddresses) | Where-Object { $otherA -contains $_ }).Count -gt 0)
        $where = if ($hostsRows.Count -gt 0) {
            $lines = @($hostsRows | ForEach-Object { ([string]$_.Source) -replace '^hosts file \(', '' -replace '\)$', '' })
            ('a hosts file entry on THIS PC ({0})' -f ($lines -join '; '))
        } elseif ($dnsHas) { ('DNS ({0})' -f $na.DnsName) }
        else { 'the Windows resolver' }
        $selfWorks  = @(@($dis.Working) | Where-Object { @($dis.SelfAddresses) -contains $_ })
        $otherWorks = @(@($dis.Working) | Where-Object { $otherA -contains $_ })
        $probeText = if ($selfWorks.Count -gt 0 -and $otherWorks.Count -eq 0) {
            (' When probed, {0} answered and {1} did not - so connecting by name goes nowhere.' -f ($selfWorks -join ', '), ($otherA -join ', '))
        } elseif ($selfWorks.Count -gt 0 -and $otherWorks.Count -gt 0) {
            (' Both answered when probed, so connecting by name works - but over a different path from the device''s own address (an overlay or VPN, typically), which stops working when that path does.')
        } elseif ($otherWorks.Count -gt 0) {
            (' Only {0} answered when probed.' -f ($otherWorks -join ', '))
        } else { ' Neither answered when probed.' }
        if (@($ps.Extra).Count -gt 0) {
            $probeText += (' It also listed {0} other adapter address(es) ({1}) - usually virtual switches - which this PC cannot reach directly.' -f @($ps.Extra).Count, (@($ps.Extra) -join ', '))
        }
        $sev =if ($selfWorks.Count -gt 0 -and $otherWorks.Count -gt 0) { 'low' } else { 'medium' }

        $action = ''; $cmds = @()
        if ($managed.Count -gt 0) {
            $action = ('The entry sits in a section of the hosts file maintained by {0}, so editing it by hand will be undone. It points at the device''s {0} address. If that path is not wanted for LAN traffic, connect by the LAN address or by {1}.local, or turn off {0}''s DNS handling on this PC.' -f ($managed -join ' / '), $na.ShortName)
            $cmds = @('notepad %SystemRoot%\System32\drivers\etc\hosts', 'ipconfig /flushdns')
        } elseif ($hostsRows.Count -gt 0) {
            $action = 'The hosts file overrides DNS for this name. Comment the entry out, flush the resolver cache, and re-test.'
            $cmds = @('notepad %SystemRoot%\System32\drivers\etc\hosts', 'ipconfig /flushdns')
        } else {
            $action = 'The record is stale or points at another of the device''s interfaces. Have the device re-register itself, check DHCP-to-DNS registration and scavenging, or correct the A record.'
            $cmds = @(('Resolve-DnsName {0} -DnsOnly' -f $na.Query), 'On the device: ipconfig /registerdns', 'ipconfig /flushdns')
        }
        $assume = @()
        if ($hostsRows.Count -eq 0) { $assume += 'A multi-homed device can legitimately be registered in DNS under another interface''s address; that is still worth knowing when connections by name fail.' }
        $f.Add((New-NtFinding -Title ('{0} answers at {1}, but its name points to {2}' -f $label, ($selfA -join ', '), ($otherA -join ', ')) `
            -Severity $sev -Confidence 'confirmed' `
            -Summary ('The device answered for itself at {0}, but {1} sends its name to {2}. Anything that connects by name - mapped drives, shortcuts, the application - goes to {2}.{3}' -f ($selfA -join ', '), $where, ($otherA -join ', '), $probeText) `
            -Evidence @('Device', 'Name answers') `
            -Basis @(('The device answered for itself (mDNS / LLMNR / NetBIOS) with {0}.' -f ($selfA -join ', ')), ('Name resolution returned {0} ({1}).' -f ($otherA -join ', '), $dis.OtherName)) `
            -Assumptions $assume -Action $action -Commands $cmds))
    }

    # --- Not found on this network -----------------------------------------
    # IP targets are left to the ladder: the ARP and neighbour findings say
    # the same thing with more precision.
    if ($code -eq 'NotFound' -and $Identity.Kind -ne 'IP') {
        $ifs = @(); if ($na) { $ifs = @($na.Interfaces) }
        $summary = if ($Identity.Kind -eq 'MAC') {
            ('{0} is not in this PC''s neighbour (ARP) cache and the inventory has never recorded it. A MAC address is only visible from the same subnet.' -f $Identity.MacTarget.MacFormatted)
        } else {
            ('Nothing answered for "{0}": no hosts entry, no DNS record, and no reply to mDNS, LLMNR or NetBIOS on {1}. The device is off, asleep, disconnected, or on a different subnet or VLAN - asking a device directly only reaches this PC''s own subnet.' -f $Identity.Input, $(if ($ifs.Count -gt 0) { ($ifs -join ', ') } else { 'any interface (none was connected)' }))
        }
        $f.Add((New-NtFinding -Title ('{0} was not found on this network' -f $label) `
            -Severity 'high' -Confidence 'probable' -Summary $summary `
            -Evidence @('Device', 'Name answers') `
            -Basis @('Every source was asked and none answered.') `
            -Assumptions @('mDNS, LLMNR and NetBIOS reach this subnet only.', 'Some devices run none of those responders; silence is not proof of absence.') `
            -Action 'Check the device is powered on and connected, and check the spelling. If it lives on another network, target it by IP there - DNS crosses routers, the direct protocols do not.'))
    }

    # --- Known to the inventory, silent now --------------------------------
    if ($code -eq 'LastSeen') {
        $h = $Identity.History[0]
        $f.Add((New-NtFinding -Title ('{0} is not answering - last seen {1}' -f $label, $h.LastSeenUtc) `
            -Severity 'medium' -Confidence 'confirmed' `
            -Summary ([string]$Status.Detail) `
            -Evidence @('Device') `
            -Basis @(('Inventory: last recorded at {0} on {1}{2}.' -f $h.LastIp, $h.LastSeenUtc, $(if ($h.LastSite) { (' (site ' + $h.LastSite + ')') } else { '' })), 'Nothing answered during this run.') `
            -Action 'If it should be here, check power and network. If it has moved sites or networks, target it there.'))
    }

    # --- On the network, ignoring what was tried ---------------------------
    if ($code -eq 'AliveNotAnswering') {
        $f.Add((New-NtFinding -Title ('{0} is on the network but ignores ping and the ports tried' -f $label) `
            -Severity 'low' -Confidence 'confirmed' `
            -Summary ('{0} That is a host firewall or a stopped service, not a network fault - the device is demonstrably present.' -f $Status.Detail) `
            -Evidence @('Device', 'Name answers') `
            -Basis @($(if ($Identity.SelfAnswered) { 'The device answered for itself by name.' } else { ('Neighbour cache state {0}, which proves presence.' -f $Identity.ArpState) })) `
            -Action 'Test a port the device actually serves, or check its firewall. Windows blocks ping by default, and its firewall profile (Public vs Private/Domain) decides which services are reachable.'))
    }

    # --- Moved, or a different device on the address -----------------------
    $alive = ($TargetReachable -or $Identity.SelfAnswered -or $Identity.ArpProvesLife)
    $hist = @($Identity.History)
    if ($alive -and $Identity.ChosenAddress -and $hist.Count -gt 0) {
        if ($Identity.Kind -in @('Name', 'MAC')) {
            $h = $hist[0]
            if ($h.LastIp -and [string]$h.LastIp -ne [string]$Identity.ChosenAddress) {
                $f.Add((New-NtFinding -Title ('{0} has moved since the inventory last saw it' -f $label) `
                    -Severity 'info' -Confidence 'confirmed' `
                    -Summary ('The inventory last recorded it at {0} on {1}; it is at {2} now. DHCP gave it a new address, or it moved networks. Anything configured with the old address - shortcuts, printer ports, firewall rules, reservations - now points at the wrong place.' -f $h.LastIp, $h.LastSeenUtc, $Identity.ChosenAddress) `
                    -Evidence @('Device') `
                    -Basis @(('Inventory: {0} last seen {1}.' -f $h.LastIp, $h.LastSeenUtc), ('Now: {0}.' -f $Identity.ChosenAddress)) `
                    -Action 'If the device needs a stable address, give it a DHCP reservation and update whatever used the old one.'))
            }
        } elseif ($Identity.Kind -eq 'IP' -and $Identity.Mac) {
            $nowMac = ConvertTo-NtNormalMac ([string]$Identity.Mac)
            $others = @($hist | Where-Object { $_.Mac -and (ConvertTo-NtNormalMac ([string]$_.Mac)) -ne $nowMac })
            if ($others.Count -gt 0) {
                $o = $others[0]
                $f.Add((New-NtFinding -Title ('A different device used to have {0}' -f $Identity.ChosenAddress) `
                    -Severity 'info' -Confidence 'confirmed' `
                    -Summary ('{0} now answers with MAC {1}. The inventory recorded {2}{3} at this address before (last seen {4}). If you expected that device, it has moved or been replaced.' -f $Identity.ChosenAddress, $Identity.MacFormatted, $o.MacFormatted, $(if (@($o.Hostnames).Count -gt 0) { (' (' + (@($o.Hostnames) -join ', ') + ')') } else { '' }), $o.LastSeenUtc) `
                    -Evidence @('Device') `
                    -Basis @(('MAC now: {0}.' -f $Identity.MacFormatted), ('Inventory: {0} at this address, last seen {1}.' -f $o.MacFormatted, $o.LastSeenUtc)) `
                    -Action ('Look the earlier device up by name or MAC to find where it went. If both are online, check for an address conflict.')))
            }
        }
    }
    return @($f.ToArray())
}
