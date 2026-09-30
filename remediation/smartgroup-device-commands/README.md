# Invoke-SmartGroupDeviceCommand.ps1

Run a device command (DeviceQuery, SyncDevice, ...) against every device of **one platform** in a Workspace ONE UEM smart group. Batched, rate limited, dry-run by default, explicit confirmation before anything is sent.

> **Draft, untested against a live tenant.** Built from the Omnissa OpenAPI specs and Bruno collections for 2410-2607. Try it on a small test smart group first. See `DESIGN.md` for what is confirmed vs assumed.

## What you need

- PowerShell 5.1 or 7+.
- An OAuth client (Groups & Settings > Configurations > OAuth Client Management) whose role can read smart groups/devices and run the chosen command. Or a pre-acquired bearer token.
- Your API host (e.g. `as137.awmdm.com`) and the regional OAuth token URL.

## Authentication (pick one)

| Mode | Parameters | Notes |
|---|---|---|
| OAuth client credentials | `-OAuthTokenUrl -ClientId -ClientSecret` | Preferred. SaaS only. Refreshes the token once on a 401. |
| Pre-acquired token | `-AccessToken` | Cannot refresh. On expiry the run stops and can be resumed. |
| **Basic auth + tenant code** | `-Credential (Get-Credential) -TenantCode <api key>` | Legacy. Sends `Authorization: Basic ...` plus the `aw-tenant-code` header on every call. Works where OAuth is not available (e.g. on-prem). **A 401 is never retried**, because repeated bad logins can lock the admin account. |

Basic auth setup:

1. Get the tenant code from Groups & Settings > All Settings > System > Advanced > API > REST API (at Customer OG or below).
2. Use a dedicated API admin account. Its role needs the REST permissions for the calls made: smart groups (read), devices (read and execute) and, for the command itself, the matching device execute permission. The role table is in Omnissa's [Using UEM Functionality With a REST API](https://docs.omnissa.com/WorkspaceONE-UEM-Console-Basics-VSaaS/UsingUEMFunctionalityWithRESTAPI) page (written for OAuth clients, same REST role model).
3. Keep secrets out of history: `$cred = Get-Credential` and `$env:WS1_TENANT_CODE`, not literals on the command line.

```powershell
$cred = Get-Credential
.\Invoke-SmartGroupDeviceCommand.ps1 -ApiUrl as137.awmdm.com `
    -Credential $cred -TenantCode $env:WS1_TENANT_CODE `
    -UemVersion 2602 -SmartGroup 42 -Platform Apple -Command DeviceQuery
```

Per the UEM API Help "Getting Started" page (`https://<as-host>/api/help/GettingStarted`), Basic auth is the Base64 of `username:password` in the `Authorization` header, and the API key goes in the `aw-tenant-code` header as well; the API Explorer sets up Basic auth by entering both. **The OAuth modes do not need `aw-tenant-code`** and the script does not send it for them.

Status: this mode has not been run against a tenant. Try `-Command List` first (read only).

Not implemented: certificate authentication (signed request), and the `aw-groupid` header.

## Required inputs

| Parameter | Meaning |
|---|---|
| `-UemVersion` | `2410`, `2506`, `2509`, `2602`, `2604` or `2607`. |
| `-SmartGroup` | Smart group **numeric ID or UUID**. Auto-detected. |
| `-Platform` | **Mandatory.** `Apple` (iOS/iPadOS), `AppleOsX` (macOS), `AppleTv`, `AppleVision`, `Android`, `WindowsPc`, `WinRT`, `ChromeOS`, `ChromeBook`, `Linux`. Other platforms in the group are counted and skipped. |
| `-Command` | Optional. Leave it out and you get a menu filtered to the platform. |

## Commands

