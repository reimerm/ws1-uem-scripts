<#
.SYNOPSIS
    Runs a device command (DeviceQuery, SyncDevice, ...) against every device of one
    platform in a Workspace ONE UEM smart group, with batching, client-side rate
    limiting, dry-run by default, and explicit confirmation before anything is sent.

.DESCRIPTION
    Inputs
      - A smart group, given as its numeric ID or its UUID (-SmartGroup).
      - The UEM release you are targeting (-UemVersion, 2410..2607).
      - A MANDATORY platform (-Platform). Only devices of that platform are touched;
        devices of other platforms in the same group are counted and skipped.
      - A command (-Command). If omitted, you are shown a menu of the commands that
        are valid for the chosen platform.

    Flow
      1. Authenticate. Three modes, chosen by which parameters you pass:
           OAuth client_credentials (-OAuthTokenUrl -ClientId -ClientSecret)
           pre-acquired bearer token (-AccessToken)
           Basic auth + tenant API key (-Credential -TenantCode): sends
             "Authorization: Basic base64(user:pass)" and the "aw-tenant-code"
             header on every request, as described in the UEM API Help "Getting
             Started" page (Basic auth needs the tenant code too). Not retried on 401.
      2. Resolve the smart group.
           ID   -> GET /mdm/smartgroups/{id}
           UUID -> page through GET /mdm/smartgroups/search and match SmartGroupUuid
                   (the group object carries both SmartGroupID and SmartGroupUuid on
                   every release 2410-2607). On 2607 the search also passes version=-1
                   so SGv2 groups are included; if a UUID is found only as an SGv2
                   rule (GET /mdm/smart-groups/{uuid}) with no numeric ID, the script
                   stops - no membership endpoint for that case exists in the specs.
      3. List members: GET /mdm/smartgroups/{id}/devices, filter to -Platform.
      4. Show the plan (counts, batches, estimated duration).
      5. DRY RUN unless -Execute is given. Nothing is sent to devices in a dry run.
      6. With -Execute you must still type a confirmation phrase. There is no way to
         skip it.
      7. Send POST /mdm/devices/{deviceid}/commands?command=<Command> one device at
         a time, in batches, through a rate limiter (shared/Ws1ApiCore.psm1).

    Why one call per device
      The bulk endpoints do not cover these commands. V1 bulk
      (POST /mdm/devices/commands/bulk) accepts only EnterpriseWipe, LockDevice,
      ScheduleOsUpdate, SoftReset, Shutdown, and keys on serial/UDID/MAC/IMEI. V2 bulk
      (POST /mdm/devices/commands/{commandName}) accepts only Lock, DeviceWipe,
      SyncSensors, and keys on device UUID. DeviceQuery and SyncDevice exist only on
      the per-device V1 routes. The smart-group member list returns numeric device
      IDs, which is exactly what POST /mdm/devices/{deviceid}/commands takes. That
      route's command list is identical on 2410, 2506, 2509, 2602, 2604 and 2607.
      "Batching" here therefore means chunking, pacing and checkpointing, not one
      HTTP call for many devices. See DESIGN.md.

    Safety
      - Dry run by default; -Execute plus a typed confirmation to send.
      - "Disruptive" commands (Lock, ClearPasscode, Shutdown, SoftReset,
        EnterpriseReset, EnterpriseWipe, DeviceWipe) additionally require
        -AllowDisruptive and a typed phrase that includes the command and count.
      - Wipe-class commands (EnterpriseWipe, DeviceWipe, EnterpriseReset) additionally
        need -AllowWipe, a warning banner, two typed confirmations and the canary.
      - Lock and DeviceWipe are refused for AppleOsX: the V2 spec requires an
        unlock PIN for macOS, and this script uses the V1 per-device route.
      - -MaxDevices caps the blast radius (default 1000).
      - The first device is sent alone as a canary; if it fails, nothing else is sent
        (skip with -SkipCanary).
      - A circuit breaker stops the run if the failure rate is too high.
      - Device names and usernames are NOT written to output unless
        -IncludeDeviceName is set (they frequently contain personal data).

    Rate limiting
      Per the UEM API Help "Getting Started" page, limits are per Organization Group
      and API key: a per-minute "Server Throttling" limit and a 24-hour "Daily Quota".
      The x-ratelimit-limit / -remaining / -reset response headers are documented as
      the daily quota, but on a real tenant they showed ~5000 behaving like a short
      window, so the script treats them only as "quota window as reported" and works
      from the reset time. It reads them on every call, shows them in the plan,
      refuses to start if the quota cannot cover the run and the reset is far off,
      waits for a near reset or stops cleanly (resumable) if it runs low (see
      -QuotaReserve, -MaxQuotaWaitMinutes). The per-minute limit value is not
      published or exposed in headers, so pacing defaults are conservative guesses:
      2 requests/second, batches of 50, 5 s pause between batches. On 429/503 the
      script honours Retry-After, otherwise backs off exponentially with jitter, and
      slows its own pacing (up to 8x) until calls succeed again. Tune with
      -RequestsPerSecond, -BatchSize, -BatchPauseSeconds, -MaxRetries.

    Status of this script
      Written against the OpenAPI specs in euc-dev/ws1-uem-apis (2410-2607) and the
      matching Bruno collections. It has NOT yet been run against a live tenant.
      First run: use a small test smart group, then a dry run, then -MaxDevices 1.
      A 202 means UEM ACCEPTED the command, not that the device has executed it.

    Requires PowerShell 5.1 or 7+.

