# ws1-uem-scripts

PowerShell scripts against the Workspace ONE UEM REST API. Each script solves one job end to end (query + report, or a single remediation action) and ships with its own `README.md` (how to run it) and `DESIGN.md` (why it's built this way, what's confirmed vs. assumed about the API). Shared plumbing — OAuth token acquisition, auth headers, tolerant field resolution — lives once in `shared/` rather than being copy-pasted into every script.

## Folder structure

```
ws1-uem-scripts/
├── README.md                  <- this file
├── CONTRIBUTING.md            <- conventions for adding a new script
├── .gitignore
├── docs/
│   └── api-notes.md           <- cross-script API findings (auth quirks, schema gaps, endpoint gotchas)
├── shared/
│   └── Ws1ApiCore.psm1        <- Get-AccessTokenViaClientCredentials, Get-AuthHeaders, Resolve-Field
├── reporting/                  <- read-only: query the API, produce a report, no changes made to the tenant
│   └── vpp-license-allocation/
│       ├── Get-VppLicenseAllocation.ps1
│       ├── README.md
│       ├── DESIGN.md
│       └── sample-output/
├── remediation/                 <- makes changes: fixes, cleans up, or corrects tenant state
├── automation/                  <- scheduled/triggered workflows, not a one-off report or fix
└── diagnostics/                 <- inspects/dumps raw API data for troubleshooting, no report produced
```

Folders are grouped by **what the script does**, not by which Workspace ONE UEM API family it happens to call (MDM/MAM/System/etc.) — a script's job is more useful for finding it later than which internal API group Omnissa put the endpoint in.

## Script naming

PowerShell's own `Verb-Noun` approved-verb convention, applied consistently:

| Rule | Example |
|---|---|
| Approved verb (`Get-`, `Set-`, `New-`, `Remove-`, `Sync-`, `Repair-`, ...) — run `Get-Verb` to check | `Get-`, not `Fetch-` or `Query-` |
| No redundant `Ws1`/`Uem` prefix — the repo itself is the WS1 context | `Get-VppLicenseAllocation.ps1`, not `Get-Ws1VppLicenseAllocation.ps1` |
| PascalCase noun, no internal hyphens | `VppLicenseAllocation`, not `Vpp-License-Allocation` |
| One script = one job — split reporting from remediation rather than one script that both reports and fixes | `Get-VppLicenseAllocation.ps1` (report) vs. a separate `remediation/` script if a fix action is ever added |

Folders use kebab-case (`vpp-license-allocation/`) paired with a PascalCase script filename inside — the folder name is the human-searchable job name; the filename follows PowerShell's own convention.

## The README + DESIGN pairing (hard rule)

Every script's folder carries both:

- **`README.md`** — usage only. What you need before running it, example commands, what the output columns mean, troubleshooting. Written for whoever's about to run the script, not maintain it.
- **`DESIGN.md`** — technical notes for whoever (human or agent) touches this next: why the logic works the way it does, which fields/endpoints are *confirmed* against a real tenant vs. assumed/speculative, known limitations, extension points.

Splitting these keeps the usage doc short and scannable while still capturing the reasoning that would otherwise get lost the next time someone has to change the script. See `reporting/vpp-license-allocation/` for a worked example of both.

## Shared module

`shared/Ws1ApiCore.psm1` holds the OAuth/field-resolution helpers common to any script hitting the WS1 UEM REST API:

- `Get-AccessTokenViaClientCredentials` — OAuth 2.0 client_credentials token request (client id/secret via HTTP Basic auth header, per the official Bruno collection — not body fields).
- `Get-AuthHeaders` — standard bearer-token header set, with a `-Version` switch for the API's versioned `Accept` header.
- `Resolve-Field` — tolerant, dotted-path property resolver for WS1's inconsistent PascalCase/snake_case/`{Value=X}`-wrapped JSON shapes.

Import it from a script with a `$PSScriptRoot`-relative path, e.g. from `reporting/<script-folder>/`:

```powershell
Import-Module (Join-Path $PSScriptRoot '..\..\shared\Ws1ApiCore.psm1') -Force
```

Add to this module only what's genuinely reusable across scripts — endpoint-specific logic (pagination shape, a particular response schema) belongs in the script itself, not here.

## Cross-script API notes

`docs/api-notes.md` collects findings about the Workspace ONE UEM REST API itself that aren't specific to any one script — auth quirks, gaps in Omnissa's published OpenAPI specs, endpoint behavior confirmed against a live tenant. Check it before re-deriving something from scratch; add to it when a new script turns up something worth remembering.

## Adding a new script

See `CONTRIBUTING.md`.
