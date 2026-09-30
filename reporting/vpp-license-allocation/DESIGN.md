# Design notes — Get-VppLicenseAllocation.ps1

Internal/technical notes for whoever (human or agent) picks this up next. For plain usage instructions, see `README.md` instead. For cross-script API findings that apply beyond just this script, see the repo-level `docs/api-notes.md`.

## Purpose

Query Workspace ONE UEM for all Apple VPP (Volume Purchase Program) apps and their license allocation, and flag apps running low on allocatable licenses — either app-wide, or within a specific smart-group assignment. Output is JSON or XML.

## Why per-assignment, not just app-wide

The original ask was "flag apps with fewer than XX available licenses," which the first version of this script answered purely at the app level (`Purchased - Redeemed`). Follow-up requirements clarified the actual failure mode being watched for: a VPP app's licenses are handed out to devices through smart-group assignments, each with its own `Allocated` reservation carved out of the app's total pool. **A device only receives the app if its own assignment still has unredeemed capacity** (`Allocated > Redeemed` for that one assignment) — not because the app has spare capacity somewhere else, and not because there's unallocated pool capacity sitting unassigned to any group. So an app can look perfectly healthy app-wide (`AvailableLicenses` comfortably above threshold) while one specific assignment is fully exhausted, silently blocking new devices in that group from getting the app.

This is why the report now surfaces, per app: `WorstAssignmentAvailable` (the single tightest assignment) and `AssignmentsBelowThreshold` (how many assignments are at or below threshold), and flags an app if **either** the app-wide figure or any individual assignment trips the threshold.

## Console display vs. JSON/XML field names — deliberately different

The JSON/XML output keeps full, unambiguous property names (`ApplicationName`, `TotalPurchased`, `WorstAssignmentAvailable`, ...) since that's the machine-consumable, canonical artifact. The console tables (`Format-Table`) instead use short calculated-property labels (`App`, `Purch`, `Avail(Grp)`, ...) defined once as `$Col*` hashtables right before the console-output section, purely so the table fits a normal terminal width without wrapping. **The console output does not carry the field definitions with it** — a person looking at a captured/pasted console table days later has no way to recover what `Avail(Grp)` means without also having the source. `README.md`'s "Field reference" table is therefore the single canonical mapping between JSON field, console label, and meaning — keep it in sync if either side changes, and prefer pointing people at that table over re-explaining a column inline in chat or in a commit message.

One correctness note tied to this: `Measure-Object -Minimum` returns `.Minimum` as `[double]` even over integer input, which without an explicit `[int]` cast made `WorstAssignmentAvailable` print as `2.000` instead of `2` in both `ConvertTo-Json` and `Format-Table`. Fixed by casting at the point of computation, not by formatting it away later — worth remembering if a similar `Measure-Object`-derived field is ever added.

## Why the design looks the way it does

This script went through several rounds of "don't assume, verify" per the operating org's data-accuracy policy (never fabricate; unknown = "Data unavailable"; label assumptions). The result is a script whose comments carry a lot of provenance information — where each fact came from and when it was confirmed — rather than reading like typical clean code. That's intentional: a future session (or a future you) should be able to tell at a glance which parts are empirically confirmed against a real tenant versus which parts are still defensive guesses, without re-doing the investigation.

## Sources consulted, and what each one was actually good for

1. **`uem-rest-bruno-2604.zip`** — the official Bruno API-client collection for WS1 UEM REST API version 2604. Good for: exact endpoint paths, HTTP methods, query/path parameter names, and the collection-level OAuth config (grant type, credentials placement). **Not useful for:** response schemas — Bruno request files only capture what you send, never what you get back.
2. **`euc-dev/ws1-uem-apis` GitHub repo** (feeds developer.omnissa.com) — publishes real OpenAPI/Swagger 2.0 files per API group per version (e.g. `docs/versions/2604/mamv1.json`, `mamv2.json`). Checked directly:
   - `mamv1.json` (2604): does **not** contain the PurchasedAppsV1 path group at all. No `/apps/purchased/...` paths, no "vpp" anywhere in the file, despite that group existing in the Bruno collection for the same release. Confirmed absent, not just unchecked.
   - `mamv2.json` (2604): **does** define `GET /apps/purchased/{uuid}` (operationId `PurchasedAppsV2_GetPurchasedApplicationAndAssignments`, confirmed `Accept: application/json;version=2`), but its 200 response schema is `{"$ref":"#/definitions/PurchasedApplicationV2Model"}` and that model name occurs exactly once in the whole file — it's referenced but never defined. A genuine bug/gap in Omnissa's own published spec.
   - Conclusion: neither Bruno nor Omnissa's own OpenAPI specs document the response shape for this endpoint family. This is a real documentation gap, not a shortcut this script is taking.