.PARAMETER ApiUrl
    UEM REST API host name only (no https://, no path), e.g. as137.awmdm.com.

.PARAMETER OAuthTokenUrl
    Region-specific OAuth 2.0 token URL. Not needed with -AccessToken.

.PARAMETER ClientId
    OAuth client ID. Not needed with -AccessToken.

.PARAMETER ClientSecret
    OAuth client secret. Not needed with -AccessToken. Never printed or logged.

.PARAMETER AccessToken
    Pre-acquired bearer token. If the token expires mid-run the script cannot
    refresh it and will stop with the progress saved for -Resume.

.PARAMETER Credential
    Basic-auth mode. A PSCredential for a UEM admin account allowed to use the REST
    API (build it with Get-Credential so the password never sits in your history).
    Use a dedicated API admin with only the roles this script needs. Use together
    with -TenantCode; cannot be combined with the OAuth parameters.

.PARAMETER TenantCode
    Basic-auth mode. The tenant API key sent in the aw-tenant-code header (Groups &
    Settings > All Settings > System > Advanced > API > REST API, at Customer OG or
    below). Treat it as a secret. Never printed or logged.

.PARAMETER UemVersion
    UEM release you are targeting: 2410, 2506, 2509, 2602, 2604 or 2607. Mandatory
    because behaviour differs slightly (UUID lookup of SGv2 groups is 2607 only).

.PARAMETER SmartGroup
    Smart group numeric ID (e.g. 42) or UUID (e.g. 59720b59-88e5-4ea8-b6d7-66d6b5fe1614).

.PARAMETER Platform
    Mandatory. Only devices whose Platform matches are targeted. Values follow the
    UEM device-type enum: Apple (iOS/iPadOS), AppleOsX (macOS), AppleTv, AppleVision,
    Android, WindowsPc, WinRT, ChromeOS, ChromeBook, Linux.

.PARAMETER Command
    Command to run, or 'List' to only export the filtered member list. Omit to pick
    from a menu. Supported: List, DeviceQuery, SyncDevice, SyncSensors, SyncWorkflows,
    OsUpdateStatus, UserList, Lock, ClearPasscode, Shutdown, SoftReset,
    EnterpriseReset, EnterpriseWipe, DeviceWipe.

.PARAMETER OrganizationGroupId
    Optional. Narrows the smart-group search used for UUID lookup.

.PARAMETER Execute
    Actually send commands. Without it the script performs a dry run.

.PARAMETER AllowDisruptive
    Required (in addition to -Execute) for Lock, ClearPasscode, Shutdown, SoftReset,
    EnterpriseReset, EnterpriseWipe and DeviceWipe.

.PARAMETER AllowWipe
    Extra switch required (together with -AllowDisruptive and -Execute) for the
    data-destroying commands EnterpriseWipe, DeviceWipe and EnterpriseReset. These
    also require a warning acknowledgement, two typed confirmations (a phrase with
    command and device count, then the smart group ID) and the canary (-SkipCanary
    is refused). Wiped devices lose data; this script cannot undo it.

.PARAMETER BatchSize
    Devices per batch (default 50). Progress is saved after each batch.

.PARAMETER BatchPauseSeconds
    Pause between batches (default 5).

.PARAMETER RequestsPerSecond
    Steady-state request ceiling (default 2).

.PARAMETER MaxRetries
    Retries per request on 429/503 (and on 5xx/network errors for non-disruptive
    commands). Default 5.

.PARAMETER MaxDevices
    Refuse to run if more than this many devices match (default 1000).

.PARAMETER MaxFailurePercent
    Stop the run when failures exceed this percentage (default 20)...

.PARAMETER MinSampleForAbort
    ...once at least this many devices have been attempted (default 10).

.PARAMETER MaxConsecutiveThrottleFailures
    Safe-abort rule for HTTP 429/503. Each request is already retried with backoff
    (see -MaxRetries). If this many devices IN A ROW still end in 429 or 503 after
    those retries, the run stops, saves its state and can be continued with -Resume
    later. Default 3. A disruptive command that gets a 503 stops at once, because a
    503 does not tell us whether the command was queued (check that device in the
    console before resuming).

.PARAMETER MaxRetryAfterSeconds
    If UEM answers 429/503 with a Retry-After longer than this (default 300 s), the
    script does not wait or retry; it stops safely and reports the requested wait.

.PARAMETER QuotaReserve
    UEM reports an API quota per Organization Group and API key in the x-ratelimit-*
    response headers (limit, remaining, reset time). UEM's docs call it a 24-hour quota,
    but a real tenant showed ~5000 that behaves like a much shorter window, so this
    script never assumes the window length; it uses the reported reset time. If fewer
    than (devices + this reserve) calls remain and the reset is far away, the run
    refuses to start; mid-run, when the remaining count reaches this reserve it waits
    for the reset (see -MaxQuotaWaitMinutes) or stops cleanly. Default 200. Other
    integrations on the same OG/key draw from the same quota, so keep a margin.

.PARAMETER MaxQuotaWaitMinutes
    Longest the script will pause for the quota to reset (default 15). If the reported
    reset is further away, it stops instead (resumable with -Resume). 0 = never wait.

.PARAMETER SkipCanary
    Do not send the first device on its own before the rest.

.PARAMETER OutputDirectory
    Where result and state files are written. Default: current directory.

.PARAMETER Resume
    Continue a previous run for the same smart group, platform and command, skipping
    devices already accepted (read from the state file).

.PARAMETER IncludeDeviceName
    Add the device friendly name to result files. Off by default (may contain PII).

.EXAMPLE
    # Dry run: what would DeviceQuery hit for the iOS devices in smart group 42?
    .\Invoke-SmartGroupDeviceCommand.ps1 -ApiUrl as137.awmdm.com `
        -OAuthTokenUrl https://na.uemauth.workspaceone.com/connect/token `
        -ClientId $env:WS1_CLIENT_ID -ClientSecret $env:WS1_CLIENT_SECRET `
        -UemVersion 2604 -SmartGroup 42 -Platform Apple -Command DeviceQuery

.EXAMPLE
    # Real run by UUID, gentler pacing, menu skipped, macOS only.
    .\Invoke-SmartGroupDeviceCommand.ps1 -ApiUrl as137.awmdm.com -AccessToken $token `
        -UemVersion 2607 -SmartGroup 59720b59-88e5-4ea8-b6d7-66d6b5fe1614 `
        -Platform AppleOsX -Command SyncDevice -Execute -RequestsPerSecond 1 -BatchSize 25

.EXAMPLE
    # Legacy Basic auth + aw-tenant-code instead of OAuth (dry run).
    $cred = Get-Credential   # UEM admin username / password
    .\Invoke-SmartGroupDeviceCommand.ps1 -ApiUrl as137.awmdm.com `
        -Credential $cred -TenantCode $env:WS1_TENANT_CODE `
        -UemVersion 2602 -SmartGroup 42 -Platform Apple -Command DeviceQuery

.EXAMPLE
    # Ask which command to run (menu filtered to the platform), dry run.
    .\Invoke-SmartGroupDeviceCommand.ps1 -ApiUrl as137.awmdm.com -AccessToken $token `
        -UemVersion 2602 -SmartGroup 42 -Platform Android
#>

#Requires -Version 5.1

[CmdletBinding(DefaultParameterSetName = 'ClientCredentials')]
param(
    [Parameter(Mandatory = $true)]
    [string]$ApiUrl,

    [Parameter(Mandatory = $true, ParameterSetName = 'ClientCredentials')]
    [string]$OAuthTokenUrl,

    [Parameter(Mandatory = $true, ParameterSetName = 'ClientCredentials')]
    [string]$ClientId,

    [Parameter(Mandatory = $true, ParameterSetName = 'ClientCredentials')]
    [string]$ClientSecret,

    [Parameter(Mandatory = $true, ParameterSetName = 'PreAcquiredToken')]
    [string]$AccessToken,

    [Parameter(Mandatory = $true, ParameterSetName = 'BasicAuth')]
    [System.Management.Automation.PSCredential]$Credential,

    [Parameter(Mandatory = $true, ParameterSetName = 'BasicAuth')]
    [string]$TenantCode,

    [Parameter(Mandatory = $true)]
    [ValidateSet('2410', '2506', '2509', '2602', '2604', '2607')]
    [string]$UemVersion,

    [Parameter(Mandatory = $true)]
    [string]$SmartGroup,

    [Parameter(Mandatory = $true)]
    [ValidateSet('Apple', 'AppleOsX', 'AppleTv', 'AppleVision', 'Android', 'WindowsPc', 'WinRT', 'ChromeOS', 'ChromeBook', 'Linux')]
    [string]$Platform,

    [Parameter(Mandatory = $false)]
    [string]$Command,

    [Parameter(Mandatory = $false)]
    [int]$OrganizationGroupId,

    [Parameter(Mandatory = $false)]
    [switch]$Execute,

    [Parameter(Mandatory = $false)]
    [switch]$AllowDisruptive,

    [Parameter(Mandatory = $false)]
    [switch]$AllowWipe,

    [Parameter(Mandatory = $false)]
    [ValidateRange(1, 5000)]
    [int]$BatchSize = 50,

    [Parameter(Mandatory = $false)]
    [ValidateRange(0, 3600)]
    [int]$BatchPauseSeconds = 5,

    [Parameter(Mandatory = $false)]
    [ValidateRange(0.05, 50)]
    [double]$RequestsPerSecond = 2,

    [Parameter(Mandatory = $false)]
    [ValidateRange(0, 20)]
    [int]$MaxRetries = 5,

    [Parameter(Mandatory = $false)]
    [ValidateRange(1, 100000)]
    [int]$MaxDevices = 1000,

    [Parameter(Mandatory = $false)]
    [ValidateRange(1, 100)]
    [int]$MaxFailurePercent = 20,

    [Parameter(Mandatory = $false)]
    [ValidateRange(1, 1000)]
    [int]$MinSampleForAbort = 10,

    [Parameter(Mandatory = $false)]
    [ValidateRange(1, 20)]
    [int]$MaxConsecutiveThrottleFailures = 3,

    [Parameter(Mandatory = $false)]
    [ValidateRange(1, 86400)]
    [int]$MaxRetryAfterSeconds = 300,

    [Parameter(Mandatory = $false)]
    [ValidateRange(0, 1000000)]
    [int]$QuotaReserve = 200,

    [Parameter(Mandatory = $false)]
    [ValidateRange(0, 1440)]
    [int]$MaxQuotaWaitMinutes = 15,

    [Parameter(Mandatory = $false)]
    [switch]$SkipCanary,

    [Parameter(Mandatory = $false)]
    [string]$OutputDirectory = (Get-Location).Path,

    [Parameter(Mandatory = $false)]
    [switch]$Resume,

    [Parameter(Mandatory = $false)]
    [switch]$IncludeDeviceName
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$BaseApiUrl = "https://$ApiUrl/api"
$VersionNumber = [int]$UemVersion

Import-Module (Join-Path $PSScriptRoot '..\..\shared\Ws1ApiCore.psm1') -Force

# ---------------------------------------------------------------------------
# Command catalog. Sources: POST /mdm/devices/{deviceid}/commands (CommandsV1_ExecuteAsync)
# description and `command` parameter in mdmv1.json, identical on 2410-2607.
#   Kind      Read        = no call to devices (list only)
#             Standard    = asks the device to report/sync; no user-visible disruption expected
#             Disruptive  = locks, wipes, resets or powers off; needs -AllowDisruptive
#   Platforms 'Any' means the spec states no platform restriction; UEM itself checks
#             support for the command on the device (per the endpoint description).
# Commands that need extra input (CustomMdmCommand, ScheduleOsUpdate, Rotate*, ...) are
# deliberately not offered.
# ---------------------------------------------------------------------------
$CommandCatalog = @(
    @{ Name = 'List';           Kind = 'Read';       Platforms = @('Any');                  Help = 'No command sent. Exports the filtered member list only.' }
    @{ Name = 'DeviceQuery';    Kind = 'Standard';   Platforms = @('Any');                  Help = 'Ask the device to report its current information to UEM.' }
    @{ Name = 'SyncDevice';     Kind = 'Standard';   Platforms = @('Any');                  Help = 'Ask the device to sync with UEM.' }
    @{ Name = 'SyncSensors';    Kind = 'Standard';   Platforms = @('AppleOsX');             Help = 'Sync sensors (macOS only per spec).' }
    @{ Name = 'SyncWorkflows';  Kind = 'Standard';   Platforms = @('AppleOsX', 'WinRT');    Help = 'Sync workflows (macOS and WinRT only per spec).' }
    @{ Name = 'OsUpdateStatus'; Kind = 'Standard';   Platforms = @('Apple', 'AppleOsX');    Help = 'Request OS update status (iOS and macOS only per spec).' }
    @{ Name = 'UserList';       Kind = 'Standard';   Platforms = @('Apple');                Help = 'Request user list (iOS only per spec).' }
    @{ Name = 'Lock';           Kind = 'Disruptive'; Platforms = @('Any');                  Help = 'Lock the device. Not available for AppleOsX in this script (needs unlock PIN).' }
    @{ Name = 'ClearPasscode';  Kind = 'Disruptive'; Platforms = @('Any');                  Help = 'Clear the device passcode.' }
    @{ Name = 'Shutdown';       Kind = 'Disruptive'; Platforms = @('Any');                  Help = 'Shut the device down.' }
    @{ Name = 'SoftReset';      Kind = 'Disruptive'; Platforms = @('Any');                  Help = 'Soft reset the device.' }
    # Wipe = $true marks data-destroying commands: on top of -AllowDisruptive they need -AllowWipe,
    # a warning banner and two typed confirmations. EnterpriseReset is included because on
    # some platforms it removes enterprise data / returns the device to a reset state.
    @{ Name = 'EnterpriseReset'; Kind = 'Disruptive'; Wipe = $true; Platforms = @('Any');   Help = '[WIPE-CLASS] Enterprise reset the device. Needs -AllowWipe.' }
    @{ Name = 'EnterpriseWipe'; Kind = 'Disruptive'; Wipe = $true; Platforms = @('Any');    Help = '[WIPE-CLASS] Remove corporate data / unenroll the device. Needs -AllowWipe.' }
    @{ Name = 'DeviceWipe';     Kind = 'Disruptive'; Wipe = $true; Platforms = @('Any');    Help = '[WIPE-CLASS] FULL DEVICE WIPE, all data lost. Needs -AllowWipe. Not available for AppleOsX in this script (needs unlock PIN).' }
)
$MacBlockedCommands = @('Lock', 'DeviceWipe')

# Platform names in the SmartGroupDevice.Platform string are not enumerated in the
# spec (only "Platform: string"); the aliases below are a best-effort normalization
# Confirmed on a live tenant (2604): Apple, AppleOsX, Android, Linux, WinRT. Others below
# remain UNCONFIRMED until a live tenant response has been checked. If nothing
# matches, the script prints the platform values it actually saw.
$PlatformAliases = @{
    'Apple'       = @('apple', 'ios', 'ipados')
    'AppleOsX'    = @('appleosx', 'macos', 'macosx', 'osx')
    'AppleTv'     = @('appletv', 'tvos')
    'AppleVision' = @('applevision', 'visionos')
    'Android'     = @('android')
    'WindowsPc'   = @('windowspc', 'windowsdesktop')
    'WinRT'       = @('winrt')
    'ChromeOS'    = @('chromeos')
    'ChromeBook'  = @('chromebook')
    'Linux'       = @('linux')
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
function ConvertTo-PlatformKey {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return '' }
    return (($Value.ToLowerInvariant()) -replace '[\s_\-]', '')
}

function Write-Step {
    param([string]$Text)
    Write-Host $Text -ForegroundColor Cyan
}

function Invoke-Uem {
    <#
        Authenticated, rate-limited call. Retries once with a fresh token on 401
        when client credentials are available.
    #>
    param(
        [string]$Method,
        [string]$Uri,
        [int]$Version = 1,
        [switch]$RetryOnServerError
    )

    # Reads are always safe to repeat, so GETs may retry 503/5xx; POSTs only if the caller says so.
    $safeToRepeat = ($RetryOnServerError -or $Method -eq 'GET')

    # Uniform auth: the shared context (OAuth / Token / Basic) builds the headers.
    $headers = Get-Ws1AuthHeaders -Context $script:Auth -Version $Version
    $res = Invoke-Ws1Request -Method $Method -Uri $Uri -Headers $headers -Limiter $script:Limiter `
        -RetryOnServerError:$safeToRepeat -OnRetry $script:OnRetry

    if ($res.StatusCode -eq 401) {
        if ($script:Auth.Mode -eq 'Basic') {
            # Never retry Basic auth on 401: repeated bad logins can lock the admin account.
            Write-Warning "HTTP 401 with Basic auth. Check the username/password, the aw-tenant-code value, and that the account is allowed to use the REST API. Not retrying."
        }
        elseif ($script:Auth.CanRefresh) {
            Write-Warning "HTTP 401 - requesting a fresh OAuth token and retrying once."
            [void](Update-Ws1AuthToken -Context $script:Auth)
            $headers = Get-Ws1AuthHeaders -Context $script:Auth -Version $Version
            $res = Invoke-Ws1Request -Method $Method -Uri $Uri -Headers $headers -Limiter $script:Limiter `
                -RetryOnServerError:$safeToRepeat -OnRetry $script:OnRetry
        }
    }
    return $res
}

