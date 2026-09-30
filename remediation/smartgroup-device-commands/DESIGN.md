# Design notes: Invoke-SmartGroupDeviceCommand.ps1

Technical notes for whoever touches this next. Usage is in `README.md`. Cross-script API findings are in `docs/api-notes.md`.

**Status: not yet run against a live tenant.** Everything below labelled "confirmed" is confirmed against Omnissa's OpenAPI specs (`euc-dev/ws1-uem-apis`, `docs/versions/2410,2506,2509,2602,2604,2607`) and the matching Bruno collections, by direct inspection on 2026-09-30. Nothing here has been verified against a tenant's actual responses. The first live run should change that.

## Purpose

Given a smart group (ID or UUID), a mandatory platform, and a command, send the command to each matching device without hammering the API, and leave an auditable record.

## Sources

1. `mdmv1.json`, `mdmv2.json`, `mdmv3.json`, `mdmv4.json`, `systemv*.json` for all six releases, parsed with a script, not read by eye.
2. `uem-rest-bruno-2607.zip` for base path (`{{baseUrl}}/mdm/...`) and `Accept` versions.
3. Repo `docs/api-notes.md` for auth.

Fetching the specs through a web tool truncates them at about 100k characters, which is why the repo is cloned locally into `_specs/` (git-ignored).

## Endpoints used (all confirmed in spec)

| Purpose | Call | Accept |
|---|---|---|
| Load group by ID | `GET /mdm/smartgroups/{id}` (`SmartGroups_LoadSmartGroupAsync`) | v1 |
| Find group by UUID | `GET /mdm/smartgroups/search` (`page`, `pagesize`, `organizationgroupid`; `version` on 2607) | v1 |
| SGv2 existence check (2607) | `GET /mdm/smart-groups/{uuid}` (`SmartGroupsV4_GetSmartGroupRuleAsync`) | v4 |
| Members | `GET /mdm/smartgroups/{smartgroupid}/devices` (`SmartGroups_GetDevices`) | v1 |
| Command | `POST /mdm/devices/{deviceid}/commands?command=X` (`CommandsV1_ExecuteAsync`) | v1 |

## Version differences found (2410 to 2607)

Diffed every endpoint above, parameter by parameter, plus descriptions.

- **Unchanged on all six releases:** smart group load, member list, and `POST /devices/{deviceid}/commands` including its full `command` list. The per-device route is the same on 2410 as on 2607.
- **2607 only:** `GET /smartgroups/search` gains `version` (`-1` all, `1` classic default, `2` SGv2). The V4 API (`/smart-groups/{uuid}` CRUD and criteria) appears. The script passes `version=-1` and does the V4 existence check only when `-UemVersion` is 2607.
- **2602:** `POST /devices/commands` (by alternate ID) gains an enum on `searchby`, including `DeviceId` and `Uuid`. Before 2602 the parameter is a free string with no documented values. The script does not use this route, because the path-based route takes the numeric device ID directly on every release.
- **Wording only:** V2 `POST /devices/{deviceUuid}/commands/{commandName}` clarified "Lock (macOS and Linux only)" in 2506; V2 alternate-ID route mentions Android custom DPC for `refresh-esim` in 2607.

So `-UemVersion` changes behaviour in exactly one place (UUID lookup of SGv2 groups). It is mandatory anyway so the run record states the target release and future version-specific behaviour has a home.

## Why one HTTP call per device

The endpoints that could do "many devices per call" do not cover the requested commands:

| Bulk route | Commands | Device key |
|---|---|---|
| `POST /mdm/devices/commands/bulk` (V1) | EnterpriseWipe, LockDevice, ScheduleOsUpdate, SoftReset, Shutdown | serial, UDID, MAC, IMEI |
| `POST /mdm/devices/commands/{commandName}` (V2) | Lock, DeviceWipe, SyncSensors | device UUID |

`DeviceQuery` and `SyncDevice` exist only on per-device routes. The member list returns numeric device IDs (`SmartGroupDevice.Id`, typed string), which fit `POST /devices/{deviceid}/commands` with no extra lookup. So "batching" is chunking, pacing, checkpointing and a circuit breaker, not fewer HTTP calls. If a future release adds a bulk `DeviceQuery`/`SyncDevice`, switch `Send-One` to it.

## Smart group ID vs UUID

`SmartGroup` and `SmartGroupSearchModel` both carry `SmartGroupID` and `SmartGroupUuid` on every release, so UUID to ID resolution is a search-and-match. The search page base (0 or 1) is not stated in the spec (its example shows `Page: 1`). The script starts at 0 and stops when a page adds no new groups, which is safe either way. Passing `-OrganizationGroupId` shortens the scan on big tenants.

**Open gap:** SGv2 groups (2607) may exist as a UUID with no numeric ID. No spec endpoint lists devices for such a group (checked all `mdmv1-4`, `mam*`, `mcm*`, `mem*`, `system*` files for smart-group paths). The script says so and stops rather than guess.

## Mandatory platform

