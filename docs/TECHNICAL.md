# NetTool - technical notes

> The full reference for every tab and check. The [README](../README.md) has the short version. The test suite, the case runbook and the review mentioned below are not part of this release.

An all-in-one network troubleshooter for Windows PowerShell 5.1, built from the notes of a real inter-site case.

Point it at a **device** — a name off the ticket, an IP address, or a MAC address. It finds the
device by asking DNS **and the device itself**, works out which address it really has, then walks
a triage ladder: audits the routing table, reads the hosts file and ARP table,
inventories the gateway's open ports, finds a working neighbour of the target on its own, traces the
path with TTL interpretation, and **tells you what it thinks is wrong and why** — with the evidence
attached so you can disagree with it. Ranges and CIDRs go to Sweep.

It is **read-only** unless you use the Fix button.

---

## Why it exists

The case it was built from took hours because two faults were tangled together:

* **Fault A** — endpoints carried persistent static routes whose next hop (`172.24.7.102`) was a
  main-site address only reachable over the client VPN. Symptom: "it only works on VPN."
* **Fault B** — the firewall source-NATted the client subnet to its own DMZ address, so the far end
  saw connections from `10.50.9.2` and needed a return route for *that*, not for the real subnet.

Both are mechanically detectable from the affected endpoint, and neither was detected. The route
auditor finds Fault A in one click. The conclusion engine reaches Fault B's *shape* — "transport is
proven, the fault is this one host, and if anything translates your source address the far end needs
a return route for the translated one" — from a peer test that takes four seconds.

---

## Quick start

```bash
Launch-NetTool.cmd
```

### Backstage / one-file use

The toolkit is normally three files, because there is exactly one copy of the diagnostic logic and
the GUI is not it. That is right for working on it and wrong for carrying into a ScreenConnect
Backstage session. So build a single self-contained file:

```bash
powershell -NoProfile -ExecutionPolicy Bypass -File Build-NetToolSingleFile.ps1
```

That writes `build\NetTool-Standalone.ps1` (~500 KB, one file, no dependencies). Copy it anywhere —
`C:\temp` is fine — and run it:

```bash
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File NetTool-Standalone.ps1
```

`-STA` matters: WinForms is unreliable without it and the failure is intermittent rather than
obvious. Re-run the builder after any source change; the generated file is not the one under test.