function Get-ItemsFromSearch {
    param($Data, [string[]]$Names)
    # Emits the items one by one (or nothing). ALWAYS call as @(Get-ItemsFromSearch ...)
    # so an empty or single-item result is still an array.
    if ($null -eq $Data) { return }
    foreach ($n in $Names) {
        if ($Data.PSObject.Properties.Name -contains $n) {
            $v = $Data.$n
            if ($null -eq $v) { return }
            $v
            return
        }
    }
}

function Resolve-SmartGroupTarget {
    <#
        Returns @{ Id; Uuid; Name; DeviceCount } for a numeric ID or a UUID.
        Confirmed in the specs (2410-2607): SmartGroup (GET /smartgroups/{id}) and
        SmartGroupSearchModel (GET /smartgroups/search) both carry SmartGroupID,
        SmartGroupUuid, Name and Devices. Search page base (0 vs 1) is not stated,
        so paging starts at 0 and stops when a page adds no new groups.
    #>
    param([string]$Value)

    $guid = [Guid]::Empty
    if ($Value -match '^\d+$') {
        $uri = "$BaseApiUrl/mdm/smartgroups/$Value"
        $r = Invoke-Uem -Method GET -Uri $uri -Version 1
        if (-not $r.Success -or $null -eq $r.Data) {
            throw "Smart group ID $Value could not be loaded (HTTP $($r.StatusCode)): $($r.Error)"
        }
        return @{
            Id          = [int](Resolve-Field -Object $r.Data -Names @('SmartGroupID', 'SmartGroupId', 'Id'))
            Uuid        = [string](Resolve-Field -Object $r.Data -Names @('SmartGroupUuid'))
            Name        = [string](Resolve-Field -Object $r.Data -Names @('Name'))
            DeviceCount = Resolve-Field -Object $r.Data -Names @('Devices')
        }
    }

    if (-not [Guid]::TryParse($Value, [ref]$guid)) {
        throw "-SmartGroup '$Value' is neither a numeric ID nor a UUID."
    }
    $wanted = $guid.ToString().ToLowerInvariant()

    Write-Step "Looking up smart group UUID $wanted (scanning smart group search results)..."
    $seen = New-Object 'System.Collections.Generic.HashSet[string]'
    $page = 0
    while ($page -lt 500) {
        $q = New-Object System.Collections.Generic.List[string]
        $q.Add("page=$page")
        $q.Add('pagesize=500')
        if ($OrganizationGroupId) { $q.Add("organizationgroupid=$OrganizationGroupId") }
        # `version` filter (-1 = all, 1 = classic [default], 2 = SGv2) exists on search from 2607 only.
        if ($VersionNumber -ge 2607) { $q.Add('version=-1') }
        $uri = "$BaseApiUrl/mdm/smartgroups/search?" + ($q -join '&')

        $r = Invoke-Uem -Method GET -Uri $uri -Version 1
        if (-not $r.Success) { throw "Smart group search failed on page $page (HTTP $($r.StatusCode)): $($r.Error)" }
        $items = @(Get-ItemsFromSearch -Data $r.Data -Names @('SmartGroups'))
        if ($items.Count -eq 0) { break }

        $newOnThisPage = 0
        foreach ($sg in $items) {
            $sgUuid = [string](Resolve-Field -Object $sg -Names @('SmartGroupUuid'))
            $sgId = Resolve-Field -Object $sg -Names @('SmartGroupID', 'SmartGroupId', 'Id')
            $key = "$sgId|$sgUuid"
            if ($seen.Add($key)) { $newOnThisPage++ }
            if ($sgUuid -and $sgUuid.ToLowerInvariant() -eq $wanted) {
                return @{
                    Id          = [int]$sgId
                    Uuid        = $sgUuid
                    Name        = [string](Resolve-Field -Object $sg -Names @('Name'))
                    DeviceCount = Resolve-Field -Object $sg -Names @('Devices')
                }
            }
        }
        if ($newOnThisPage -eq 0) { break }
        $total = Resolve-Field -Object $r.Data -Names @('Total')
        if ($total -and $seen.Count -ge [int]$total) { break }
        $page++
    }

    if ($VersionNumber -ge 2607) {
        $v4 = Invoke-Uem -Method GET -Uri "$BaseApiUrl/mdm/smart-groups/$wanted" -Version 4
        if ($v4.Success) {
            throw "UUID $wanted exists as a smart group RULE (GET /mdm/smart-groups/{uuid}, name '$($v4.Data.name)') but was not found in the numeric-ID smart group list. The specs document no endpoint that lists devices for such a group. Data unavailable - cannot continue."
        }
    }
    throw "No smart group with UUID $wanted was found. Check the UUID, the -OrganizationGroupId scope, and that the API client can see the group."
}