`SmartGroupDevice.Platform` is documented only as `string`. The UEM `DeviceTypeEnum` (Apple, AppleOsX, Android, WindowsPc, WinRT, ChromeOS, ...) is confirmed in the specs and drives `-Platform`'s allowed values. **Unconfirmed:** that the member list returns those exact labels. The script normalizes case/spaces and accepts a small alias set (`ios`, `macos`, ...). If nothing matches, it prints the labels it saw. Fix the alias table from a real response.

The previous note in `docs/api-notes.md` that VPP `Platform` is a bare integer applies to a different endpoint; do not assume it here.

Platform-vs-command rules come from the spec text ("macOS only", "iOS only", "macOS and WinRT only"). Where the spec states no restriction, the script allows it and lets UEM reject unsupported devices ("support for command on device" is checked server-side per the endpoint description).

## Authentication modes

| Mode | Confirmed | Unconfirmed |
|---|---|---|
| OAuth client_credentials | Token request and Bearer use, per Omnissa's REST API page and the Bruno collection; already exercised by `Get-VppLicenseAllocation.ps1` on 2604 | |
| Pre-acquired token | Same bearer header | |
| Basic + `aw-tenant-code` | UEM API Help "Getting Started" page (tenant `/api/help/GettingStarted`, text supplied by the user 2026-09-30): Basic = Base64 of `username:password` in `Authorization`; UEM APIs also take an API key in the `aw-tenant-code` header; the API Explorer sets Basic up by entering username/password under BasicAuth and the tenant code under ApiKeyAuth; the key is on the REST API settings page. Specs 2410-2607 agree: `securityDefinitions` has `BasicAuth` and `ApiKeyAuth` (header `aw-tenant-code`), and 519 of 530 `mdmv1.json` (2607) operations list them | That the smart group and command endpoints accept it on a live tenant. Certificate auth and `aw-groupid` are not implemented. The Help page's request-header table says the tenant code "needs to be appended in the URL", which contradicts its own Authentication section and the spec (`in: header`); the script uses the header |

