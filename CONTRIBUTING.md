# Contributing a new script

## Before writing code

- **No fabricated fields or endpoints.** Every endpoint path, auth mechanism, query param, and response field this repo relies on should be confirmed against either the official Bruno collection for the target UEM release, a live tenant response (e.g. via a `-DumpRawSample`-style diagnostic switch), or both. Omnissa's own published OpenAPI specs (euc-dev/ws1-uem-apis) have known gaps for some endpoint families — don't treat "it's not in the spec" as "it doesn't exist," and don't treat "it's in the spec" as confirmed without a live check if the spec has been wrong before. Where something is genuinely unconfirmed, say so explicitly in the script's header comment and in `DESIGN.md` rather than presenting a guess as fact.
- Check `docs/api-notes.md` first — someone may have already confirmed (or ruled out) the thing you're about to re-derive.
- Decide which top-level folder the script belongs in (see the root `README.md`) based on what it *does*, not which UEM API family it calls.

## Naming

- `Verb-Noun.ps1`, approved verb only (`Get-Verb` lists them).
- No `Ws1`/`Uem` prefix on the filename — redundant inside this repo.
- PascalCase noun, no internal hyphens in the filename; the containing folder is kebab-case.
- One script, one job. If a reporting script's logic naturally wants to also fix something it finds, that's two scripts, not one — put the fix in `remediation/` and have it (optionally) consume the report's output rather than folding both concerns into a single file.

## Required files per script folder

```
<category>/<script-name-kebab-case>/
├── <ScriptName>.ps1
├── README.md      <- usage only: prerequisites, example commands, output/column meanings, troubleshooting
└── DESIGN.md       <- technical notes: why it works this way, confirmed vs. assumed, known limitations, extension points
```

Both docs are mandatory, not optional — a script without them isn't done yet.

## Script header (comment-based help)

Every script should have a standard PowerShell comment-based help block so `Get-Help .\Script.ps1 -Full` works without needing to open the source:

```powershell
<#
.SYNOPSIS
    One line: what this script does.

.DESCRIPTION
    What it does, in more detail — endpoints called, auth model, key logic decisions
    a reader needs up front. Point to DESIGN.md for the full reasoning rather than
    duplicating it here.

.PARAMETER SomeParam
    What it's for, valid values/defaults, and where in the WS1 console/API docs
    to find the value if it's something the user has to look up.

.EXAMPLE
    .\Script.ps1 -SomeParam value
#>
```

## Using the shared module

If your script needs OAuth token acquisition, standard auth headers, or tolerant field resolution, use `shared/Ws1ApiCore.psm1` rather than re-implementing it:

```powershell
Import-Module (Join-Path $PSScriptRoot '..\..\shared\Ws1ApiCore.psm1') -Force
```

Only add genuinely cross-script-reusable logic to the shared module itself. Anything specific to one endpoint's response shape or pagination behavior belongs in the script.

## PR checklist

- [ ] Script lives in the right category folder, named per the conventions above.
- [ ] `README.md` and `DESIGN.md` both present and filled in (not just copied from another script and left unedited).
- [ ] Comment-based help block present and accurate.
- [ ] Every endpoint/field/param the script depends on is either confirmed (say how — Bruno collection, live tenant dump, etc.) or explicitly flagged as unconfirmed/speculative.
- [ ] No secrets (client secrets, tokens, real tenant hostnames) committed — use placeholders in examples and docs.
- [ ] Generated output files (reports, dumps) are covered by `.gitignore` — real tenant data (app names, license counts, org identifiers) is never committed. If a sample is genuinely useful in docs, hand-write a small redacted/synthetic snippet directly in the README instead of committing a real report file.
- [ ] If you added or changed something in `shared/Ws1ApiCore.psm1`, checked for other scripts that import it and confirmed you haven't broken them.
- [ ] If you learned something about the API worth remembering beyond this one script, added it to `docs/api-notes.md`.
