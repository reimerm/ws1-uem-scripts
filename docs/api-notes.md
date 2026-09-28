# Workspace ONE UEM REST API — cross-script notes

Findings about the API itself (not specific to any one script) confirmed while building scripts in this repo. Confirmed against UEM release **2604** unless noted otherwise; re-verify after any tenant upgrade before trusting these across a version boundary.

## Auth

- **OAuth 2.0, `client_credentials` grant.** Client id/secret are sent as an HTTP Basic `Authorization` header on the token request — **not** as `client_id`/`client_secret` fields in the request body. Confirmed via the official Bruno collection's collection-level auth config (`auth:oauth2`, `credentials_placement: basic_auth_header`). Only `grant_type=client_credentials` goes in the body.
- No `aw-tenant-code` / legacy API-key header is used anywhere in the validated Bruno collection — OAuth bearer token only.
- Base URL shape: `https://<YourApiServer>/api` — lowercase `api`, confirmed via the Bruno collection's `basePath`/pre-request variables.

## Query params (MAM Purchased Apps search)

- `locationgroupid` (integer Organization Group id) and `organizationgroupuuid` (string OG UUID) are separate, correctly-named params — there is **no** `organizationgroupid` param (easy typo to make).
- `platform`, `page`, `pagesize` confirmed present; other documented-but-unverified-by-us params on this endpoint: `applicationname`, `isassigned`, `bundleid`, `model`, `status`, `orderby`.

## Omnissa's published OpenAPI specs have real gaps (euc-dev/ws1-uem-apis, 2604)

Confirmed by direct inspection of `docs/versions/2604/mamv1.json` and `mamv2.json` in that repo (which feed developer.omnissa.com):

- `mamv1.json` has **zero** Purchased Apps paths for 2604, despite those endpoints existing and working (per the Bruno collection and live tenant calls).
- `mamv2.json` references a `PurchasedApplicationV2Model` via `$ref` for the V2 purchased-app response, but **never defines it** — a dangling reference. The V2 response schema below was reverse-engineered from live tenant responses, not from this spec.

Treat "not in the spec" as inconclusive, not as "doesn't exist," for this endpoint family. Always cross-check against a live tenant response before relying on a field.

## Purchased VPP apps — confirmed response shapes (live tenant, 2026-09-28)

**V1 search** — `GET {base}/mam/apps/purchased/search` (`Accept: application/json;version=1`):
top-level `ApplicationName, BundleId, Platform (int), LocationGroupId, OrganizationGroupUuid, RootOrganizationGroupName, Id.Value, Uuid, AppType`, plus `ManagedDistribution.{Purchased, Burned, OnHold, Available, AppLicenseEligibility}` and an `Assignments[]` array (`SmartGroupId, LocationGroupId, Users, Allocated, Redeemed, AssignmentRuleType, Status`) — confirmed present on every app returned, including flexible-assignment apps.

**V1 detail** — `GET {base}/mam/apps/purchased/{applicationid}` (`version=1`):
`Licenses.{TotalLicenses, OnHold, Allocated, Unallocated, Redeemed, ExternallyRedeemed}`, `Assignments[]`, `Deployment{}`. **Returns `501 Not Implemented` for apps using flexible assignment** — this is documented as the endpoint's own limitation ("Not valid for apps implementing flexible assignment"), not a bug; confirmed 2 out of 41 apps in one tenant's catalog.

**V2 detail** — `GET {base}/mam/apps/purchased/{uuid}` (`version=2`, `operationId PurchasedAppsV2_GetPurchasedApplicationAndAssignments`):
snake_case — `uuid, organization_group_uuid, name, identifier, adam_id, vpp_app_eligibility, product_type, categories`, `licenses_summary.{total, on_hold, redeemed, allocated, unallocated}` (no direct "available" field — confirmed equal to `total - redeemed` in every inspected sample), `assignments[]` (`smart_group_uuid, is_active, allocated, redeemed, deployment_parameters{...}`). Confirmed to serve both of the apps V1 refused, with richer per-assignment `deployment_parameters` than V1's `Deployment` block.

**V1 vs V2 — which to call:** V2 first, V1 as fallback, is both faster (no wasted 501 round-trip) and strictly more capable so far. Keep V1 in the mix only for `ExternallyRedeemed` (not seen in V2 samples) and because V2's schema, despite being empirically confirmed, is nowhere formally documented by Omnissa either — if V2 ever regresses for some app type, V1 remains available.

## Business logic gotcha: licenses are consumed per smart-group assignment, not just app-wide

A VPP app's purchased licenses are handed out through smart-group assignments, each with its own `Allocated` reservation carved out of the app's total pool. A device only receives the app if **its specific assignment** still has unredeemed capacity (`Allocated > Redeemed` for that one assignment) — not merely because the app has spare capacity somewhere else. An app can look healthy at the app-wide level while one specific assignment is fully exhausted, silently blocking new devices in that group. Any script reporting on VPP allocation should surface the per-assignment breakdown, not just the app-wide available count. See `reporting/vpp-license-allocation/DESIGN.md` for the full reasoning and the fields (`WorstAssignmentAvailable`, `AssignmentsBelowThreshold`) built around this.

## PowerShell gotcha: `Measure-Object -Minimum`/`-Maximum` return `[double]`

Even over integer input, `(...| Measure-Object -Minimum).Minimum` comes back as a `[double]` — left uncast, this prints as `2.000` instead of `2` in both `Format-Table` and `ConvertTo-Json`. Cast explicitly: `[int]((...| Measure-Object -Minimum).Minimum)`.

## Platform field — not useful for Apple sub-platform detection

The purchased-apps search response's own `Platform` field is a bare integer enum that, in samples checked so far, did not distinguish iOS vs. macOS vs. visionOS for Apple VPP apps. No confirmed mapping table exists for this enum as of 2026-09-28. Don't surface it in a report as if it means something more granular than "Apple" without new evidence (e.g. a confirmed enum-to-platform mapping from a future spec or support case).