function Get-SmartGroupMembers {
    <#
        GET /mdm/smartgroups/{smartgroupid}/devices (SmartGroups_GetDevices).
        Documented query params: seensince, seentill. No paging params are
        documented, so the response is treated as the complete list.
        SmartGroupDevice fields: Id (string), Name, Model, OSVersion, Username,
        Platform, Ownership.
    #>
    param([int]$SmartGroupId)

    $r = Invoke-Uem -Method GET -Uri "$BaseApiUrl/mdm/smartgroups/$SmartGroupId/devices" -Version 1
    if (-not $r.Success) { throw "Could not list devices of smart group $SmartGroupId (HTTP $($r.StatusCode)): $($r.Error)" }
    return @(Get-ItemsFromSearch -Data $r.Data -Names @('Devices'))
}

function Get-ThrottleAbortReason {
    <#
        Safe-abort rule for HTTP 429/503. Called after every send. Returns $null to
        carry on, or the reason to stop. Requests were already retried with backoff
        inside Invoke-Ws1Request, so a 429/503 seen here is one that did not clear.
          - Retry-After above -MaxRetryAfterSeconds       -> stop now
          - 503 on a disruptive command                   -> stop now (outcome unknown)
          - -MaxConsecutiveThrottleFailures in a row      -> stop
    #>
    param($Rec)

    $st = $Rec.HttpStatus
    if ($Rec.Status -eq 'Accepted' -or ($st -ne 429 -and $st -ne 503)) {
        $script:ConsecThrottle = 0
        return $null
    }
    $script:ConsecThrottle++
    $wait = ''
    if ($null -ne $Rec.RetryAfterSeconds) { $wait = " UEM asked for a wait of about $([math]::Round([double]$Rec.RetryAfterSeconds)) s." }

    if ($Rec.RetryAfterExceeded) {
        return "HTTP $st and UEM's Retry-After is longer than -MaxRetryAfterSeconds ($MaxRetryAfterSeconds s).$wait Stopped safely; progress saved."
    }
    if ($st -eq 503 -and $isDisruptive) {
        return "HTTP 503 on a disruptive command for device $($Rec.DeviceId). A 503 does not say whether the command was queued: check that device in the UEM console before using -Resume. Stopped safely; progress saved."
    }
    if ($script:ConsecThrottle -ge $MaxConsecutiveThrottleFailures) {
        return "HTTP $st on $($script:ConsecThrottle) devices in a row after retries.$wait Stopped safely; progress saved. Wait, then re-run with -Resume (consider lowering -RequestsPerSecond)."
    }
    return $null
}