3. **Live tenant** (via `-DumpRawSample` and `-InspectApplicationId`, 2026-09-28) — the only source that actually resolved field names. Three real responses were captured and are the basis for everything in `$FieldMap`:
   - V1 search (`GET /mam/apps/purchased/search`) — PascalCase, includes a full `ManagedDistribution` block per app.
   - V1 detail (`GET /mam/apps/purchased/{applicationid}`) — PascalCase, `Licenses` block. **Returns 501 Not Implemented for flexible-assignment apps** (confirmed on 2 of 41 apps in the test tenant) — matches that endpoint's own documented caveat ("Not valid for apps implementing flexible assignment").
   - V2 detail (`GET /mam/apps/purchased/{uuid}`) — snake_case, `licenses_summary` block. Confirmed to serve both apps V1 refused.

## Confirmed data model

**Search response** (`ManagedDistribution` block), the primary source for the whole report:
```
ManagedDistribution.Purchased  -> total licenses purchased
ManagedDistribution.Burned     -> licenses redeemed/installed by end users
ManagedDistribution.OnHold     -> licenses on hold
ManagedDistribution.Available  -> Purchased - Burned (the metric used for -LowAllocationThreshold)
```
Confirmed present on **every** app returned by search in the test tenant, including the two flexible-assignment apps whose V1 detail call 501s. This is why the script's default behavior needs only one API call total (the paginated search), not one call per app.

**V1 detail** (`Licenses` block, only reached as a fallback or via `-IncludeAllocationDetail`):
```
Licenses.TotalLicenses       -> matches ManagedDistribution.Purchased
Licenses.Allocated           -> licenses assigned to a smart group (may exceed what's been redeemed)
Licenses.Unallocated         -> purchased licenses not assigned to ANY group yet (stricter "available" notion)
Licenses.Redeemed            -> matches ManagedDistribution.Burned
Licenses.OnHold, Licenses.ExternallyRedeemed
```

**V2 detail** (`licenses_summary` block, snake_case):
```
licenses_summary.total / on_hold / redeemed / allocated / unallocated
```
No direct "available" field (same limitation as V1 detail) — confirmed equal to `total - redeemed` in both inspected samples (55-3=52 and 3-2=1), matching each app's `ManagedDistribution.Available` exactly. Top-level: `uuid`, `organization_group_uuid`, `name`, `identifier`, `adam_id`, `vpp_app_eligibility`, `product_type`, `assignments[]` (keyed by `smart_group_uuid`, each with `deployment_parameters` — richer than V1's `Deployment` block: `allow_management`, `prevent_removal`, `send_application_configuration`, etc.).

## Three distinct "available" concepts — don't conflate them

- **`AvailableLicenses`** (app-wide) = `Purchased - Redeemed`. Answers "how many more times can this app be installed/claimed in total before we run out of purchased licenses."
- **`TotalUnallocated`** = `Purchased - sum(Assignments[].Allocated)`. Licenses purchased but not yet reserved for *any* smart group at all — a free pool an admin could still allocate to a starved assignment, but which does **not** currently help any specific assignment that's already exhausted. An app can show `AvailableLicenses: 2` but `TotalUnallocated: 0` if every purchased license is already allocated to some group, just not yet redeemed.
- **`WorstAssignmentAvailable`** (the one that actually predicts device behavior) = `min(Assignments[].Allocated - Assignments[].Redeemed)` across all of an app's assignments. This is the number that answers "will the next device in a given smart group actually get this app" — and it's derived per-assignment from the search response's own `Assignments` array, confirmed present on every app (see below), no extra API call needed.

Don't use these interchangeably: an app can be fine on two of these and still be actively blocking devices on the third.

## V1 vs V2 for the per-app detail call — the actual reasoning

Originally the script called V1 first (chronological/historical default) and only fell back to V2 on failure. This was flipped after live testing showed:
- V1 **unconditionally fails (501)** for flexible-assignment apps — a wasted round trip every time, plus warning noise.
- V2 has **no observed restriction** — served both apps V1 refused, and its own naming ("New - Get purchased application and assignment details") and lack of any flexible-assignment caveat in its description suggest it's the intended general replacement.
- V2's richer `deployment_parameters` per assignment is a bonus, not a requirement.
- The only reason V1 is kept in the code at all: (a) it has `ExternallyRedeemed`, a field not observed in the V2 sample, and (b) V2's schema, despite being empirically confirmed now, is *also* nowhere formally documented by Omnissa (same dangling-`$ref` problem) — keeping a fallback path costs nothing and hedges against V2 itself regressing for some未-tested app type.