| Command | Kind | Platform |
|---|---|---|
| `List` | Read only, exports the filtered member list | any |
| `DeviceQuery`, `SyncDevice` | Standard | any (UEM checks support per device) |
| `SyncSensors` | Standard | AppleOsX |
| `SyncWorkflows` | Standard | AppleOsX, WinRT |
| `OsUpdateStatus` | Standard | Apple, AppleOsX |
| `UserList` | Standard | Apple |
| `Lock`, `ClearPasscode`, `Shutdown`, `SoftReset`, `EnterpriseReset`, `EnterpriseWipe`, `DeviceWipe` | **Disruptive** | any, except `Lock`/`DeviceWipe` are refused on AppleOsX (unlock PIN needed) |

Disruptive commands (Lock, ClearPasscode, Shutdown, SoftReset) need `-AllowDisruptive` **and** `-Execute`, then a typed phrase like `EXECUTE Shutdown 120`.

**Wipe-class commands** (`EnterpriseWipe`, `DeviceWipe`, `EnterpriseReset`) destroy data and need more: `-Execute -AllowDisruptive -AllowWipe`, a red warning banner, then two typed confirmations: `WIPE <Command> <count>` (e.g. `WIPE DeviceWipe 3`) and the smart group ID. `-SkipCanary` is refused, so the first device is always sent alone. Smart group membership can change; check the dry-run list first.

> **Disclaimer:** community tool, not an Omnissa product, MIT licensed, provided "AS IS" without warranty. Test on a small group in a non-production tenant first. You are solely responsible for what you run.

## Examples

Dry run (default). Nothing is sent to devices:

```powershell
.\Invoke-SmartGroupDeviceCommand.ps1 -ApiUrl as137.awmdm.com `
    -OAuthTokenUrl https://na.uemauth.workspaceone.com/connect/token `
    -ClientId $env:WS1_CLIENT_ID -ClientSecret $env:WS1_CLIENT_SECRET `
    -UemVersion 2604 -SmartGroup 42 -Platform Apple -Command DeviceQuery
```

Real run, by UUID, gentler pacing:

```powershell
.\Invoke-SmartGroupDeviceCommand.ps1 -ApiUrl as137.awmdm.com -AccessToken $token `
    -UemVersion 2607 -SmartGroup 59720b59-88e5-4ea8-b6d7-66d6b5fe1614 `
    -Platform AppleOsX -Command SyncDevice -Execute `
    -RequestsPerSecond 1 -BatchSize 25 -BatchPauseSeconds 10
```

Pick the command from a menu:

```powershell
.\Invoke-SmartGroupDeviceCommand.ps1 -ApiUrl as137.awmdm.com -AccessToken $token `
    -UemVersion 2602 -SmartGroup 42 -Platform Android
```

Continue an interrupted run (skips devices already accepted):

```powershell
# same parameters as the original run, plus:
    -Execute -Resume
```

## Suggested first run

1. `-Command List` to see the members and the platform labels UEM returns.
2. Dry run with the real command.
3. `-Execute -MaxDevices 1` on a test device.
4. Full run.

## Batching and rate limiting

| Control | Default | Notes |
|---|---|---|
| `-BatchSize` | 50 | Devices per batch. Progress is saved after every batch. |
| `-BatchPauseSeconds` | 5 | Pause between batches. |
| `-RequestsPerSecond` | 2 | Steady ceiling. **A guess.** UEM has a per-minute "Server Throttling" limit but does not publish or expose its value. Lower it if you see 429/503. |
| `-QuotaReserve` | 200 | UEM reports a quota per Organization Group and API key in the `x-ratelimit-limit/-remaining/-reset` response headers. Omnissa's docs call it a 24-hour quota, but on a real tenant it showed ~5000 and behaves like a much shorter window, so the script **does not assume the window length**. It shows the reset time in the plan and works from that. Other integrations on the same OG/key share it. |
| `-MaxQuotaWaitMinutes` | 15 | When the remaining count reaches the reserve and the reported reset is within this many minutes, the script pauses until the reset and carries on. If the reset is further away it stops cleanly (resumable with `-Resume`). At start, a run that needs more than the window holds is allowed if the reset is within this time (it will pause), otherwise refused. `0` = never wait. |
| `-MaxRetries` | 5 | On 429/503 it honours `Retry-After`, else backs off 2s, 4s, 8s... with jitter, and slows its own pacing up to 8x until calls succeed again. |
| `-MaxDevices` | 1000 | Refuses to run above this. |
| Canary | on | First device is sent alone. If it fails, nothing else is sent. `-SkipCanary` to disable. |
| `-MaxFailurePercent` / `-MinSampleForAbort` | 20 / 10 | Circuit breaker. |

