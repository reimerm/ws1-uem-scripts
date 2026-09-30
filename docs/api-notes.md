# Workspace ONE UEM REST API — cross-script notes

Findings about the API itself (not specific to any one script) confirmed while building scripts in this repo. Confirmed against UEM release **2604** unless noted otherwise; re-verify after any tenant upgrade before trusting these across a version boundary.

## Auth

- **OAuth 2.0, `client_credentials` grant.** Client id/secret are sent as an HTTP Basic `Authorization` header on the token request — **not** as `client_id`/`client_secret` fields in the request body. Confirmed via the official Bruno collection's collection-level auth config (`auth:oauth2`, `credentials_placement: basic_auth_header`). Only `grant_type=client_credentials` goes in the body.
- No `aw-tenant-code` / legacy API-key header is used anywhere in the validated Bruno collection — OAuth bearer token only. The OpenAPI specs (2410-2607) do still declare the legacy schemes in `securityDefinitions`: `BasicAuth`, `ApiKeyAuth` (header `aw-tenant-code`), `GroupIdAuth` (`aw-groupid`), `CmsAuth`; almost every operation lists them. Omnissa's REST API console page documents only OAuth; the tenant's own API Help "Getting Started" page documents Basic + `aw-tenant-code` (see below). The Basic mode in `remediation/smartgroup-device-commands` follows it and is unverified against a tenant.
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

## Smart groups, device commands and rate limits (spec review 2410-2607, 2026-09-30)

Spec-derived, not yet live-verified. Details and version diff in `remediation/smartgroup-device-commands/DESIGN.md`.

- Smart group objects carry both `SmartGroupID` (int) and `SmartGroupUuid` on every release. `GET /mdm/smartgroups/{id}` takes the numeric ID only; UUID lookup means paging `GET /mdm/smartgroups/search` and matching.
- `GET /mdm/smartgroups/{smartgroupid}/devices` returns `Devices[]` with `Id` (string), `Name`, `Model`, `OSVersion`, `Username`, `Platform` (string), `Ownership`. No paging params documented.
- `POST /mdm/devices/{deviceid}/commands?command=` (V1) is the only route covering DeviceQuery and SyncDevice, identical on 2410-2607. V1 bulk (`/devices/commands/bulk`) covers EnterpriseWipe, LockDevice, ScheduleOsUpdate, SoftReset, Shutdown by serial/UDID/MAC/IMEI. V2 bulk (`/devices/commands/{commandName}`) covers Lock, DeviceWipe, SyncSensors by device UUID.
- 2607 adds `version` on smart group search (-1 all, 1 classic, 2 SGv2) and the V4 API `/mdm/smart-groups/{uuid}` (Accept `version=4`), which returns rules with no device list.
- Platform enum (`DeviceTypeEnum`): Apple, AppleOsX, AppleTv, AppleVision, Android, WindowsPc, WinRT, ChromeOS, ChromeBook, Linux, and others. Whether member lists return exactly these labels is unconfirmed.
- Rate limits (UEM API Help > Getting Started > API Rate Limits): applied per Organization Group by API key. *Server Throttling* = per-minute limit, *Daily Quota* = per-24 h limit; keys on the same OG aggregate. Response headers `x-ratelimit-limit`, `x-ratelimit-remaining`, `x-ratelimit-reset` (epoch) describe the daily quota only. The per-minute value and the throttle status code are not documented; specs show HTTP 429 on some System/MAM operations only, none on MDM. Treat 429/503 as throttling, honour `Retry-After`, and watch the quota headers.
- **Observed vs documented:** the Help page documents `x-ratelimit-*` as the 24-hour quota (example 50000), but a live tenant returned ~5000 that looks like a short (about 5 minute) window per the user. Window length unmeasured. Do not hard-code 24 h; use `x-ratelimit-reset`.
- Auth per the same page: OAuth (recommended), Basic (Base64 `user:pass`), or certificate auth in `Authorization`; the `aw-tenant-code` API key header goes with Basic. OAuth does not need it. No `Accept` header means XML.
- **Live test (2604, 2026-09-30, OAuth, SyncDevice on 3 Apple devices):** confirmed smart group lookup by numeric ID; member list `Platform` values `Apple`, `AppleOsX`, `Android`, `Linux`, `WinRT` match the enum labels; per-device V1 command route returned HTTP 202 for the canary and the batch; `x-ratelimit-*` headers present (limit 5000, 5 requests consumed 5, reset about 1 min out at that moment). UUID lookup, Basic auth, 429/503 behaviour and other platforms are still untested on a live tenant.
- Fetching large spec files through a web fetch tool truncates at ~100k characters. Clone `euc-dev/ws1-uem-apis` locally to analyze them.

## Platform field — not useful for Apple sub-platform detection

The purchased-apps search response's own `Platform` field is a bare integer enum that, in samples checked so far, did not distinguish iOS vs. macOS vs. visionOS for Apple VPP apps. No confirmed mapping table exists for this enum as of 2026-09-28. Don't surface it in a report as if it means something more granular than "Apple" without new evidence (e.g. a confirmed enum-to-platform mapping from a future spec or support case).