Note that `profiles\`, `baselines\` and `inventory\` are resolved **relative to wherever the file
runs**, so a standalone copy in `C:\temp` will not see the site profiles unless you copy that folder
alongside it.

Then type a device — `RECEPTION-PC02`, `192.168.1.20` or `aa-bb-cc-dd-ee-ff` — and press **Check
device**. Leave **Neighbour (auto)** blank; the tool finds one when it needs one. If a site profile
matches the subnet you are on, it is selected automatically and the target, neighbour, and ports are
pre-filled.

The **window title shows the address this machine is currently sourcing traffic from**, and the kind
of link it leaves by — refreshed every 5 seconds:

```
192.168.1.72 WiFi - NetTool
192.168.1.72 WiFi +VPN - NetTool     a second default route exists, so there is another way out
172.24.7.55 VPN - NetTool
no route - NetTool
```

That is the fact the whole inter-site case turned on, and it changes silently the moment a VPN
connects. In a remote session there is otherwise nothing on screen to tell you which network you
are actually on.

To skip the GUI and drive it from a console:

```bash
powershell -NoProfile -ExecutionPolicy Bypass -Command ". .\NetTool.Helpers.ps1; Set-NtProjectDir -Path .; $r = Invoke-NtPathTriage -Target RECEPTION-PC02; $r.device.Headline; $r.findings | Format-List title,summary"
```

`-Peer` still overrides the automatic neighbour; `-NoAutoNeighbour` turns the search off for
scripted runs; `-DestinationCidr 10.60.100.0/23` states the target's network so the neighbour
comparison becomes a control test instead of an assumption.

---

## Checking a device

Windows resolves a name by asking whichever source answers first and throws away who answered. On a
PC running Tailscale that returned the **overlay** address from a Tailscale-managed hosts entry for a
machine sitting on the same Wi-Fi — so "unreachable" was about the wrong address. And a PC that never
got a DHCP lease sits on `169.254.x.x`, ignores ping, and is invisible to DNS.

So the name is asked of every source **separately and at once**, against one ~1.2 s deadline:

| Source | Asked how | Is the answer the device itself? |
|---|---|---|
| hosts file | read, with the line number and **which product manages that section** (Tailscale, Docker Desktop) | no |
| Windows resolver | what an application would get | no |
| DNS | `Resolve-DnsName -DnsOnly -NoHostsFile` | no — can be stale or an overlay |
| mDNS | `NAME.local` to 224.0.0.251:5353 | **yes** |
| LLMNR | `NAME` to 224.0.0.252:5355 | **yes** |
| NetBIOS | name query, subnet broadcast :137 | **yes** — and lists every adapter |

They are complementary: on the test LAN one PC answered LLMNR only, the NAS mDNS only, another PC
both. An **IP** is looked up in reverse the same way (DNS PTR, the device's own mDNS/LLMNR, NetBIOS
node status — which also reports its MAC). A **MAC** is found in the neighbour cache, graded by state
(`Reachable` proves it is there now; `Stale` only that it was), then in the inventory's history.

When the sources disagree, every candidate address is probed at once and the one that answers is
tested. The **Device** tab shows the answer in one line, and who said what:

| Status | Means |
|---|---|
| REACHABLE / REACHABLE (PING BLOCKED) | It answers; a blocked ping is a firewall setting, not a fault |
| ALIVE, NO DHCP LEASE | It answered for itself with 169.254.x.x — powered on and plugged in, but DHCP never reached it |
| REACHABLE, BUT ITS NAME POINTS ELSEWHERE | It answers at one address; its name resolves to another (and it says which source is responsible) |
| ALIVE, BLOCKING PING AND THE PORTS TRIED | Present (it answered by name, or ARP proves it) but ignoring what was tried |
| NOT ANSWERING, LAST SEEN date | Silent now; the inventory knows where it was |
| NOT RESPONDING | A routed address that answered nothing — the ladder separates path from host |
| NOT FOUND ON THIS NETWORK | Nothing answered anywhere |

**The neighbour is automatic.** "Does another machine on the target's network answer?" is the
strongest test in the ladder, and nobody should have to know that to get it. When the target is on
this PC's own subnet it is not needed (ARP and the gateway already answer the question). Otherwise
the tool takes the site profile's neighbour, else addresses the inventory has seen near the target,
else up to 16 likely addresses (`.1`, `.254`, `.2`, then the target's nearest), probed in parallel.
It prefers one that answers **the same port** as the target. Without `-DestinationCidr` the
candidates come from an **assumed /24**, the report says so, and the subnet relationship stays
*unknown* to the conclusion engine — no certainty is invented.

---

## Verifying a change

The regression suite is not part of this release. The builder is a gate of its own:

```bash
powershell.exe -NoProfile -ExecutionPolicy Bypass -File Build-NetToolSingleFile.ps1
```

Run it after any change to the sources. The builder now **builds to a temporary file,
validates, and only then promotes it** - it used to overwrite the artefact first and check
afterwards, so a build that failed its own gate still replaced a working copy with a broken one.
Its gates are: the generated file parses; `NetTool.Helpers.ps1` parses and is **pure** (nothing
executes at load, because it is re-created from text inside every background runspace); and the
embedded helper text is **byte-identical** to the source.

That last gate matters more than it sounds. `build\NetTool-Standalone.ps1` is a full generated
duplicate of all three sources, so without it a fix to the sources ships as a no-op - and the first
time the check ran it caught exactly that, with the standalone 4,256 characters behind.

## What the tests are for

They are not coverage for its own sake. An internal review's central finding is that this tool stated
conclusions its evidence did not support, so most of the suite asserts the **shape of a
conclusion** rather than a number:

| Rule | Why |
|---|---|
| An untested endpoint never reads as a failed one | A cancelled sweep reported its input count as "probed", so addresses nothing was sent to appeared as silent hosts |
| A cancelled run never reads as a completed one | `Invoke-NtPathTriage` had no cancel checks at all; `Test-NtIcmp` returns `Success = $false` on cancel, which is indistinguishable from a real failure, and the GUI then said "Triage complete." |
| A collection error never reads as a finding about the network | A name that failed to resolve produced `critical` / `confirmed` **"Windows has no route at all for this destination"** |
| A conclusion cites what it rests on | `New-NtFinding` gained `basis` and `assumptions`. The host-specific verdict asserted "same subnet, same transport, same rules" while the four measurements that establish it sat computed-but-unread 300 lines away |
| Unknown stays unknown | Subnet membership was a three-octet string comparison - a `/24` assumption - defaulting to `true` when no peer was given. It now takes an explicit destination CIDR and returns `$null` when the mask is not known |
| A neighbour-cache state is read, not just stored | Every state counted as proof of life, so an `Unreachable` entry - a recorded resolution *failure* - was reported as "powered on and connected" |
| A banner does not outrank the finding | Two default routes - Ethernet and Wi-Fi via one gateway - raised a `high` "an alternate path is live" that dominated every real result, and put `+VPN` in the window title with no VPN present |
| You export the run you are looking at | Export preferred the triage unconditionally, so triage-then-sweep wrote a file named for one investigation containing another |
| A socket error is evidence | Refused, timed out and unreachable collapsed into "closed or filtered" - and the wait-handle pattern underneath was never signalled on failure, so every closed port cost a full timeout and was reported as a timeout whatever happened |
| Input is never silently substituted | Bad port tokens were dropped without a word, and an all-bad list fell back to a default set - testing ports nobody named |
| A baseline says whether it saved | Save ignored its own `Ok` flag; compare read `.data` without checking `.state`, so a **missing** baseline reported "No route changes since the baseline" |
| A profile is a stated fact, not a measurement | A real site profile flagged its own application port `UNCONFIRMED` and that never reached the operator; the profile dropdown had no change handler at all |
| A route is identified by its interface too | Store matching keyed on prefix + next hop, but Ethernet and Wi-Fi hold identical default routes via one gateway - so two routes collided on one key and the Active/PersistentOnly distinction was decided by lookup order |
| Windows' own selection wins; ours is labelled inferred | The manual fallback took the first longest-prefix match regardless of metric, picking 500 over 1, and never filled in a source address |
| A long chain is not a loop | Eight hops deep was reported as "the static routes point at each other"; a loop is now a next hop that actually repeats, and a reachable inner chain is no longer rejected by the outer recursion |
| A TTL reading is an estimate | The initial TTL is not in the packet - it is guessed by rounding up to the nearest default - yet the hop count and OS class were stated as proven, and the last hop that *answered* was called a demarcation point |
| A resolution difference is not an override | Two sequential lookups disagreeing became a confirmed local override, though a load balancer or geo-steered CDN answers differently between queries by design |
| Every comparison dimension reaches the verdict | Added routes, metric changes and adapters appearing produced rows but never reached `Proofs`, so the verdict could read "nothing changed" above a visible list of changes |
| A local source address is not a far-end one | A changed source was described as what the far end sees, though NAT can map both to one address |
| A MAC is not a device identity | An IP-to-MAC change became a high-severity hardware replacement, despite DHCP, HA failover, hypervisors and MAC randomisation all producing that evidence untouched |
| Nothing is printed to a raw socket | Banner grabbing sent `HEAD / HTTP/1.0` to port **9100**, which a printer can accept as print data |

## Files

| File | Role |
|---|---|
| `NetTool.Helpers.ps1` | **All** logic. Function definitions only, no side effects at load. |
| `NetTool-Gui.ps1` | WinForms GUI: UI, background workers, rendering, export. |
| `Launch-NetTool.cmd` | Launcher. Forces `-STA`, which WinForms requires. |
| `NetTool_HTML_Report.ps1` | **Render only.** Report object or exported JSON to a single HTML file. Run it with no arguments for a file picker. |
| `Launch-NetTool-Report.cmd` | Launcher for the report picker (forces `-STA`). |
| `Build-NetToolSingleFile.ps1` | Builds `build\NetTool-Standalone.ps1` — one self-contained file. |
| `profiles\_template.json` | Documented blank site profile. Files starting with `_` are ignored by the loader. |
| `baselines\` | Saved route-table and traceroute snapshots, one file per site. |
| `inventory\` | Project rollup of the IP/MAC inventory, one file per site. |

The helpers file is loaded as **text** and rebuilt inside each background runspace, so the UI thread
and every worker share one definition. There is exactly one copy of the diagnostic logic and it is
not in the GUI.

---

## What each tab does

**Device** (opens after every check) — the one-line status, a paragraph saying what it means, a
**How it was found** grid (Source | Answer | Name | Answered by | Interface | MAC | ms; green rows
are the device answering for itself), and the device's facts: the address tested and why, names,
MAC and vendor, on-link or routed, every candidate address with its probe result, inventory
history, and which neighbour was used and how it was chosen. The banner above the tabs carries the
same status, with the top finding underneath.

**Triage** — the triage ladder (rungs 0–7), then the conclusions. Rungs record the first failure
but the ladder does not stop there: the later rungs are exactly what separates "the transport is
broken" from "the transport is fine and one host has no return route".

**Routes** — every route with a verdict, and a **Store** column that matters more than it looks:

| Store | Meaning |
|---|---|
| `Active` | In the forwarding table. Steering traffic now. |
| `Both` | In the forwarding table *and* persistent. Steering traffic now, and survives a rebuild. |
| `PersistentOnly` | Configured but **not installed**. Cannot be affecting anything today. |

That last row is the distinction most route audits get wrong. `route print`'s Persistent Routes
section does **not** prove a route is active — Windows can hold a persistent route it has not
installed. A `PersistentOnly` route with a hopeless next hop is reported as **configuration
residue at medium severity**, explicitly not as the current fault, because treating it as one sends
you after the wrong thing. It is still worth removing, and the tool still gives you the command:
it may activate when a VPN comes up, and the rest of the fleet probably carries it too.

`StaleUnreachable` means an **active** route whose next hop cannot be delivered to. `VpnDependent`
means it is only on-link while some interface is up. Next-hop resolution **follows the chain**, so a
route whose next hop is itself reached through another broken static route is reported as such
rather than just "not on-link".

Every route is also read against **the interface it is bound to**, which answers questions a route
table alone cannot:

| Binding | Meaning |
|---|---|
| `OrphanedInterface` | Bound to an interface index that no longer exists. **Can never install** — delete it, no VPN test needed. |
| `BoundToDisconnected` | The interface exists but is disconnected. **Will** install when it comes up; if it is a VPN adapter, that is your "only works on VPN" mechanism, established from a single snapshot. |
| `MisboundNextHop` | Installed on a connected interface whose subnets do not contain the next hop. It is in the table and still cannot deliver — usually added against the wrong adapter. |
| `DhcpSupplied` | Pushed by DHCP option 121. **No delete command is offered**: deleting it locally looks like it worked and it returns at the next lease renewal. Fix the scope. |

The grid also shows `TotalMetric` (route metric + interface metric), which is what Windows actually
compares when two routes could carry the same traffic.

**Path** — traceroute with the reply TTL kept. Initial TTL tells you the OS class (64 = Linux or
appliance, 128 = Windows, 255 = network gear); the delta tells you the hop count.

**Names and ARP** — hosts file and lmhosts entries with line numbers, the target resolved both
normally and with `-DnsOnly -NoHostsFile` (a difference is a local override), NRPT rules, and the
ARP table with vendors and collisions.

**Gateway** — TCP connect scan of management ports plus HTTP/TLS/SSH banners, and an appliance
identification from the OUI and certificate.

**Interfaces** — every IPv4 interface, **including disconnected ones and loopback**, with kind
(WiFi / LAN / VPN / WWAN / Virtual), connection state, addresses, metric, MTU, DHCP and DNS. The
Endpoint summary deliberately shows only what is Up and addressed; this is the view you need when
reasoning about a dormant route, because the disconnected VPN adapter it is bound to is exactly what
the summary hides. Populated at startup, with a Refresh button.

**Neighbour** (filled when a neighbour was given or found) — the two hosts side by side across selected
route, next hop, **source address**, interface, ICMP, and each TCP port. The neighbour is probed the
*same way* as the target, not with ping alone: a Windows host that blocks ICMP but serves the port
is healthy, and treating it as dead used to produce a confident "the whole subnet is unreachable".
The rows that **match** are the valuable ones — identical route and identical source address rule
the workstation out as the difference between the two hosts.

**VPN A/B** — capture the state, change one thing (connect or disconnect the VPN), capture again.
Answers the two questions a single snapshot never can: did a persistent route become **active**, and
did the **source address the far end sees** change? Findings are ordered by how much they prove.

**Sweep** — expand a range, probe it, and merge the results into the inventory.

**Inventory** — cross-match findings across runs.

### Rendering a saved report later

Export JSON on site, render it back at the desk:

```bash
Launch-NetTool-Report.cmd
```

Pick the JSON (or drag one onto the window). It summarises what you loaded — target, verdict,
when it was captured, how many findings — **before** rendering, so you notice if you picked the
wrong capture. Then Render, and it opens.

Command line, same thing:

```bash
powershell -NoProfile -ExecutionPolicy Bypass -File NetTool_HTML_Report.ps1 -JsonPath report.json -Open
```

Only a **triage** export renders (`schema: nettoolkit-report/1`). Sweep results, VPN A/B snapshots
and the inventory are different shapes; the picker says so rather than producing an empty page.

**Escalation** — a paste-ready demarcation summary: what is proven working (with TTLs and timings),
what is **ruled out**, the single thing that fails, specific vendor questions, and the commands to
run on the edge device.

---

## The inventory

Every sweep (and every device check — the device's own name against its MAC, plus the ARP table)
merges into two JSON files. That name/MAC pairing is what lets a later check by name say "not
answering, last seen 12 Aug at 192.168.1.20" instead of "not found":

* `C:\ProgramData\NetToolkit\inventory.json` — everything this machine has ever seen.
* `inventory\<site>.json` — the project rollup, which travels between sites.

Keyed by **MAC**, because that is what identifies a device across address changes. Hosts with no MAC
go in a separate `ipsWithoutMac` collection — an off-link host can never yield a MAC, and inventing
a placeholder key for it would corrupt every cross-match that follows.

Cross-matching then answers:

| Finding | Means |
|---|---|
| `DeviceReplaced` | Same IP, different MAC than last time. **Catches an edge router being swapped.** |
| `DeviceMoved` | One MAC has held several addresses. |
| `MultiSite` | One MAC seen at several sites — a roaming laptop, or your site labels are wrong. |
| `LiveDuplicateMac` | One MAC answering for several addresses right now. Proxy ARP, or a conflict. |

---

## Site profiles

A profile lets someone who has never seen the site run the triage properly. Copy
`profiles\_template.json`, fill it in, and it is auto-selected whenever this machine has an address
inside its `lanSubnets`.

The highest-value field is **`targets[].peer`** — another host on the *destination* subnet that is
known to answer. It is what collapses "something is broken between here and there" into "one host is
misconfigured". Without it the tool searches for a neighbour itself, but a machine you *know* runs
the same service is a better control than one that merely answered a probe. The tool checks the
neighbour really is on the target's subnet and refuses to draw the conclusion if it is not.

`knownNat` is the other one that matters. Source NAT **cannot be observed from an endpoint**, so
recording it in the profile is what lets the tool tell you which address the far end must have a
return route for.

---

## Read this: what this tool cannot see

* **It cannot see source NAT.** Nothing on an endpoint can observe a translation performed
  downstream. Where the evidence points that way, the tool says so explicitly and hands you the
  firewall-side commands that *would* show it. It never claims to have measured it.
* **It cannot read the firewall log.** Rung 3 (the firewall log) is missing by necessity; the escalation
  summary carries the commands instead.
* **A connect scan cannot tell closed from filtered**, and it cannot see UDP services at all.
* **A persistent route is not necessarily an active one.** The tool reports the two separately and
  will not blame a route that Windows has not installed. If you need to know whether one activates
  when the VPN comes up, that is what the VPN A/B tab is for — nothing else can answer it.
* **TLS**: the gateway probe records the certificate subject and the *negotiated* protocol version.
  It does not probe whether legacy TLS 1.0/1.1 are still accepted. Note that capping a handshake
  below TLS 1.2 against current SFOS fails for reasons unrelated to reachability, so
  `curl --tls-max 1.1` is a hardening test, not a connectivity one.
* **ARP only describes directly connected subnets.** For an off-link range, a host that silently
  drops ICMP is invisible, and the sweep says so in its caveats rather than reporting it as down.
* **A failed ping to a firewall proves nothing.** In the original case the appliance was routing,
  serving DHCP, and answering HTTPS on 4444 while dropping ICMP to itself. The gateway tab reports a
  failed ping as information, never as a fault.
* **A silent traceroute hop is not a fault.** Plenty of routers do not answer TTL expiry.
* **Asking a device directly only reaches this PC's own subnet.** mDNS, LLMNR and NetBIOS
  broadcasts do not cross routers, so a device on another VLAN can only be found through DNS or the
  inventory. And not every device runs every responder — many printers answer none, and Group
  Policy often disables LLMNR — so silence from one protocol is not absence.
* **The automatic neighbour is a probe result, not a known-good host.** It answered, which proves
  the path to it; it does not prove it runs the target's service or shares its mask.

**And the big one:** if a VPN or overlay adapter is up **and the route Windows chose for the target
uses it**, every conclusion is provisional and a high banner says so. With a second path to the
destination live, a successful test proves nothing about the path you are trying to fix. When the
selected route leaves by another interface — an on-link device on Wi-Fi while Tailscale idles
alongside — it is recorded as a low note instead, because the measured route is the authority.

---

## Operational cautions

* Port-sweeping a customer network can trip IDS and EDR. Ranges above **1024 addresses** are
  refused unless you confirm the prompt.
* The GUI needs an interactive desktop. Under SYSTEM with no desktop there is nothing to draw on —
  use a ScreenConnect Backstage session.
* Remediation needs elevation and confirms every action individually. The hosts file is backed up
  before it is edited; route deletions are not automatically reversible.

---

## Not included

There is **no Atera collector**, so a fleet-wide persistent-route audit is not covered —
the route auditor runs one machine at a time from the GUI. Given that stale
routes are probably on other machines too, this is the obvious next addition. All the logic lives in
the helpers file with no side effects at load, so a headless collector is a thin wrapper rather than
a rewrite.

---

## Requirements

Windows PowerShell 5.1. No modules, no internet (OUI vendor lookups are best-effort and cached in
`C:\ProgramData\NetToolkit\oui-cache.json`; without internet every vendor simply reads `Unknown`).
Elevation is optional and only needed for remediation.