**Recommendation if extending this further:** don't remove V1 entirely. If a future tenant/app type causes V2 to fail unexpectedly, V1 is the safety net. If you want to simplify, the next-safest simplification is dropping V1 for the *default fast path* (search-only) — which the script already does — and only touching this V1/V2 order question inside `-IncludeAllocationDetail` / fallback code, which is already V2-first.

## Platform field — tried, dropped, not worth resurrecting without new evidence

The search response's `Platform` field is a small integer (observed: `2`), not the `"Apple"` string used in the request's `platform` query filter. It was briefly surfaced in the report as a `PlatformName` column, then removed at the user's request ("no value to it") — every app returned the same value (`2`) regardless of whether it looked like a plain iOS app, and no enum for this field exists in the Bruno collection or either OpenAPI spec (`mamv1.json`/`mamv2.json` don't define one — checked). It's plausible WS1 UEM simply doesn't distinguish Apple sub-platforms (iOS/iPadOS/macOS/visionOS) at this field's granularity for VPP/ABM purchases, but that's a hypothesis, not a confirmed fact.

**If this is ever worth resurrecting:** it would need a VPP app whose search record returns a `Platform` value other than `2` to diff against, or a different field entirely (e.g. `SupportedModels`, not observed in any sample so far since it's not returned by default) that might carry real OS targeting. Absent that, don't re-add a `PlatformMap`/friendly-name column — it was tried and added no signal.

## Authentication modes

Three modes via parameter sets, all built through the shared `New-Ws1AuthContext` / `Get-Ws1AuthHeaders` (`shared/Ws1ApiCore.psm1`): OAuth client_credentials (default set), pre-acquired `-AccessToken`, and Basic (`-Credential` + `-TenantCode` -> `Authorization: Basic` + `aw-tenant-code`). Basic follows the UEM API Help "Getting Started" page and the `securityDefinitions` in the published specs; it has not been run against a tenant for this script. OAuth and token modes never send `aw-tenant-code` (not required for OAuth). Version `Accept` headers (V1 for search/detail, V2 for the purchased-app lookup) are set per call by `Get-Ws1AuthHeaders -Version`. This script does not yet use the shared rate limiter / retry (`Invoke-Ws1Request`); it still calls `Invoke-RestMethod` directly, so the "no retry/backoff" limitation below still applies.

## Extension points / where to look first

- **All response field names live in `$FieldMap`** (dotted-path candidate lists, tried in order). If Omnissa changes the schema in a future release, re-run `-DumpRawSample` and/or `-InspectApplicationId`, diff against the confirmed values documented in the script header, and update `$FieldMap` — nothing else in the script needs to change for a pure field-rename.
- **`Resolve-Field`** (now in `shared/Ws1ApiCore.psm1`, imported by this script) supports dotted paths into nested objects (e.g. `ManagedDistribution.Purchased`) and unwraps WS1's occasional `{ Value = X }` wrapper at the final segment. If a future schema nests things differently, this is the function to extend (e.g. array indexing isn't supported yet, only object property traversal). Since it's shared, a change here affects every script that imports the module — check for other consumers before altering its behavior.
- **`Get-AllPurchasedVppApps`**'s list-wrapper detection (`Application`/`PurchasedApps`/`Apps`/`Items`) is itself an unconfirmed guess — the actual wrapper key observed in practice has always just worked via one of these candidates so far, but this was never explicitly logged/confirmed the way the per-app fields were. Worth confirming explicitly if pagination behavior ever looks wrong.
- **`-IncludeRawSourceData`** attaches the complete raw search/detail records per app to the report (`RawSearchRecord`, `RawDetailRecord`, `RawDetailSource`). This is the escape hatch for "I need a field this script doesn't curate" — rather than adding every possible field to the curated summary, point people at this switch and let them pull whatever they need from the raw JSON.

## Known limitations (a plain list, not prose, since it's a reference list not an argument)

- Response schemas are empirically confirmed against one tenant on one release (2604) as of 2026-09-28, not formally documented anywhere by Omnissa. Re-verify after any UEM upgrade.
- `Get-AllPurchasedVppApps`'s response-wrapper key list is a best-effort guess, not confirmed the same rigorous way as the per-app fields.
- V2's schema is empirically confirmed but, like V1, not formally documented by Omnissa — treat both as "confirmed today, re-verify after upgrades," not "guaranteed stable contracts."
- No retry/backoff logic for transient API failures (429/5xx) beyond the specific 501-is-flexible-assignment handling — a genuinely transient failure will just be reported as "Data unavailable" for that app.
- The `ManagedDistribution.Available = Purchased - Burned` formula (and this script's own fallback computation when that field is absent) has only been observed with `OnHold = 0` in every sample. Whether `Available` (or the fallback) also needs to subtract `OnHold` when it's nonzero is unconfirmed — flagged in the script's own comment at the fallback computation.
- `Platform` is deliberately not surfaced in the report at all — see the section above.