**OAuth does not need `aw-tenant-code`.** The Help page says UEM APIs "also require" the key, but OAuth calls work without it (user-confirmed; also the repo's live 2604 finding), so OAuth modes never send it. Only the Basic mode does.

Also from that page: with no `Accept` header the API assumes `application/xml`. Every call here sends `Accept: application/json;version=N`.

**Uniform auth code (2026-09-30):** this script and `Get-VppLicenseAllocation.ps1` now authenticate through the same shared functions, `New-Ws1AuthContext` (modes `OAuth`, `Token`, `Basic`), `Get-Ws1AuthHeaders` and `Update-Ws1AuthToken` in `shared/Ws1ApiCore.psm1`, with identical parameter sets. OAuth itself is unchanged underneath: the same `Get-AccessTokenViaClientCredentials` and `Get-AuthHeaders` calls that were validated in both scripts (the smart-group script's OAuth path was exercised with safe commands before this refactor; the refactor itself has not been re-run). Results JSON `AuthMode` is now `OAuth`, `Token` or `Basic`.

Behaviour: `Get-BasicAuthHeaders` builds `Authorization: Basic base64(user:pass)` (UTF-8), `aw-tenant-code`, and the versioned `Accept`. Credentials go in as a `PSCredential`; the tenant code is a plain string and is never printed or written to results. There is no token to refresh, so a 401 stops the run at once (no retry, and no second attempt to log in) to avoid tripping account lockout. The auth mode, never the secrets, is recorded in the results JSON.

## Rate limiting and retry

Implemented in `shared/Ws1ApiCore.psm1` (`New-Ws1RateLimiter`, `Invoke-Ws1Request`) since any script can reuse it.

- **What is documented** (UEM API Help "Getting Started", "API Rate Limits"): limits are applied **per Organization Group, by API key**. Two limits: *Server Throttling* (per 1-minute interval) and *Daily Quota* (per 24 hours). Extra API keys on the same OG aggregate into that OG's totals. Responses carry `x-ratelimit-limit` (24 h total), `x-ratelimit-remaining` and `x-ratelimit-reset` (epoch). The example shows a 50000/day limit; actual values are tenant-specific.
- **Not documented:** the per-minute value, any header exposing it, and the status code returned when either limit is hit (the page's status table has no 429; the specs document 429 only on some System/MAM operations, none on MDM). The script therefore treats 429 and 503 as throttling, and additionally acts on the quota headers itself.
- **Doc vs observation:** the Help page describes `x-ratelimit-*` as a 24-hour quota (example 50000). A live tenant returned ~5000, which the user reads as a short (about 5 minute) window. Only the observed number is known; the window length has not been measured here, and the headers do not state it. So the code never hard-codes 24 h: it labels the values "quota window", prints the reported reset in minutes, and decides from `QuotaResetUtc`.
- **Quota handling:** `Update-Ws1RateLimitState` records the three headers from every response (success or error). `Wait-ForQuota` runs before every send: at or below `-QuotaReserve` it pauses until the reported reset if that is within `-MaxQuotaWaitMinutes` (then clears the stale count so the next response refreshes it), otherwise stops cleanly and saves state for `-Resume`. At start, a run larger than the window holds is allowed only if the reset is close enough to pause through; a `QuotaLimit <= QuotaReserve` is rejected because it could never proceed. The count is a snapshot and other clients share it, hence the reserve. Group lookups and retries also consume quota.
- **Follow-up if the short window is confirmed:** it may in fact be the per-minute/short-interval throttle surfacing in the headers. To find out, log `QuotaResetUtc` over two or three runs and compare with the time between calls, then update this section and `docs/api-notes.md`.
- **Pacing defaults** (2 req/s = 120/min, batches of 50, 5 s pause) are conservative assumptions, not vendor guidance. Per-minute limit: Data unavailable.
- **Pacing:** each call reserves the next slot `1000/rps` ms after the previous one.
- **429/503:** wait `Retry-After` if sent (seconds or HTTP-date), else `2 * 2^(attempt-1)` s capped at 120 s plus up to 1 s jitter. Pacing doubles (cap 8x). After 20 consecutive successes it eases back by 20% per step.
- **500/502/504/network:** retried only for non-disruptive commands (and reads). A 500 on a wipe may still have queued the wipe.
- **429 vs 503:** 429 is always retried (not processed). 503 is retried only when repeating is safe (`-RetryOnServerError`; GETs and non-disruptive POSTs). For disruptive POSTs a 503 is returned at once and `Get-ThrottleAbortReason` stops the run, since whether the command was queued is unknown.
- **Safe abort (`Get-ThrottleAbortReason`, checked after every send):** (1) `Retry-After` above `-MaxRetryAfterSeconds` (limiter setting, default 300) makes `Invoke-Ws1Request` return `RetryAfterExceeded` with no retry; the run stops. (2) 503 on a disruptive command stops immediately. (3) `-MaxConsecutiveThrottleFailures` (default 3) devices in a row ending 429/503 after retries stops the run. Any accepted device resets the counter. State is saved by the existing `finally` block, so `-Resume` works; the canary uses the same rule. Decision table checked with an offline model; the PowerShell itself has not been run.
- **401:** never retried by the limiter. The script fetches a fresh token once when it holds client credentials; otherwise it stops and saves state.
- Sequential by design (5.1 compatible, easy to reason about). Concurrency would need a shared limiter across runspaces.

## Safety model

Aligned with the org rule "warn, dry-run, confirm; no auto-exec":

1. Dry run unless `-Execute`.
2. Typed confirmation, not skippable. No `-Force`. Non-interactive sessions cannot send.
3. Disruptive commands: extra `-AllowDisruptive` plus a phrase containing the command and device count.
3a. Wipe-class commands (EnterpriseWipe, DeviceWipe, EnterpriseReset; catalog flag `Wipe`): additionally `-AllowWipe`, a warning banner (irreversible, 202 = queued not executed, membership can change, community tool/MIT/no warranty), confirmation 1 `WIPE <Command> <count>`, confirmation 2 = the smart group ID, and `-SkipCanary` is rejected. Covered by mock tests S5d–S5h.
4. `-MaxDevices` cap, canary device, circuit breaker.
5. macOS `Lock`/`DeviceWipe` blocked: the V2 models require `unlock_pin`, and the V1 per-device route documents no PIN input.
6. Commands that need input bodies (`CustomMdmCommand`, `ScheduleOsUpdate`, `Rotate*`, `InstallPackagedMacOSXAgent`, ...) are not offered.

PII: outputs carry device IDs, platform, model only. Names and usernames excluded unless `-IncludeDeviceName`. No secrets or tokens are printed or logged. Error text from the server is truncated to 500 characters.

## State and resume

After every batch (and in `finally` on Ctrl+C or error) the accepted device IDs are written to `smartgroup-state_<sg>_<platform>_<command>.json`. `-Resume` requires the same group, platform and command and skips accepted IDs. Devices that failed are retried on resume. Running without `-Resume` overwrites the state (with a warning).

## Known limitations and things to verify on first live run

- Not run on a tenant. PowerShell was not available in the authoring sandbox, so the script was only checked for balanced syntax, not executed.
- `POST` with an empty body and `Content-Type: application/json` mirrors the Bruno request (`body: none`, JSON header). Confirm UEM answers 202.
- Member list has no documented paging. If large groups come back truncated, that needs a different source.
- Alias table for the `Platform` label is a best guess.
- `Accepted` = request accepted. There is no polling for command completion; a status check would need a further endpoint.
- Whether `DeviceQuery`/`SyncDevice` behave identically across platforms is not documented.
- Command permissions are role-based; a 403 on some commands and not others is expected.

## Extension points

- New command: add a row to `$CommandCatalog` (name, kind, platforms). If it needs a body or parameter, extend `Send-One`.
- New release: add it to `-UemVersion`'s `ValidateSet`, then re-diff with the snippet approach used for this note (parse `mdmv1.json` and compare the five endpoints above).
- Different member source or bulk endpoint: replace `Get-SmartGroupMembers` / `Send-One` only.
