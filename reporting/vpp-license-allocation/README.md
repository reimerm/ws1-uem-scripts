# VPP License Allocation

A PowerShell script that checks your Workspace ONE UEM tenant for Apple VPP (Volume Purchase Program) apps and tells you which ones are running low on allocatable licenses — either app-wide, or within a specific smart-group assignment (the thing that actually determines whether a given device gets the app).

> Not created, reviewed, or endorsed by Omnissa. Run at your own risk — review the script and test in a non-production tenant first. See the [repo-root README](../../README.md) for the full disclaimer.

Part of the `ws1-uem-scripts` repo — see the [repo-root README](../../README.md) for naming/folder conventions and how this script relates to others. For technical/design background on this script specifically (why it's built this way, what's confirmed vs. assumed about the API), see `DESIGN.md`. This file is just "how do I run it."

## What you need before running it

- Your Workspace ONE UEM REST API host name (e.g. `as137.awmdm.com`) — found in the console under **Groups & Settings > All Settings > System > Advanced > API > REST API**, at the Customer OG or below.
- An OAuth 2.0 client with permission to read purchased/VPP app data, set up under **Groups & Settings > Configurations > OAuth Client Management**. You'll need the client ID, client secret, and your datacenter's OAuth token URL (see Omnissa's "Datacenter and Token URLs for OAuth 2.0 Support" documentation).
  - Alternatively, if you already have a valid bearer token from somewhere else, you can pass that directly instead.
- PowerShell 5.1+ (Windows PowerShell or PowerShell 7+, either works).

## Basic usage

Check what your tenant actually returns first (recommended once per environment, and again after any UEM upgrade):

```powershell
.\Get-VppLicenseAllocation.ps1 -ApiUrl as137.awmdm.com `
    -OAuthTokenUrl "https://na.uemauth.workspaceone.com/connect/token" `
    -ClientId "<your-oauth-client-id>" `
    -ClientSecret "<your-oauth-client-secret>" `
    -DumpRawSample
```

Then run a real report:

```powershell
.\Get-VppLicenseAllocation.ps1 -ApiUrl as137.awmdm.com `
    -OAuthTokenUrl "https://na.uemauth.workspaceone.com/connect/token" `
    -ClientId "<your-oauth-client-id>" `
    -ClientSecret "<your-oauth-client-secret>" `
    -LowAllocationThreshold 5
```

This writes `VppAllocationReport_<timestamp>.json` in the current folder and prints a summary, plus a table of any app whose app-wide availability, or any single smart-group assignment, is at or below 5.

If you already have a bearer token, use `-AccessToken` instead of the three OAuth parameters:

```powershell
.\Get-VppLicenseAllocation.ps1 -ApiUrl as137.awmdm.com -AccessToken $token -LowAllocationThreshold 5
```

## Common tasks

**Scope to one Organization Group** (instead of your default scope):
```powershell
... -LocationGroupId 12426
```
or
```powershell
... -OrganizationGroupUuid "3aabd3c8-8190-47ac-8b75-e1f3e7949bca"
```

**Change the threshold** ("the XX" from the original ask):
```powershell
... -LowAllocationThreshold 15
```

**Get XML instead of JSON:**
```powershell
... -OutputFormat Xml -OutputPath C:\reports\vpp.xml
```

**See every app, not just the flagged ones, printed to the console** (the JSON/XML file already has everything regardless — this is just for the console):
```powershell
... -ShowAllInConsole
```

**Get the full raw detail per app** (every field the API returns, not just this script's curated columns):
```powershell
... -IncludeRawSourceData
```
This adds `RawSearchRecord` (always), and `RawDetailRecord`/`RawDetailSource` (only when a detail lookup happened — see `-IncludeAllocationDetail` below) to each app in the JSON/XML output. Note the per-assignment `Assignments` breakdown is already in every report by default (see "What the numbers mean" below) — you don't need this switch just to see it.

**Force a cross-check against the per-app detail endpoint** (the report's numbers are already complete from the search response by default; this is for double-checking, or picking up OnHold/ExternallyRedeemed):
```powershell
... -IncludeAllocationDetail
```

**Combine several of the above** — they all work together:
```powershell
.\Get-VppLicenseAllocation.ps1 -ApiUrl as137.awmdm.com -AccessToken $token `
    -LowAllocationThreshold 5 -IncludeRawSourceData -ShowAllInConsole `
    -OutputFormat Json -OutputPath C:\reports\vpp-full.json
```

**Investigate one specific app** (e.g. after seeing a warning about it):
```powershell
... -InspectApplicationId 32367
```
Prints that app's raw search record and the raw response from both the V1 and V2 detail endpoints, without generating a report. Handy for figuring out why a particular app's numbers look off, or why it triggered a warning.

## Field reference

VPP licenses are handed out to devices through smart-group assignments, each with its own reserved pool carved out of the app's total. **A device only gets the app if its specific assignment still has room** — not just because the app looks fine overall. So the report gives you both the app-wide picture and the per-assignment picture. This table is the canonical definition of every field — the JSON/XML output always uses the "JSON field" name; the console tables (both the flagged-only one and `-ShowAllInConsole`) use the shorter "Console label" instead, purely for screen width, and don't carry these definitions with them — so this table, not a screenshot, is the source of truth for what a column means.

| JSON field | Console label | Meaning |
|---|---|---|
| `ApplicationName` | `App` | The app's display name. |
| `TotalPurchased` | `Purch` | Total licenses bought for this app. |
| `TotalRedeemed` | `Redm` | Of those, how many are actually installed/claimed by an end user, across the whole app. |
| `AvailableLicenses` | `Avail(App)` | `TotalPurchased - TotalRedeemed`. The app-wide "how much room is left in total." |
| `TotalAllocated` | `Alloc` (shown only with `-ShowAllInConsole`) | Sum of licenses reserved across all smart-group assignments — can be less than TotalPurchased if some licenses aren't assigned to any group yet. |
| `TotalUnallocated` | `Unalloc` | `TotalPurchased - TotalAllocated`. Licenses in the free pool, reserved for no group — available for an admin to (re)allocate, but **not currently helping any specific assignment**. |
| `WorstAssignmentAvailable` | `Avail(Grp)` | The tightest individual assignment's own available count (that assignment's `Allocated - Redeemed`). Blank/`-` means the app has no smart-group assignments at all. **Usually the number that actually matters** — see below. |
| `AssignmentsBelowThreshold` | `Grps<=Thr` | How many of the app's smart-group assignments are individually at or below `-LowAllocationThreshold` — at a glance, is it one group or several. |
| `LowAllocation` | `Flag` (`LOW` or blank) | True if *either* `AvailableLicenses` *or* `WorstAssignmentAvailable` is at or below `-LowAllocationThreshold`. This is what puts an app in the "Flagged" table. |
| `Assignments` | *(not in console tables — JSON/XML only)* | The full per-smart-group breakdown behind the numbers above: `SmartGroupId`, `Allocated`, `Redeemed`, `Available`, `IsLow` for each assignment. Drill into this when `AssignmentsBelowThreshold > 0` to see exactly which group(s) need attention. |

**Why `WorstAssignmentAvailable` usually matters more than `AvailableLicenses`:** an app can show `AvailableLicenses: 52` (healthy-looking) while one specific smart-group assignment is fully exhausted (`Available: 0` for that group) — every purchased license is already reserved somewhere, and that one group's reservation is used up. The next device that lands in that group won't get the app, even though the app-wide number looked fine. Buying more licenses helps; reallocating from an under-used assignment to the starved one might also help without buying anything, if another assignment has slack (check `TotalUnallocated` and the individual `Assignments` entries).

### Sample output

From a real tenant, `-ShowAllInConsole` at `-LowAllocationThreshold 5`, filtered here to just the apps whose name ends in "Workspace ONE" plus Intelligent Hub (illustrative subset, not the full run):

```
App                            Purch  Redm  Avail(App)  Alloc  Unalloc  Avail(Grp)  Flag
---                             ----  ----  ----------  -----  -------  ----------  ----
Web - Workspace ONE               55     3          52      5       50           2   LOW
Boxer - Workspace ONE             55     0          55      1       54           1   LOW
Content - Workspace ONE           55     3          52     30       25          27
People - Workspace ONE           100     0         100      0      100           -
Send - Workspace ONE              50     0          50      0       50           -
Cards - Workspace ONE             50     0          50      0       50           -
Smartfolio - Workspace ONE        50     0          50      0       50           -
Tunnel Workspace ONE              50     3          47     20       30          17
PIV-D Manager - Workspace ONE     50     3          47     40       10          37
VMware Workspace ONE              50     0          50      0       50           -
Intelligent Hub                   55     3          52     40       15          10
```

Reading this: Web and Boxer are flagged — both have a smart-group assignment down to 1-2 available, well under the threshold of 5, even though Boxer's app-wide `Avail(App)` is 55. Content, Tunnel, PIV-D Manager, and Intelligent Hub all have real assignments (`Alloc > 0`) but their tightest one (`Avail(Grp)`) is still comfortably above 5, so they're not flagged despite having the same shape of data as the flagged two. People/Send/Cards/Smartfolio/VMware Workspace ONE show `Alloc: 0` and `Avail(Grp): -` — these apps are purchased but not currently assigned to any smart group at all, so there's no per-assignment figure to compute (100% of their licenses sit in `Unalloc`).

## Troubleshooting

**"501 Not Implemented" warning for a specific app:** this is expected for VPP apps using "flexible assignment" — the older allocation-detail endpoint doesn't support them (Omnissa's own documentation says so). The script automatically retries with the newer endpoint for exactly this reason, and in practice this warning doesn't affect your report's numbers, since the search response already has everything needed for the core AvailableLicenses figure. If you want to double-check a specific app, use `-InspectApplicationId <id>`.

**"Data unavailable" / an app is missing counts:** run `-DumpRawSample` and compare the field names it prints against what the script expects (documented in the script's own header comment). Omnissa may have changed the API response shape since this was last verified (2026-09-28, UEM release 2604).

**OAuth token request fails:** double check the token URL is the right one for your datacenter (not just "the" URL — this varies by region), and that the client ID/secret are for an OAuth client (not an old-style API key).

## Where things live

- `Get-VppLicenseAllocation.ps1` — the script.
- `README.md` — this file.
- `DESIGN.md` — technical/design notes for whoever maintains this next.
- `sample-output/` — local scratch space if you want somewhere to point `-OutputPath` while testing; it's git-ignored entirely (see the repo-root `.gitignore`) since report contents include real tenant data (app names, license counts, org name) that shouldn't be committed.
- `../../shared/Ws1ApiCore.psm1` — the OAuth/field-resolution helpers this script imports; shared with other scripts in the repo.