### Safe abort on HTTP 429 / 503

| Situation | What happens |
|---|---|
| 429 on a device | Retried with backoff (honours `Retry-After`), up to `-MaxRetries`. A 429 means the request was not processed. |
| 503 on a standard command | Retried the same way (repeating a query/sync is harmless). |
| 503 on a **disruptive** command | **Not retried, and the run stops at once.** A 503 does not say whether the command was queued, so check that device in the console before using `-Resume`. |
| `-MaxConsecutiveThrottleFailures` (default 3) devices in a row still 429/503 after retries | Run stops, state saved. Wait, lower `-RequestsPerSecond`, then `-Resume`. |
| `Retry-After` longer than `-MaxRetryAfterSeconds` (default 300) | No waiting or retrying; the run stops and reports the requested wait. |
| Canary gets 429/503 | Nothing else is sent. |

The stop reason is printed in the summary and saved in the results JSON (`AbortReason`). Progress is checkpointed, so `-Resume` continues where it stopped.

Disruptive commands are never retried on 500/502/504, 503 or network errors, because the command may already be queued. They are retried on 429 only.

Not documented by Omnissa (so unconfirmed): which status code UEM returns when a limit is hit, and whether it sends `Retry-After`. The Getting Started page lists neither 429 nor `Retry-After`.

## Output

Written to `-OutputDirectory` (default: current folder):

- `SmartGroupCommand_<id>_<platform>_<command>_<timestamp>.csv` and `.json`: per device `DeviceId, Platform, Model, Command, Status, HttpStatus, Attempts, Throttled, Message, TimestampUtc`. The JSON also holds a run summary and rate-limiter stats.
- `smartgroup-state_<id>_<platform>_<command>.json`: accepted device IDs, used by `-Resume`.

Device names and usernames are **not** written unless you pass `-IncludeDeviceName`. They often contain personal data. All three file patterns are in `.gitignore`.

`Accepted` means UEM returned success for the request (expected HTTP 202). It does not mean the device has run the command.

## Troubleshooting

| Symptom | Likely cause |
|---|---|
| "No members matched platform" | The label UEM returns for `Platform` is not in the alias table. The script prints the labels it saw. Send that list back so the table can be fixed. |
| UUID exists only as a "smart group RULE" | SGv2 group with no numeric ID. The specs document no member-listing endpoint for it. Use a classic smart group ID or extend the script once an endpoint is confirmed. |
| Smart group UUID not found | Wrong UUID, or the API client cannot see the group's OG. Try `-OrganizationGroupId`. |
| HTTP 403 on commands | The OAuth client's role lacks permission for that command. |
| HTTP 404/400 on a device | Device unenrolled or command unsupported on that device. Check `Message` in the results. |
| Repeated 429 | Lower `-RequestsPerSecond`, raise `-BatchPauseSeconds`. |
| HTTP 401 mid-run with `-AccessToken` | Token expired and cannot be refreshed. Re-run with `-Resume`. |
| HTTP 401 with `-Credential` | Wrong username/password or tenant code, or the account cannot use the REST API. The script stops at once. Fix it before retrying to avoid a lockout. |
| HTTP 403 with Basic auth | Authenticated but the admin role lacks the REST permission. |