function Wait-ForQuota {
    <#
        Called before each send. Returns $true when it is fine to send (quota above
        the reserve, unknown, or we just waited out the reset) and $false when the
        run must stop (reason in $script:QuotaStopReason).
        If the remaining count is at or below -QuotaReserve and the reported reset is
        within -MaxQuotaWaitMinutes, it sleeps until the reset, then clears the
        stale count so the next response refreshes it.
    #>
    $lim = $script:Limiter
    if ($null -eq $lim.QuotaRemaining -or $lim.QuotaRemaining -gt $QuotaReserve) { return $true }

    if ($null -eq $lim.QuotaResetUtc) {
        $script:QuotaStopReason = "API quota at or below the reserve ($($lim.QuotaRemaining) left, reserve $QuotaReserve) and no reset time was reported. Re-run with -Resume later."
        return $false
    }
    $secs = ($lim.QuotaResetUtc - [DateTime]::UtcNow).TotalSeconds
    if ($secs -le 0) { $lim.QuotaRemaining = $null; return $true }
    if (($secs / 60.0) -gt $MaxQuotaWaitMinutes) {
        $script:QuotaStopReason = ("API quota at or below the reserve ({0} left, reserve {1}); reset at {2:u} is more than -MaxQuotaWaitMinutes ({3}) away. Re-run with -Resume after the reset." -f $lim.QuotaRemaining, $QuotaReserve, $lim.QuotaResetUtc, $MaxQuotaWaitMinutes)
        return $false
    }
    Write-Warning ("API quota at the reserve ({0} left). Pausing {1:N0}s until the reset at {2:u}." -f $lim.QuotaRemaining, $secs, $lim.QuotaResetUtc)
    Start-Sleep -Seconds ([int][math]::Ceiling($secs) + 5)
    $lim.QuotaRemaining = $null
    return $true
}

function Read-Confirmation {
    param([string]$Prompt, [string]$Expected)
    Write-Host ""
    Write-Host $Prompt -ForegroundColor Yellow
    try { $answer = Read-Host "Type exactly [$Expected] to continue, anything else aborts" }
    catch { throw "No interactive input available - refusing to send commands without confirmation." }
    return ($answer -ceq $Expected)
}

function Save-State {
    param([string]$Path, $State)
    $State | ConvertTo-Json -Depth 5 | Out-File -FilePath $Path -Encoding utf8
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
$runStart = Get-Date
$timestamp = $runStart.ToString('yyyyMMdd_HHmmss')
if (-not (Test-Path -LiteralPath $OutputDirectory)) { New-Item -ItemType Directory -Path $OutputDirectory | Out-Null }

$script:Limiter = New-Ws1RateLimiter -RequestsPerSecond $RequestsPerSecond -MaxRetries $MaxRetries -MaxRetryAfterSeconds $MaxRetryAfterSeconds
$script:ConsecThrottle = 0
$script:OnRetry = {
    param($attempt, $status, $wait)
    $s = if ($null -eq $status) { 'network error' } else { "HTTP $status" }
    Write-Warning ("{0} - retry {1} in {2:N1}s" -f $s, $attempt, $wait)
}

# 1. Authenticate
# Same three modes and the same shared code path as Get-VppLicenseAllocation.ps1.
switch ($PSCmdlet.ParameterSetName) {
    'ClientCredentials' { $script:Auth = New-Ws1AuthContext -Mode OAuth -TokenUrl $OAuthTokenUrl -ClientId $ClientId -ClientSecret $ClientSecret }
    'PreAcquiredToken'  { $script:Auth = New-Ws1AuthContext -Mode Token -AccessToken $AccessToken }
    'BasicAuth' {
        # Legacy mode: admin username/password + aw-tenant-code header. No token
        # exchange happens; every request carries the credentials. See DESIGN.md.
        $script:Auth = New-Ws1AuthContext -Mode Basic -Credential $Credential -TenantCode $TenantCode
        Write-Warning "Basic auth + aw-tenant-code is the legacy mechanism. OAuth is preferred where your tenant supports it."
    }
}
$script:AuthMode = $script:Auth.Mode
Write-Host "Auth mode: $($script:AuthMode)" -ForegroundColor DarkGray

# 2. Choose and validate the command (before any smart-group traffic)
$eligible = @($CommandCatalog | Where-Object {
        ($_.Platforms -contains 'Any' -or $_.Platforms -contains $Platform) -and
        -not ($Platform -eq 'AppleOsX' -and $MacBlockedCommands -contains $_.Name)
    })

if (-not $Command) {
    Write-Host "`nCommands available for platform '$Platform':" -ForegroundColor Cyan
    for ($i = 0; $i -lt $eligible.Count; $i++) {
        $tag = if ($eligible[$i].Kind -eq 'Disruptive') { ' [DISRUPTIVE]' } else { '' }
        Write-Host ("  {0,2}. {1,-16}{2} {3}" -f ($i + 1), $eligible[$i].Name, $tag, $eligible[$i].Help)
    }
    try { $pick = Read-Host "`nEnter the number or name of the command to run" }
    catch { throw "No command supplied and no interactive input available. Pass -Command." }
    if ($pick -match '^\d+$' -and [int]$pick -ge 1 -and [int]$pick -le $eligible.Count) { $Command = $eligible[[int]$pick - 1].Name }
    else { $Command = $pick }
}

$cmdDef = $CommandCatalog | Where-Object { $_.Name -ieq $Command } | Select-Object -First 1
if (-not $cmdDef) {
    throw "Command '$Command' is not supported by this script. Supported: $(($CommandCatalog | ForEach-Object { $_.Name }) -join ', ')."
}
$Command = $cmdDef.Name
if (-not ($eligible | Where-Object { $_.Name -eq $Command })) {
    if ($Platform -eq 'AppleOsX' -and $MacBlockedCommands -contains $Command) {
        throw "$Command on AppleOsX requires an unlock PIN (V2 command models); this script uses the V1 per-device route and does not support it."
    }
    throw "$Command is documented as applying to $($cmdDef.Platforms -join '/') only, not '$Platform'."
}
$isDisruptive = ($cmdDef.Kind -eq 'Disruptive')
$isReadOnly = ($cmdDef.Kind -eq 'Read')
if ($isDisruptive -and -not $AllowDisruptive) {
    throw "$Command is a disruptive command. Re-run with -AllowDisruptive (and -Execute) if you really intend to send it."
}
$isWipe = [bool]$cmdDef.Wipe
if ($isWipe -and -not $AllowWipe) {
    throw "$Command is a wipe-class command that destroys device data. It needs -AllowWipe in addition to -AllowDisruptive and -Execute."
}
if ($isWipe -and $SkipCanary) {
    throw "-SkipCanary is not allowed with $Command. The first device is always sent alone so a bad result stops the run before more data is lost."
}

# 3. Resolve smart group and list members
$sg = Resolve-SmartGroupTarget -Value $SmartGroup
Write-Host ("Smart group: '{0}'  ID {1}  UUID {2}  (UEM reports {3} device(s))" -f $sg.Name, $sg.Id, $sg.Uuid, $sg.DeviceCount) -ForegroundColor Green

Write-Step "Listing members of smart group $($sg.Id)..."
$members = @(Get-SmartGroupMembers -SmartGroupId $sg.Id)
if ($members.Count -eq 0) {
    Write-Warning "Smart group $($sg.Id) returned no devices. Nothing to do."
    return
}

$keys = $PlatformAliases[$Platform]
$targets = New-Object System.Collections.Generic.List[object]
$platformCounts = @{}
$badIds = 0
$seenIds = New-Object 'System.Collections.Generic.HashSet[int]'
foreach ($m in $members) {
    $p = [string](Resolve-Field -Object $m -Names @('Platform'))
    $pk = if ($p) { $p } else { '(blank)' }
    if ($platformCounts.ContainsKey($pk)) { $platformCounts[$pk]++ } else { $platformCounts[$pk] = 1 }

    if ($keys -notcontains (ConvertTo-PlatformKey $p)) { continue }
    $idText = [string](Resolve-Field -Object $m -Names @('Id'))
    $idNum = 0
    if (-not [int]::TryParse($idText, [ref]$idNum)) { $badIds++; continue }
    if (-not $seenIds.Add($idNum)) { continue }
    $targets.Add([PSCustomObject]@{
            DeviceId = $idNum
            Platform = $p
            Model    = [string](Resolve-Field -Object $m -Names @('Model'))
            Name     = [string](Resolve-Field -Object $m -Names @('Name'))
        })
}

Write-Host "`nMembers by platform reported by UEM:" -ForegroundColor Cyan
$platformCounts.GetEnumerator() | Sort-Object Name | ForEach-Object { Write-Host ("  {0,-20} {1,6}" -f $_.Name, $_.Value) }
Write-Host ("Selected platform '{0}': {1} of {2} member(s) match." -f $Platform, $targets.Count, $members.Count) -ForegroundColor Green
if ($badIds -gt 0) { Write-Warning "$badIds matching device(s) had a non-numeric Id and were skipped." }

if ($targets.Count -eq 0) {
    throw "No members matched platform '$Platform'. Compare the list above with -Platform; if UEM uses a different label for this platform, the alias table in this script needs that value (unconfirmed mapping)."
}
if ($targets.Count -gt $MaxDevices) {
    throw "$($targets.Count) devices match, which exceeds -MaxDevices $MaxDevices. Raise -MaxDevices deliberately or narrow the smart group."
}

# 4. Files
$safeCmd = $Command -replace '[^A-Za-z0-9]', ''
$baseName = "SmartGroupCommand_$($sg.Id)_${Platform}_${safeCmd}"
$resultCsv = Join-Path $OutputDirectory "${baseName}_$timestamp.csv"
$resultJson = Join-Path $OutputDirectory "${baseName}_$timestamp.json"
$stateFile = Join-Path $OutputDirectory "smartgroup-state_$($sg.Id)_${Platform}_${safeCmd}.json"

if ($isReadOnly) {
    $targets | Select-Object DeviceId, Platform, Model, @{ n = 'Name'; e = { if ($IncludeDeviceName) { $_.Name } else { '[REDACTED]' } } } |
        Export-Csv -Path $resultCsv -NoTypeInformation -Encoding utf8
    Write-Host "`nMember list written to $resultCsv. No commands were sent." -ForegroundColor Green
    return
}

# 5. Resume handling
$completed = New-Object 'System.Collections.Generic.HashSet[int]'
if ($Resume) {
    if (-not (Test-Path -LiteralPath $stateFile)) { throw "-Resume given but no state file found at $stateFile." }
    $prev = Get-Content -LiteralPath $stateFile -Raw | ConvertFrom-Json
    if ($prev.SmartGroupId -ne $sg.Id -or $prev.Platform -ne $Platform -or $prev.Command -ne $Command) {
        throw "State file does not match this smart group / platform / command."
    }
    foreach ($d in @($prev.Accepted)) { [void]$completed.Add([int]$d) }
    Write-Host "Resuming: $($completed.Count) device(s) already accepted in the previous run will be skipped." -ForegroundColor Yellow
}
elseif ((Test-Path -LiteralPath $stateFile) -and $Execute) {
    Write-Warning "An earlier state file exists at $stateFile and will be overwritten (use -Resume to continue it instead)."
}

$todo = New-Object System.Collections.Generic.List[object]
foreach ($t in $targets) { if (-not $completed.Contains($t.DeviceId)) { $todo.Add($t) } }
if ($todo.Count -eq 0) { Write-Host "Nothing left to send." -ForegroundColor Green; return }

# 6. Plan
$batchCount = [int][math]::Ceiling($todo.Count / [double]$BatchSize)
$estSeconds = ($todo.Count / $RequestsPerSecond) + (($batchCount - 1) * $BatchPauseSeconds)
Write-Host "`n================ PLAN ================" -ForegroundColor Cyan
Write-Host ("Command          : {0}{1}" -f $Command, $(if ($isDisruptive) { '  (DISRUPTIVE)' } else { '' }))
Write-Host ("UEM version      : {0}" -f $UemVersion)
Write-Host ("Auth mode        : {0}" -f $script:AuthMode)
Write-Host ("Smart group      : '{0}' (ID {1})" -f $sg.Name, $sg.Id)
Write-Host ("Platform         : {0}" -f $Platform)
Write-Host ("Devices to send  : {0}" -f $todo.Count)
Write-Host ("Batches          : {0} x up to {1}, {2}s pause between batches" -f $batchCount, $BatchSize, $BatchPauseSeconds)
Write-Host ("Rate limit       : {0} req/s, up to {1} retries (429/503 honour Retry-After, back off, slow down)" -f $RequestsPerSecond, $MaxRetries)
Write-Host ("Estimated time   : ~{0:N1} minutes (excluding retries)" -f ($estSeconds / 60))
Write-Host ("API quota window : {0}" -f $(
        if ($null -ne $script:Limiter.QuotaRemaining) {
            "{0} remaining of {1}, resets {2:u} (in {3:N1} min; window length not stated by UEM headers); reserve {4}" -f $script:Limiter.QuotaRemaining, $(if ($null -ne $script:Limiter.QuotaLimit) { $script:Limiter.QuotaLimit } else { '?' }), $script:Limiter.QuotaResetUtc, $(if ($null -ne $script:Limiter.QuotaResetUtc) { [math]::Max(0, ($script:Limiter.QuotaResetUtc - [DateTime]::UtcNow).TotalMinutes) } else { 0 }), $QuotaReserve
        } else { 'Data unavailable (no x-ratelimit-* headers seen yet)' }))
Write-Host ("Canary           : {0}" -f $(if ($SkipCanary) { 'skipped' } else { 'first device sent alone' }))
Write-Host ("Circuit breaker  : stop above {0}% failures after {1} attempts" -f $MaxFailurePercent, $MinSampleForAbort)
Write-Host ("Endpoint         : POST {0}/mdm/devices/{{deviceid}}/commands?command={1}  (Accept version=1)" -f $BaseApiUrl, $Command)
Write-Host "======================================" -ForegroundColor Cyan

if (-not $Execute) {
    Write-Host "`nDRY RUN - no commands were sent. Sample of devices that would be targeted:" -ForegroundColor Yellow
    $todo | Select-Object -First 5 | ForEach-Object { Write-Host ("  POST {0}/mdm/devices/{1}/commands?command={2}   [{3} / {4}]" -f $BaseApiUrl, $_.DeviceId, $Command, $_.Platform, $_.Model) }
    $todo | Select-Object DeviceId, Platform, Model, @{ n = 'Name'; e = { if ($IncludeDeviceName) { $_.Name } else { '[REDACTED]' } } } |
        Export-Csv -Path $resultCsv -NoTypeInformation -Encoding utf8
    Write-Host "Full target list written to $resultCsv. Re-run with -Execute to send." -ForegroundColor Yellow
    return
}

# 6b. Quota guard (x-ratelimit-* headers: UEM per Organization Group + API key)
# The window length is NOT stated by the headers. UEM's docs describe a 24 h quota, but
# a real tenant showed ~5000 that behaves like a short window, so the guard works from the
# reset time the headers report instead of assuming 24 h.
if ($null -ne $script:Limiter.QuotaRemaining) {
    if ($null -ne $script:Limiter.QuotaLimit -and $script:Limiter.QuotaLimit -le $QuotaReserve) {
        throw "The reported limit ($($script:Limiter.QuotaLimit)) is not larger than -QuotaReserve ($QuotaReserve), so the run could never proceed. Lower -QuotaReserve."
    }
    $needed = $todo.Count + $QuotaReserve
    if ($script:Limiter.QuotaRemaining -lt $needed) {
        $minsToReset = if ($null -ne $script:Limiter.QuotaResetUtc) { ($script:Limiter.QuotaResetUtc - [DateTime]::UtcNow).TotalMinutes } else { $null }
        if ($null -ne $minsToReset -and $minsToReset -le $MaxQuotaWaitMinutes) {
            Write-Warning ("Quota window holds {0} call(s) but this run needs {1} (+{2} reserve). It resets in about {3:N1} min, so the run will pause at the reserve and continue after the reset." -f $script:Limiter.QuotaRemaining, $todo.Count, $QuotaReserve, [math]::Max(0, $minsToReset))
        }
        else {
            throw ("API quota too low: {0} call(s) remaining, reset {1}, but this run needs {2} (+{3} reserve) and the reset is more than -MaxQuotaWaitMinutes ({4}) away. Wait, send fewer devices (-MaxDevices), raise -MaxQuotaWaitMinutes, or lower -QuotaReserve if you accept the risk. Other integrations on the same OG/API key share this quota." -f $script:Limiter.QuotaRemaining, $(if ($null -ne $script:Limiter.QuotaResetUtc) { '{0:u}' -f $script:Limiter.QuotaResetUtc } else { 'time unknown' }), $todo.Count, $QuotaReserve, $MaxQuotaWaitMinutes)
        }
    }
}
else {
    Write-Warning "No x-ratelimit-* headers were returned, so the quota cannot be checked before sending. Data unavailable."
}

# 7. Confirmation (never skippable)
if ($isWipe) {
    $bar = '!' * 78
    Write-Host "`n$bar" -ForegroundColor Red
    Write-Host " DESTRUCTIVE ACTION: $Command" -ForegroundColor Red
    Write-Host " - Sends a wipe-class command to $($todo.Count) $Platform device(s) in smart group '$($sg.Name)' (ID $($sg.Id))." -ForegroundColor Red
    Write-Host " - Device data and/or enterprise data will be REMOVED. This script cannot undo it." -ForegroundColor Red
    Write-Host " - HTTP 202 means UEM queued the command; it may run at any time, even after you stop." -ForegroundColor Red
    Write-Host " - Check that the smart group membership is exactly what you expect; it can change." -ForegroundColor Red
    Write-Host " - This tool is community software, NOT an Omnissa product. MIT License, provided" -ForegroundColor Red
    Write-Host "   'AS IS' with NO WARRANTY. You are solely responsible for what you run." -ForegroundColor Red
    Write-Host "$bar" -ForegroundColor Red
    $phrase = "WIPE $Command $($todo.Count)"
    if (-not (Read-Confirmation -Prompt "Confirmation 1 of 2 - about to send $Command to $($todo.Count) $Platform device(s)." -Expected $phrase)) {
        Write-Host "Aborted. Nothing was sent." -ForegroundColor Yellow; return
    }
    if (-not (Read-Confirmation -Prompt "Confirmation 2 of 2 - type the smart group ID to prove this is the right group ('$($sg.Name)')." -Expected ([string]$sg.Id))) {
        Write-Host "Aborted. Nothing was sent." -ForegroundColor Yellow; return
    }
}
elseif ($isDisruptive) {
    $phrase = "EXECUTE $Command $($todo.Count)"
    Write-Host "`nWARNING: $Command is disruptive and cannot be undone by this script." -ForegroundColor Red
    if (-not (Read-Confirmation -Prompt "About to send $Command to $($todo.Count) $Platform device(s) in smart group '$($sg.Name)' (ID $($sg.Id))." -Expected $phrase)) {
        Write-Host "Aborted. Nothing was sent." -ForegroundColor Yellow; return
    }
}
else {
    if (-not (Read-Confirmation -Prompt "About to send $Command to $($todo.Count) $Platform device(s) in smart group '$($sg.Name)' (ID $($sg.Id))." -Expected 'YES')) {
        Write-Host "Aborted. Nothing was sent." -ForegroundColor Yellow; return
    }
}

# 8. Execute in batches
$results = New-Object System.Collections.Generic.List[object]
$accepted = New-Object System.Collections.Generic.List[int]
foreach ($d in $completed) { $accepted.Add($d) }
$attempted = 0
$failed = 0
$aborted = $false
$abortReason = $null
$retryPosts = -not $isDisruptive

function Send-One {
    param($Device)
    $uri = "$BaseApiUrl/mdm/devices/$($Device.DeviceId)/commands?command=$([uri]::EscapeDataString($Command))"
    $r = Invoke-Uem -Method POST -Uri $uri -Version 1 -RetryOnServerError:$retryPosts
    $rec = [ordered]@{
        DeviceId     = $Device.DeviceId
        Platform     = $Device.Platform
        Model        = $Device.Model
        Command      = $Command
        Status       = if ($r.Success) { 'Accepted' } else { 'Failed' }
        HttpStatus   = $r.StatusCode
        Attempts     = $r.Attempts
        Throttled    = $r.Throttled
        RetryAfterSeconds = $r.RetryAfterSeconds
        RetryAfterExceeded = $r.RetryAfterExceeded
        Message      = if ($r.Success) { '' } else { ([string]$r.Error -replace '[\r\n]+', ' ') }
        TimestampUtc = (Get-Date).ToUniversalTime().ToString('o')
    }
    if ($IncludeDeviceName) { $rec['DeviceName'] = $Device.Name }
    return [PSCustomObject]$rec
}

try {
    $index = 0
    $batchNo = 0

    if (-not $SkipCanary) {
        Write-Step "Canary: sending to device $($todo[0].DeviceId) only..."
        if (-not (Wait-ForQuota)) {
            $aborted = $true
            $abortReason = $script:QuotaStopReason
        }
    }
    if (-not $SkipCanary -and -not $aborted) {
        $c = Send-One -Device $todo[0]
        $results.Add($c); $attempted++; $index = 1
        if ($c.Status -ne 'Accepted') {
            $failed++
            $aborted = $true
            $abortReason = Get-ThrottleAbortReason -Rec $c
            if (-not $abortReason) { $abortReason = "Canary failed (HTTP $($c.HttpStatus)): $($c.Message)" }
            else { $abortReason = "Canary throttled. $abortReason" }
        }
        else {
            $accepted.Add([int]$c.DeviceId)
            Write-Host "Canary accepted (HTTP $($c.HttpStatus))." -ForegroundColor Green
        }
    }

    while (-not $aborted -and $index -lt $todo.Count) {
        $batchNo++
        $count = [math]::Min($BatchSize, $todo.Count - $index)
        Write-Step ("Batch {0}: devices {1}-{2} of {3}" -f $batchNo, ($index + 1), ($index + $count), $todo.Count)

        for ($k = 0; $k -lt $count; $k++) {
            if (-not (Wait-ForQuota)) {
                $aborted = $true
                $abortReason = $script:QuotaStopReason
                $index += $k
                break
            }
            $rec = Send-One -Device $todo[$index + $k]
            $results.Add($rec); $attempted++
            if ($rec.Status -eq 'Accepted') { $accepted.Add([int]$rec.DeviceId) } else { $failed++ }

            $throttleReason = Get-ThrottleAbortReason -Rec $rec
            if ($throttleReason) {
                $aborted = $true
                $abortReason = $throttleReason
                $index += ($k + 1)
                break
            }
            if ($attempted -ge $MinSampleForAbort -and (($failed * 100.0) / $attempted) -gt $MaxFailurePercent) {
                $aborted = $true
                $abortReason = "Failure rate {0:N0}% exceeded {1}% after {2} attempts." -f (($failed * 100.0) / $attempted), $MaxFailurePercent, $attempted
                $index += ($k + 1)
                break
            }
            if ($rec.HttpStatus -eq 401) {
                $aborted = $true
                $abortReason = if ($script:AuthMode -eq 'Basic') {
                    "HTTP 401 with Basic auth (credentials, aw-tenant-code or account rights rejected). Stopped without retrying. Fix, then re-run with -Resume."
                } else {
                    "HTTP 401 and the token could not be refreshed (pre-acquired token expired?). Re-run with -Resume."
                }
                $index += ($k + 1)
                break
            }
        }
        if ($aborted) { break }
        $index += $count

        Save-State -Path $stateFile -State ([ordered]@{
                SmartGroupId = $sg.Id; Platform = $Platform; Command = $Command
                UpdatedUtc = (Get-Date).ToUniversalTime().ToString('o'); Accepted = @($accepted)
            })
        Write-Host ("  batch done - accepted so far: {0}, failed: {1}" -f ($accepted.Count - $completed.Count), $failed)

        if ($index -lt $todo.Count -and $BatchPauseSeconds -gt 0) { Start-Sleep -Seconds $BatchPauseSeconds }
    }
}
finally {
    Save-State -Path $stateFile -State ([ordered]@{
            SmartGroupId = $sg.Id; Platform = $Platform; Command = $Command
            UpdatedUtc = (Get-Date).ToUniversalTime().ToString('o'); Accepted = @($accepted)
        })
    if ($results.Count -gt 0) {
        $results | Export-Csv -Path $resultCsv -NoTypeInformation -Encoding utf8
        [PSCustomObject]@{
            GeneratedUtc = (Get-Date).ToUniversalTime().ToString('o')
            ApiUrl       = $BaseApiUrl
            AuthMode     = $script:AuthMode
            UemVersion   = $UemVersion
            SmartGroupId = $sg.Id
            SmartGroup   = $sg.Name
            Platform     = $Platform
            Command      = $Command
            Attempted    = $attempted
            Accepted     = @($results | Where-Object { $_.Status -eq 'Accepted' }).Count
            Failed       = $failed
            Aborted      = $aborted
            AbortReason  = $abortReason
            RateLimiter  = [PSCustomObject]@{
                Requests = $script:Limiter.TotalRequests; ThrottleEvents = $script:Limiter.ThrottleEvents
                Retries = $script:Limiter.Retries; WaitSeconds = [math]::Round($script:Limiter.TotalWaitSeconds, 1)
                FinalIntervalMs = [math]::Round($script:Limiter.CurrentIntervalMs, 0)
                QuotaLimit = $script:Limiter.QuotaLimit; QuotaRemaining = $script:Limiter.QuotaRemaining
                QuotaResetUtc = $script:Limiter.QuotaResetUtc
            }
            Results      = $results
        } | ConvertTo-Json -Depth 6 | Out-File -FilePath $resultJson -Encoding utf8
    }
}

# 9. Summary
$elapsed = (Get-Date) - $runStart
Write-Host "`n================ SUMMARY ================" -ForegroundColor Cyan
Write-Host ("Attempted : {0} of {1}" -f $attempted, $todo.Count)
Write-Host ("Accepted  : {0}  (UEM queued the command; devices execute it later)" -f @($results | Where-Object { $_.Status -eq 'Accepted' }).Count) -ForegroundColor Green
Write-Host ("Failed    : {0}" -f $failed) -ForegroundColor $(if ($failed -gt 0) { 'Red' } else { 'Green' })
Write-Host ("Limiter   : {0} requests, {1} throttle event(s), {2} retries, {3:N1}s waiting, spacing now {4:N0} ms" -f $script:Limiter.TotalRequests, $script:Limiter.ThrottleEvents, $script:Limiter.Retries, $script:Limiter.TotalWaitSeconds, $script:Limiter.CurrentIntervalMs)
if ($null -ne $script:Limiter.QuotaRemaining) {
    Write-Host ("Quota window left: {0} of {1}, resets {2:u}" -f $script:Limiter.QuotaRemaining, $(if ($null -ne $script:Limiter.QuotaLimit) { $script:Limiter.QuotaLimit } else { '?' }), $script:Limiter.QuotaResetUtc)
}
Write-Host ("Elapsed   : {0:N1} minutes" -f $elapsed.TotalMinutes)
Write-Host "Results   : $resultCsv"
Write-Host "            $resultJson"
Write-Host "State     : $stateFile"
if ($aborted) {
    Write-Host "`nRUN STOPPED EARLY: $abortReason" -ForegroundColor Red
    Write-Host "Fix the cause, then re-run the same command with -Resume to continue." -ForegroundColor Yellow
}
if ($failed -gt 0) {
    Write-Host "`nFailure breakdown by HTTP status:" -ForegroundColor Yellow
    $results | Where-Object { $_.Status -eq 'Failed' } | Group-Object HttpStatus | Sort-Object Count -Descending |
        ForEach-Object { Write-Host ("  HTTP {0}: {1}" -f $(if ($_.Name) { $_.Name } else { 'n/a' }), $_.Count) }
}
