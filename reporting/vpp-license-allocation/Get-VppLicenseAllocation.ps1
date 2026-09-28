<#
.SYNOPSIS
    Reports Apple VPP (Volume Purchase Program) app license allocation/consumption from
    Workspace ONE UEM, flagging apps that are running low on allocatable licenses —
    either app-wide, or within a specific smart-group assignment.

.DESCRIPTION
    Authenticates to the Workspace ONE UEM REST API using OAuth 2.0 (client_credentials
    grant, credentials sent via HTTP Basic Auth header on the token request), then:

      1. GET {{baseUrl}}/mam/apps/purchased/search  (Accept: application/json;version=1)
         to enumerate purchased (VPP) apps for the given platform. This alone is
         enough to build the report — see FIELD NAMES below — including the
         per-smart-group assignment breakdown (see WHY PER-ASSIGNMENT MATTERS).
      2. Optionally, a per-app detail call — only as a genuine fallback for any
         app whose search record is missing the allocation block or the
         Assignments array, or when -IncludeAllocationDetail is passed to force
         a cross-check / pick up detail-only fields (OnHold, ExternallyRedeemed).
         V2 (GET {{baseUrl}}/mam/apps/purchased/{uuid}, version=2) is tried
         first, falling back to V1
         (GET {{baseUrl}}/mam/apps/purchased/{applicationid}, version=1) only if
         no Uuid is available or V2 itself fails. See "V1 vs V2" below for why.

    WHY PER-ASSIGNMENT MATTERS
    ---------------------------
    A VPP app's purchased licenses are handed out to devices through smart-group
    assignments, each with its own Allocated reservation carved out of the app's
    total pool. A device only receives the app if the SPECIFIC assignment it
    falls into still has unredeemed capacity (Allocated > Redeemed for that one
    assignment) — not if the app merely has spare capacity somewhere else, and
    not just because there's unallocated pool capacity sitting unassigned to any
    group. So an app can look perfectly healthy at the app-wide level
    (AvailableLicenses comfortably above threshold) while one specific
    assignment is fully exhausted, silently blocking new devices in that group
    from getting the app. This script therefore extracts every app's
    "Assignments" array (confirmed present on every app returned by search,
    2026-09-28, including flexible-assignment apps) and reports, per app:
    WorstAssignmentAvailable (the single tightest assignment) and
    AssignmentsBelowThreshold (how many assignments are at or below threshold),
    alongside the app-wide AvailableLicenses/TotalAllocated/TotalUnallocated
    figures — and flags the app if EITHER the app-wide figure or any individual
    assignment is at or below -LowAllocationThreshold.

    V1 VS V2 FOR THE PER-APP DETAIL CALL
    -------------------------------------
    V1 (.../purchased/{applicationid}, version=1) is the older, numeric-id
    endpoint. Confirmed 2026-09-28: it returns 501 Not Implemented for apps
    implementing flexible assignment (its own docs say as much), which in this
    tenant's 41-app catalog was true for 2 apps. It also has one field V2's
    sample didn't show (Licenses.ExternallyRedeemed).
    V2 (.../purchased/{uuid}, version=2) is the newer, uuid-based endpoint.
    Confirmed 2026-09-28 to serve both of the apps V1 refused, with no evidence
    it's restricted for classic/device-based apps either — nothing in its
    description carries V1's flexible-assignment caveat, and Omnissa's own
    naming ("New - Get purchased application...") positions it as the general
    replacement. Its response also includes richer per-assignment
    deployment_parameters (allow_management, prevent_removal, etc.) than V1's
    Deployment block.
    Net effect: V2 first, V1 as a fallback, is both faster in the common case
    (no wasted 501 round-trip before falling back) and strictly more capable
    (works for every app type observed so far). The one reason to keep V1 in
    the mix at all is ExternallyRedeemed and because V2's schema, despite being
    empirically confirmed here, is nowhere formally documented by Omnissa
    either (see FIELD NAMES below) — if V2 ever regresses for some app type,
    V1 remains available as a fallback rather than removed outright.

    where {{baseUrl}} = https://<YourApiServer>/api

    ---------------------------------------------------------------------------
    VALIDATION NOTE (per org data-accuracy policy — read before relying on this)
    ---------------------------------------------------------------------------
    ENDPOINTS / AUTH / PARAMS — confirmed against the official
    `uem-rest-bruno-2604.zip` Bruno collection (Workspace ONE UEM REST API,
    version 2604):
      - Base URL shape: https://{{YOUR_API_SERVER}}/api  (lowercase "api")
      - Auth: OAuth 2.0, grant_type=client_credentials, with client_id/client_secret
        sent via an HTTP Basic Authorization header on the token request (Bruno's
        collection-level auth config: credentials_placement = basic_auth_header),
        NOT as client_id/client_secret fields in the token request body.
      - No aw-tenant-code / API-key header is used anywhere in this collection.
      - Endpoint paths, HTTP methods, and query/path parameter names below (see the
        "Vpp App Search" and "Load Vpp Licensed App Allocation" requests in the
        MAM API V1 > PurchasedAppsV1 folder), including the Accept header version
        (version=1 for both of these V1 endpoints).
      - Query params: `locationgroupid` (integer OG id) and, separately,
        `organizationgroupuuid` (string OG UUID) — there is no
        `organizationgroupid` parameter.

    FIELD NAMES — the Bruno collection and Omnissa's own published OpenAPI specs
    (euc-dev/ws1-uem-apis, docs/versions/2604/mamv1.json + mamv2.json) both turned
    out not to document the response schema for these endpoints at all (mamv1.json
    has no Purchased Apps paths for 2604; mamv2.json's one purchased-app response
    model, PurchasedApplicationV2Model, is referenced but never defined). So this
    was instead confirmed directly against a live 2604 tenant via -DumpRawSample
    (search result for an Apple/iOS app, plus its allocation-detail record) on
    2026-09-28. Confirmed real shape:

      Search response, per app (top-level):
        ApplicationName, BundleId, Platform (integer enum, not a string),
        LocationGroupId (integer), OrganizationGroupUuid, RootOrganizationGroupName,
        Id.Value (the numeric application id used in the detail URL), Uuid,
        AppType ("Purchased"), and the allocation counts nested one level down
        under "ManagedDistribution":
          ManagedDistribution.Purchased   -> total licenses purchased
          ManagedDistribution.Burned      -> licenses redeemed/installed by users
          ManagedDistribution.OnHold      -> licenses on hold
          ManagedDistribution.Available   -> Purchased minus Burned; this is the
                                              "available licenses" figure used for
                                              -LowAllocationThreshold in this script.

      Search response also includes, per app, an "Assignments" array — one
      entry per smart-group this app is assigned to:
          Assignments[].SmartGroupId -> the smart group this reservation belongs to
          Assignments[].Allocated    -> licenses reserved for this specific assignment
          Assignments[].Redeemed     -> of those, how many are actually installed
      Confirmed 2026-09-28: summing Assignments[].Allocated across all of an
      app's assignments exactly equals that app's separately-reported total
      Allocated figure (Intelligent Hub: 10+30=40; Netflix: 1+2=3, both matching
      the V2 detail endpoint's licenses_summary.allocated) — so TotalAllocated
      and TotalUnallocated (= Purchased - Allocated) are derived from the search
      response alone, no extra per-app API call required in the common case.

      Allocation-detail response (GET /mam/apps/purchased/{applicationid}), under
      "Licenses" (V1, PascalCase) or "licenses_summary" (V2, snake_case):
          Licenses.TotalLicenses / licenses_summary.total   -> matches ManagedDistribution.Purchased
          Licenses.Allocated / licenses_summary.allocated   -> matches the Assignments[].Allocated sum
          Licenses.Unallocated / licenses_summary.unallocated -> matches Purchased - Allocated
          Licenses.Redeemed / licenses_summary.redeemed     -> matches ManagedDistribution.Burned
          Licenses.OnHold / licenses_summary.on_hold, Licenses.ExternallyRedeemed (V1 only, not seen in the V2 sample)

    Since the search response already carries everything needed — including the
    per-assignment breakdown — the script defaults to a single API call per
    page (no per-app detail calls), only falling back to a detail endpoint for
    an individual app if its search record is missing the ManagedDistribution
    block or the Assignments array (a defensive path for tenants/versions that
    may differ), or when -IncludeAllocationDetail is explicitly requested.
    $FieldMap below still lists secondary/legacy candidate names for resilience
    across tenants/versions, but the primary, confirmed names above are tried
    first.

.PARAMETER ApiUrl
    Your Workspace ONE UEM REST API host name only — no https://, no path, e.g.
    as137.awmdm.com (found under Groups & Settings > All Settings > System >
    Advanced > API > REST API, at the Customer OG or below). The script builds
    https://<ApiUrl>/api from this, matching the validated Bruno collection.

.PARAMETER OAuthTokenUrl
    Region-specific OAuth 2.0 token URL for your datacenter (see Omnissa's
    "Datacenter and Token URLs for OAuth 2.0 Support" documentation). Not needed
    if you pass -AccessToken directly.

.PARAMETER ClientId
    OAuth 2.0 client ID from Groups & Settings > Configurations > OAuth Client
    Management. Not needed if you pass -AccessToken directly.

.PARAMETER ClientSecret
    OAuth 2.0 client secret issued alongside the client ID (shown only once at
    creation). Sent via HTTP Basic Auth on the token request, per the validated
    collection. Not needed if you pass -AccessToken directly.

.PARAMETER AccessToken
    A pre-acquired OAuth bearer token. If supplied, ClientId/ClientSecret/
    OAuthTokenUrl are ignored and this token is used directly.

.PARAMETER LocationGroupId
    Optional. Numeric Location Group / Organization Group id to scope the search
    to (query param `locationgroupid`, confirmed in the collection).

.PARAMETER OrganizationGroupUuid
    Optional. Organization Group UUID to scope the search to (query param
    `organizationgroupuuid`, confirmed in the collection). Use this or
    -LocationGroupId, not necessarily both.

.PARAMETER Platform
    Platform filter passed to the API's `platform` query param. Defaults to
    'Apple', which is how this API represents VPP apps for iOS/iPadOS/macOS.
    Confirm the exact literal your tenant expects with -DumpRawSample if unsure.
    Note: the response's own per-app "Platform" field doesn't appear to
    distinguish Apple sub-platforms (iOS vs macOS vs visionOS) — see DESIGN.md —
    so this script doesn't surface it in the report at all.

.PARAMETER LowAllocationThreshold
    The configurable "XX" — an app is flagged if EITHER its app-wide
    AvailableLicenses, OR any individual smart-group assignment's own available
    count (that assignment's Allocated minus Redeemed), is at or below this
    number. The per-assignment check exists because a device only fails to
    receive an app when its OWN assignment runs out — the app-wide figure alone
    can look healthy while one assignment is already exhausted. Default: 10.

.PARAMETER OutputFormat
    'Json' or 'Xml'. Default: Json.

.PARAMETER OutputPath
    File path for the report. Defaults to .\VppAllocationReport_<timestamp>.<ext>
    in the current directory.

.PARAMETER PageSize
    Page size for the paginated /search call. Default: 500.

.PARAMETER SkipDetailLookup
    The search response has been confirmed to already include full allocation
    counts (ManagedDistribution.Purchased/Burned/Available) AND the
    per-assignment Assignments array, so no per-app detail call is made by
    default. This switch additionally disables the automatic fallback detail
    call for any app whose search record is somehow missing that data — those
    apps will be reported with 'Data unavailable' counts instead of an extra
    API call.

.PARAMETER IncludeAllocationDetail
    Forces a per-app detail call (V2 first, falling back to V1) for every app,
    even though TotalAllocated/TotalUnallocated are already derived from the
    search response's own Assignments array by default. Use this to
    cross-check that derivation against the API's own authoritative
    Allocated/Unallocated figures, or to pick up detail-only fields
    (OnHold/ExternallyRedeemed) that the search response's own OnHold field
    might not fully capture. Adds one extra HTTP call per app; off by default.

.PARAMETER DumpRawSample
    Prints the raw, untouched JSON for the first app from the search response,
    and from the per-app allocation-detail endpoint too, then exits without
    generating a report. Use this once per environment/version to confirm
    $FieldMap still matches if Omnissa changes the schema in a future release.

.PARAMETER InspectApplicationId
    Diagnostic mode: takes one or more numeric application ids. For each, prints
    its raw search record, the result of the V1 allocation-detail endpoint
    (GET /mam/apps/purchased/{applicationid}, version=1), and — using the Uuid
    from the search record — the result of the V2 endpoint
    (GET /mam/apps/purchased/{uuid}, version=2). Useful when the V1 endpoint
    returns 501 Not Implemented, which per its own documentation happens for
    apps implementing flexible assignment; this lets you see whether V2 (or the
    search response alone) has usable data for that specific app instead. Exits
    without generating a report.

.PARAMETER IncludeRawSourceData
    Attaches the complete, untouched raw JSON this script actually received for
    each app to the report: RawSearchRecord (always, from the search response)
    and, whenever a per-app detail call was made (see -IncludeAllocationDetail
    and the automatic fallback), RawDetailRecord plus RawDetailSource ('V1' or
    'V2') showing which endpoint it came from. Use this when you want a
    genuinely complete dump — every field the API returns, including nested
    Assignments/assignments arrays and deployment parameters — rather than just
    this script's curated summary columns. Significantly increases output size
    for large catalogs.

.PARAMETER ShowAllInConsole
    By default the console only prints the flagged (low-availability) subset,
    to keep output short — the JSON/XML file already contains every evaluated
    app regardless. Pass this switch to also print a full table of all apps to
    the console.

.EXAMPLE
    .\Get-VppLicenseAllocation.ps1 -ApiUrl as137.awmdm.com `
        -OAuthTokenUrl https://na.uemauth.workspaceone.com/connect/token `
        -ClientId $env:WS1_CLIENT_ID -ClientSecret $env:WS1_CLIENT_SECRET `
        -LowAllocationThreshold 15 -OutputFormat Json

.EXAMPLE
    .\Get-VppLicenseAllocation.ps1 -ApiUrl as137.awmdm.com -AccessToken $token -DumpRawSample
#>

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

    [Parameter(Mandatory = $false)]
    [int]$LocationGroupId,

    [Parameter(Mandatory = $false)]
    [string]$OrganizationGroupUuid,

    [Parameter(Mandatory = $false)]
    [string]$Platform = 'Apple',

    [Parameter(Mandatory = $false)]
    [int]$LowAllocationThreshold = 10,

    [Parameter(Mandatory = $false)]
    [ValidateSet('Json', 'Xml')]
    [string]$OutputFormat = 'Json',

    [Parameter(Mandatory = $false)]
    [string]$OutputPath,

    [Parameter(Mandatory = $false)]
    [int]$PageSize = 500,

    [Parameter(Mandatory = $false)]
    [switch]$SkipDetailLookup,

    [Parameter(Mandatory = $false)]
    [switch]$IncludeAllocationDetail,

    [Parameter(Mandatory = $false)]
    [switch]$DumpRawSample,

    [Parameter(Mandatory = $false)]
    [int[]]$InspectApplicationId,

    [Parameter(Mandatory = $false)]
    [switch]$IncludeRawSourceData,

    [Parameter(Mandatory = $false)]
    [switch]$ShowAllInConsole
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$BaseApiUrl = "https://$ApiUrl/api"

# Shared OAuth/field-resolution helpers (Get-AccessTokenViaClientCredentials,
# Get-AuthHeaders, Resolve-Field) live in the repo's shared module so other
# WS1 scripts can reuse them without copy-pasting. See shared/Ws1ApiCore.psm1.
Import-Module (Join-Path $PSScriptRoot '..\..\shared\Ws1ApiCore.psm1') -Force

# ---------------------------------------------------------------------------
# Field mapping — confirmed 2026-09-28 against a live 2604 tenant, both via
# -DumpRawSample (V1 search + allocation-detail) and -InspectApplicationId
# (V2 lookup, for two flexible-assignment apps where V1's detail endpoint
# returned 501). Names support dotted paths (e.g. 'ManagedDistribution.Purchased')
# to reach into nested objects. Left side is the canonical name this script
# uses internally; right side is a list of candidate source property paths
# tried in order (first match wins) — confirmed real paths are listed first
# (V1 search, then V1 detail, then V2), followed by speculative fallbacks kept
# for resilience across other tenants/versions. Re-run -DumpRawSample after any
# Omnissa release to confirm this still matches before trusting the report.
#
# V2's response uses snake_case and nests everything under "licenses_summary":
# total/on_hold/redeemed/allocated/unallocated. It has no direct "available"
# field (same as V1 detail) — confirmed equal to total - redeemed in both
# inspected samples (55-3=52 and 3-2=1, matching each app's V1 search
# ManagedDistribution.Available exactly), so the existing Purchased-Redeemed
# fallback below covers it without a dedicated V2 "Available" candidate.
# ---------------------------------------------------------------------------
$FieldMap = @{
    AppId        = @('Id', 'ApplicationId', 'ApplicationID')
    AppUuid      = @('Uuid')
    AppName      = @('ApplicationName', 'AppName', 'Name')
    BundleId     = @('BundleId', 'BundleID', 'identifier', 'AppIdentifier')
    Platform     = @('Platform')
    LocationName = @('RootOrganizationGroupName', 'LocationGroupName', 'LocationName')
    Purchased    = @('ManagedDistribution.Purchased', 'Licenses.TotalLicenses', 'licenses_summary.total', 'TotalPurchasedCount', 'PurchasedCount', 'TotalPurchased', 'TotalNumberOfLicenses')
    Redeemed     = @('ManagedDistribution.Burned', 'Licenses.Redeemed', 'licenses_summary.redeemed', 'TotalProvisionedCount', 'ProvisionedCount', 'AssignedCount', 'TotalAssignedCount', 'LicensesAssigned')
    Available    = @('ManagedDistribution.Available', 'LicensesAvailable', 'AvailableCount', 'AvailableLicenses')
    OnHold       = @('ManagedDistribution.OnHold', 'Licenses.OnHold', 'licenses_summary.on_hold')
    Allocated    = @('Licenses.Allocated', 'licenses_summary.allocated')
    Unallocated  = @('Licenses.Unallocated', 'licenses_summary.unallocated')
    # The search response's own "Assignments" array (confirmed present on every
    # app, including flexible-assignment ones) is the key to per-smart-group
    # visibility — see Get-AssignmentBreakdown below.
    Assignments  = @('Assignments', 'assignments')
    AssignSmartGroup = @('SmartGroupId', 'smart_group_uuid')
    AssignAllocated  = @('Allocated', 'allocated')
    AssignRedeemed   = @('Redeemed', 'redeemed')
}

function Get-AssignmentBreakdown {
    <#
        Extracts per-smart-group license allocation from an app's "Assignments"
        (V1 search/detail, PascalCase) or "assignments" (V2 detail, snake_case)
        array. This is the actual mechanism the user is watching for: a device
        that falls into a given smart-group assignment only receives the app if
        THAT assignment's own Allocated pool still has unredeemed capacity — the
        app-level AvailableLicenses figure can look fine overall while one
        specific assignment is fully exhausted (Allocated == Redeemed for that
        assignment), because Allocated is a per-assignment reservation out of
        the app's total purchased pool, not a shared free-for-all.
        Confirmed 2026-09-28: summing every assignment's Allocated exactly
        matches the app's separately-reported Allocated total in both V2 samples
        checked (Intelligent Hub: 10+30=40, matches licenses_summary.allocated=40;
        Netflix: 1+2=3, matches licenses_summary.allocated=3) — so this also
        gives us TotalAllocated/TotalUnallocated for free from the search
        response alone, no extra per-app API call required in the common case.
        Returns @{ Assignments = <array of PSCustomObject>; TotalAllocated = <int|$null> }
    #>
    param($RawApp, [int]$Threshold)

    $rawAssignments = Resolve-Field -Object $RawApp -Names $FieldMap.Assignments
    $result = New-Object System.Collections.Generic.List[object]
    $sumAllocated = $null

    # Use an explicit null check, not truthiness — an app assigned to zero
    # smart groups legitimately has an EMPTY Assignments array, which is falsy
    # in PowerShell's `if ($x)` but is a confirmed "0 allocated", not an
    # "unknown" that should trigger the detail-call fallback in the caller.
    if ($null -ne $rawAssignments) {
        $sumAllocated = 0
        foreach ($a in $rawAssignments) {
            $sgId      = Resolve-Field -Object $a -Names $FieldMap.AssignSmartGroup
            $allocated = Resolve-Field -Object $a -Names $FieldMap.AssignAllocated
            $redeemed  = Resolve-Field -Object $a -Names $FieldMap.AssignRedeemed

            $allocatedInt = if ($null -ne $allocated) { [int]$allocated } else { $null }
            $redeemedInt  = if ($null -ne $redeemed)  { [int]$redeemed }  else { $null }
            $availInt     = if ($null -ne $allocatedInt -and $null -ne $redeemedInt) { $allocatedInt - $redeemedInt } else { $null }

            if ($null -ne $allocatedInt) {
                if ($null -eq $sumAllocated) { $sumAllocated = 0 }
                $sumAllocated += $allocatedInt
            }

            $result.Add([PSCustomObject]@{
                SmartGroupId = $sgId
                Allocated    = $allocatedInt
                Redeemed     = $redeemedInt
                Available    = $availInt
                IsLow        = ($null -ne $availInt) -and ($availInt -le $Threshold)
            })
        }
    }

    return @{ Assignments = $result.ToArray(); TotalAllocated = $sumAllocated }
}

function Get-AllPurchasedVppApps {
    <#
        Pages through the confirmed endpoint:
          GET {baseUrl}/mam/apps/purchased/search
        Confirmed query params (from the Bruno collection): applicationname,
        isassigned, bundleid, locationgroupid, organizationgroupuuid, model,
        status, platform, page, pagesize, orderby.
        Returns the raw (unmapped) list of app records.
    #>
    param(
        [string]$Base,
        [hashtable]$Headers,
        [string]$PlatformFilter,
        [int]$LocGroupId,
        [string]$OrgGroupUuid,
        [int]$Size
    )

    $allApps = New-Object System.Collections.Generic.List[object]
    $page = 0
    $endpoint = "$Base/mam/apps/purchased/search"

    while ($true) {
        $queryParams = [ordered]@{
            platform = $PlatformFilter
            page     = $page
            pagesize = $Size
        }
        if ($LocGroupId)  { $queryParams['locationgroupid'] = $LocGroupId }
        if ($OrgGroupUuid) { $queryParams['organizationgroupuuid'] = $OrgGroupUuid }

        $qs  = ($queryParams.GetEnumerator() | ForEach-Object { "$($_.Key)=$([uri]::EscapeDataString([string]$_.Value))" }) -join '&'
        $uri = "$endpoint`?$qs"

        Write-Verbose "Fetching page $page : $uri"
        try {
            $resp = Invoke-RestMethod -Method Get -Uri $uri -Headers $Headers
        }
        catch {
            throw "Purchased VPP apps search failed on page $page : $($_.Exception.Message)"
        }

        # UNVERIFIED wrapper name (see VALIDATION NOTE) — try common candidates,
        # fall back to treating the whole response as the item list.
        $items = $null
        foreach ($listProp in @('Application', 'PurchasedApps', 'Apps', 'Items')) {
            if ($resp.PSObject.Properties.Name -contains $listProp) {
                $items = $resp.$listProp
                break
            }
        }
        if ($null -eq $items) {
            if ($resp -is [System.Array]) { $items = $resp } else { $items = @() }
        }

        if (-not $items -or $items.Count -eq 0) { break }
        foreach ($i in $items) { $allApps.Add($i) }

        $total = Resolve-Field -Object $resp -Names @('Total', 'TotalResults', 'TotalCount')
        $page++

        if ($items.Count -lt $Size) { break }
        if ($total -and ($allApps.Count -ge [int]$total)) { break }
        if ($page -gt 1000) {
            Write-Warning "Stopped after 1000 pages as a safety limit — check pagination logic/response shape with -DumpRawSample."
            break
        }
    }

    return $allApps
}

function Get-VppAppAllocationDetail {
    <#
        Confirmed endpoint (MAM API V1 > PurchasedAppsV1 > "Load Vpp Licensed
        App Allocation"): GET {baseUrl}/mam/apps/purchased/{applicationid}
        Confirmed response shape (2026-09-28, live tenant): a "Licenses" object
        with TotalLicenses/Allocated/Unallocated/Redeemed/OnHold/ExternallyRedeemed,
        plus "Assignments" and "Deployment" — see FIELD NAMES in the header.
    #>
    param([string]$Base, [hashtable]$Headers, $ApplicationId)

    $uri = "$Base/mam/apps/purchased/$ApplicationId"
    try {
        return Invoke-RestMethod -Method Get -Uri $uri -Headers $Headers
    }
    catch {
        $status = $null
        if ($_.Exception.Response) { $status = [int]$_.Exception.Response.StatusCode }
        if ($status -eq 501) {
            Write-Warning "Allocation detail lookup for application id $ApplicationId returned 501 Not Implemented — per this endpoint's own documented limitation, it is 'Not valid for apps implementing flexible assignment.' This app is likely a flexible-assignment VPP app; try -InspectApplicationId $ApplicationId to check the V2 endpoint instead."
        }
        else {
            Write-Warning "Allocation detail lookup failed for application id $ApplicationId : $($_.Exception.Message)"
        }
        return $null
    }
}

function Get-PurchasedAppByUuidV2 {
    <#
        Confirmed endpoint (MAM API V2 > PurchasedAppsV2 > "New - Get purchased
        application and assignment details"): GET {baseUrl}/mam/apps/purchased/{uuid}
        operationId PurchasedAppsV2_GetPurchasedApplicationAndAssignments,
        Accept: application/json;version=2. This is the V2 replacement the V1
        allocation endpoint's own docs point to for apps it can't serve
        (flexible assignment) — confirmed 2026-09-28 via -InspectApplicationId
        against two apps that returned 501 from V1. Response schema, despite
        Omnissa's own OpenAPI spec never actually defining
        PurchasedApplicationV2Model (dangling $ref), is confirmed for real:
        snake_case, with counts nested under "licenses_summary"
        (total/on_hold/redeemed/allocated/unallocated — no direct "available"
        field, see $FieldMap comment above) and a "uuid"/"name"/"identifier" top
        level plus an "assignments" array keyed by smart_group_uuid.
    #>
    param([string]$Base, [string]$Token, [string]$Uuid)

    $v2Headers = Get-AuthHeaders -Token $Token -Version 2
    $uri = "$Base/mam/apps/purchased/$Uuid"
    try {
        return Invoke-RestMethod -Method Get -Uri $uri -Headers $v2Headers
    }
    catch {
        Write-Warning "V2 purchased-app lookup failed for uuid $Uuid : $($_.Exception.Message)"
        return $null
    }
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

if ($PSCmdlet.ParameterSetName -eq 'ClientCredentials') {
    $token = Get-AccessTokenViaClientCredentials -TokenUrl $OAuthTokenUrl -Id $ClientId -Secret $ClientSecret
}
else {
    $token = $AccessToken
}

$headers = Get-AuthHeaders -Token $token

Write-Verbose "Querying purchased VPP apps for platform '$Platform' from $BaseApiUrl"
$rawApps = Get-AllPurchasedVppApps -Base $BaseApiUrl -Headers $headers -PlatformFilter $Platform `
    -LocGroupId $LocationGroupId -OrgGroupUuid $OrganizationGroupUuid -Size $PageSize

if (-not $rawApps -or $rawApps.Count -eq 0) {
    Write-Warning "No purchased VPP apps were returned. Data unavailable — verify LocationGroupId/OrganizationGroupUuid/Platform scope, or that VPP content exists in this tenant."
    return
}

if ($InspectApplicationId -and $InspectApplicationId.Count -gt 0) {
    foreach ($targetId in $InspectApplicationId) {
        $match = $rawApps | Where-Object { (Resolve-Field -Object $_ -Names $FieldMap.AppId) -eq $targetId } | Select-Object -First 1

        Write-Host "`n=====================================================================" -ForegroundColor Cyan
        Write-Host "Application id $targetId" -ForegroundColor Cyan
        Write-Host "=====================================================================" -ForegroundColor Cyan

        if (-not $match) {
            Write-Warning "No app with id $targetId was found in the current search scope (LocationGroupId/OrganizationGroupUuid/Platform) — widen the scope or check the id."
            continue
        }

        Write-Host "`n--- Search record (raw, unmapped) ---`n" -ForegroundColor Yellow
        $match | ConvertTo-Json -Depth 8

        Write-Host "`n--- V1 allocation detail: GET /mam/apps/purchased/$targetId (version=1) ---`n" -ForegroundColor Yellow
        $detailV1 = Get-VppAppAllocationDetail -Base $BaseApiUrl -Headers $headers -ApplicationId $targetId
        if ($detailV1) { $detailV1 | ConvertTo-Json -Depth 8 }

        $uuid = Resolve-Field -Object $match -Names $FieldMap.AppUuid
        if ($uuid) {
            Write-Host "`n--- V2 lookup: GET /mam/apps/purchased/$uuid (version=2) ---`n" -ForegroundColor Yellow
            $detailV2 = Get-PurchasedAppByUuidV2 -Base $BaseApiUrl -Token $token -Uuid $uuid
            if ($detailV2) { $detailV2 | ConvertTo-Json -Depth 8 }
        }
        else {
            Write-Warning "No Uuid found on the search record for app id $targetId — cannot attempt the V2 lookup."
        }
    }
    Write-Host "`nDone inspecting. No report was generated (diagnostic mode).`n" -ForegroundColor Cyan
    return
}

if ($DumpRawSample) {
    Write-Host "`n=== Raw sample record from /mam/apps/purchased/search (first result, unmapped) ===`n" -ForegroundColor Cyan
    $rawApps[0] | ConvertTo-Json -Depth 8

    $sampleId = Resolve-Field -Object $rawApps[0] -Names $FieldMap.AppId
    if ($sampleId) {
        Write-Host "`n=== Raw sample record from /mam/apps/purchased/$sampleId (allocation detail, unmapped) ===`n" -ForegroundColor Cyan
        $detail = Get-VppAppAllocationDetail -Base $BaseApiUrl -Headers $headers -ApplicationId $sampleId
        if ($detail) { $detail | ConvertTo-Json -Depth 8 }
    }
    else {
        Write-Warning "Could not resolve an application id from the search result's $($FieldMap.AppId -join '/') fields to fetch a detail sample."
    }

    Write-Host "`nCompare the property names above against `$FieldMap in this script and adjust if needed.`n" -ForegroundColor Cyan
    return
}

$reportItems = foreach ($app in $rawApps) {
    $appId    = Resolve-Field -Object $app -Names $FieldMap.AppId
    $appName  = Resolve-Field -Object $app -Names $FieldMap.AppName
    $bundleId = Resolve-Field -Object $app -Names $FieldMap.BundleId
    $location = Resolve-Field -Object $app -Names $FieldMap.LocationName

    # The search response already carries ManagedDistribution AND the
    # per-assignment Assignments array (confirmed 2026-09-28 on every app,
    # including flexible-assignment ones) — try it first, no extra API call.
    $purchased = Resolve-Field -Object $app -Names $FieldMap.Purchased
    $redeemed  = Resolve-Field -Object $app -Names $FieldMap.Redeemed
    $available = Resolve-Field -Object $app -Names $FieldMap.Available
    $onHold    = Resolve-Field -Object $app -Names $FieldMap.OnHold
    $allocated = $null
    $unallocated = $null

    $breakdown = Get-AssignmentBreakdown -RawApp $app -Threshold $LowAllocationThreshold
    $assignments = $breakdown.Assignments
    if ($null -ne $breakdown.TotalAllocated) { $allocated = $breakdown.TotalAllocated }

    $rawDetailRecord = $null
    $rawDetailSource = $null
    # A detail call is now only needed as a genuine fallback (search missing
    # ManagedDistribution/Assignments) or when explicitly requested — the
    # allocation breakdown above already comes for free from the search
    # response in the common case.
    $needsDetail = $IncludeAllocationDetail -or ($null -eq $purchased -and $null -eq $available) -or ($null -eq $allocated)
    if ($needsDetail -and -not $SkipDetailLookup -and $appId) {
        # V2 is tried first: confirmed (2026-09-28) to serve flexible-assignment
        # apps that V1's detail endpoint 501s on, and nothing observed suggests
        # V2 is any less capable for classic/device-based apps either — it's the
        # newer, more general "get purchased app + assignments" endpoint. V1 is
        # kept only as a fallback in case a Uuid is ever missing or V2 itself
        # fails, and because it has one field V2's sample didn't show
        # (ExternallyRedeemed). See DESIGN.md for the full V1-vs-V2 writeup.
        $uuidForDetail = Resolve-Field -Object $app -Names $FieldMap.AppUuid
        if ($uuidForDetail) {
            $rawDetailRecord = Get-PurchasedAppByUuidV2 -Base $BaseApiUrl -Token $token -Uuid $uuidForDetail
            $rawDetailSource = 'V2'
        }
        if (-not $rawDetailRecord -and $appId) {
            $rawDetailRecord = Get-VppAppAllocationDetail -Base $BaseApiUrl -Headers $headers -ApplicationId $appId
            $rawDetailSource = 'V1'
        }
        if ($rawDetailRecord) {
            if ($null -eq $purchased) { $purchased = Resolve-Field -Object $rawDetailRecord -Names $FieldMap.Purchased }
            if ($null -eq $redeemed)  { $redeemed  = Resolve-Field -Object $rawDetailRecord -Names $FieldMap.Redeemed }
            if ($null -eq $available) { $available = Resolve-Field -Object $rawDetailRecord -Names $FieldMap.Available }
            if ($null -eq $onHold)    { $onHold    = Resolve-Field -Object $rawDetailRecord -Names $FieldMap.OnHold }
            # Detail endpoints report Allocated/Unallocated directly too — prefer
            # that over our own sum-from-Assignments if it disagrees, since it's
            # the API's own authoritative figure rather than a derived one.
            $detailAllocated = Resolve-Field -Object $rawDetailRecord -Names $FieldMap.Allocated
            if ($null -ne $detailAllocated) { $allocated = $detailAllocated }
            $unallocated = Resolve-Field -Object $rawDetailRecord -Names $FieldMap.Unallocated
            if (-not $assignments -or $assignments.Count -eq 0) {
                $detailBreakdown = Get-AssignmentBreakdown -RawApp $rawDetailRecord -Threshold $LowAllocationThreshold
                if ($detailBreakdown.Assignments.Count -gt 0) { $assignments = $detailBreakdown.Assignments }
            }
        }
    }

    if ($null -eq $available -and $null -ne $purchased -and $null -ne $redeemed) {
        # Fall back to computing availability when the API doesn't return it
        # directly. Confirmed equivalent to ManagedDistribution.Available =
        # Purchased - Burned in every observed sample (all had OnHold = 0, so
        # this hasn't been confirmed one way or the other for whether OnHold
        # would also need subtracting here if it's ever nonzero — see DESIGN.md).
        $available = [int]$purchased - [int]$redeemed
    }

    $purchasedInt   = if ($null -ne $purchased)   { [int]$purchased }   else { $null }
    $redeemedInt    = if ($null -ne $redeemed)    { [int]$redeemed }    else { $null }
    $availableInt   = if ($null -ne $available)   { [int]$available }  else { $null }
    $onHoldInt      = if ($null -ne $onHold)      { [int]$onHold }     else { $null }
    $allocatedInt   = if ($null -ne $allocated)   { [int]$allocated }  else { $null }
    $unallocatedInt = if ($null -ne $unallocated) { [int]$unallocated }
                      elseif ($null -ne $purchasedInt -and $null -ne $allocatedInt) { $purchasedInt - $allocatedInt }
                      else { $null }

    $percentUsed = if ($purchasedInt -and $purchasedInt -gt 0 -and $null -ne $redeemedInt) {
        [math]::Round(($redeemedInt / $purchasedInt) * 100, 1)
    } else { $null }

    # The number that actually matters for "will a device stop getting this
    # app": the tightest (lowest-available) individual assignment, not just
    # the app-wide pool. A device only fails to receive the app when ITS
    # smart-group assignment runs out, even if other assignments (or the
    # unallocated pool) still have room.
    $assignmentAvailables = $assignments | Where-Object { $null -ne $_.Available } | ForEach-Object { $_.Available }
    # Measure-Object always returns .Minimum as [double] even over integer input —
    # cast back to [int] so this doesn't print as "2.000" in Format-Table/JSON.
    $worstAssignmentAvailable = if ($assignmentAvailables) { [int](($assignmentAvailables | Measure-Object -Minimum).Minimum) } else { $null }
    $assignmentsBelowThreshold = ($assignments | Where-Object { $_.IsLow }).Count

    $isLow = (($null -ne $availableInt) -and ($availableInt -le $LowAllocationThreshold)) -or ($assignmentsBelowThreshold -gt 0)
    $dataComplete = ($null -ne $purchasedInt) -and ($null -ne $redeemedInt) -and ($null -ne $availableInt)

    $item = [ordered]@{
        ApplicationId             = $appId
        ApplicationName           = if ($appName) { $appName } else { 'Data unavailable' }
        BundleId                  = if ($bundleId) { $bundleId } else { 'Data unavailable' }
        LocationName              = if ($location) { $location } else { $null }
        TotalPurchased            = $purchasedInt
        TotalRedeemed             = $redeemedInt
        TotalOnHold               = $onHoldInt
        AvailableLicenses         = $availableInt
        TotalAllocated            = $allocatedInt
        TotalUnallocated          = $unallocatedInt
        WorstAssignmentAvailable  = $worstAssignmentAvailable
        AssignmentsBelowThreshold = $assignmentsBelowThreshold
        PercentUsed               = $percentUsed
        LowAllocation             = $isLow
        DataComplete              = $dataComplete
        Assignments               = $assignments
    }
    if ($IncludeRawSourceData) {
        $item['RawSearchRecord'] = $app
        $item['RawDetailRecord'] = $rawDetailRecord
        $item['RawDetailSource'] = $rawDetailSource
    }
    [PSCustomObject]$item
}

$reportItems = $reportItems | Sort-Object -Property @{Expression = 'LowAllocation'; Descending = $true}, @{Expression = 'AvailableLicenses'; Descending = $false}

$flagged = $reportItems | Where-Object { $_.LowAllocation }
$incomplete = $reportItems | Where-Object { -not $_.DataComplete }

$report = [PSCustomObject]@{
    GeneratedUtc           = (Get-Date).ToUniversalTime().ToString('o')
    ApiUrl                 = $BaseApiUrl
    Platform               = $Platform
    LowAllocationThreshold = $LowAllocationThreshold
    TotalAppsEvaluated     = $reportItems.Count
    AppsFlaggedLow         = $flagged.Count
    AppsWithIncompleteData = $incomplete.Count
    Apps                   = $reportItems
}

if (-not $OutputPath) {
    $ts = Get-Date -Format 'yyyyMMdd_HHmmss'
    $ext = if ($OutputFormat -eq 'Json') { 'json' } else { 'xml' }
    $OutputPath = ".\VppAllocationReport_$ts.$ext"
}

if ($OutputFormat -eq 'Json') {
    $report | ConvertTo-Json -Depth 8 | Out-File -FilePath $OutputPath -Encoding utf8
}
else {
    # Simple, readable custom XML rather than PowerShell's verbose CLIXML.
    $xmlDoc = New-Object System.Xml.XmlDocument
    $root = $xmlDoc.CreateElement('VppAllocationReport')
    $root.SetAttribute('GeneratedUtc', $report.GeneratedUtc)
    $root.SetAttribute('ApiUrl', $report.ApiUrl)
    $root.SetAttribute('Platform', $report.Platform)
    $root.SetAttribute('LowAllocationThreshold', $LowAllocationThreshold)
    $root.SetAttribute('TotalAppsEvaluated', $report.TotalAppsEvaluated)
    $root.SetAttribute('AppsFlaggedLow', $report.AppsFlaggedLow)
    $xmlDoc.AppendChild($root) | Out-Null

    foreach ($item in $reportItems) {
        $el = $xmlDoc.CreateElement('App')
        $el.SetAttribute('LowAllocation', $item.LowAllocation)
        foreach ($prop in $item.PSObject.Properties.Name) {
            if ($prop -eq 'LowAllocation') { continue }
            $child = $xmlDoc.CreateElement($prop)
            $value = $item.$prop
            if ($null -ne $value -and $value -isnot [string] -and ($value -is [System.Management.Automation.PSCustomObject] -or $value -is [System.Array])) {
                # Nested objects (the per-assignment Assignments array always;
                # the raw records only with -IncludeRawSourceData) — flatten to
                # a JSON string so the XML stays well-formed rather than
                # emitting ".ToString()" noise for a complex object.
                $child.InnerText = ($value | ConvertTo-Json -Depth 8 -Compress)
            }
            else {
                $child.InnerText = [string]$value
            }
            $el.AppendChild($child) | Out-Null
        }
        $root.AppendChild($el) | Out-Null
    }
    $resolvedOutputPath = if ([System.IO.Path]::IsPathRooted($OutputPath)) {
        $OutputPath
    } else {
        Join-Path -Path (Get-Location).Path -ChildPath $OutputPath
    }
    $xmlDoc.Save($resolvedOutputPath)
}

# ---------------------------------------------------------------------------
# Console display columns — short, scannable labels for the terminal only.
# The JSON/XML output always uses the full property names (ApplicationName,
# TotalPurchased, etc.) — see README.md's "Field reference" table for the
# authoritative mapping between these console labels and those field names,
# since a console screenshot alone doesn't carry that mapping with it.
# ---------------------------------------------------------------------------
$ColApp        = @{Label = 'App';         Expression = { $_.ApplicationName } }
$ColPurchased  = @{Label = 'Purch';       Expression = { $_.TotalPurchased } }
$ColRedeemed   = @{Label = 'Redm';        Expression = { $_.TotalRedeemed } }
$ColAvailApp   = @{Label = 'Avail(App)';  Expression = { $_.AvailableLicenses } }
$ColAllocated  = @{Label = 'Alloc';       Expression = { $_.TotalAllocated } }
$ColUnalloc    = @{Label = 'Unalloc';     Expression = { $_.TotalUnallocated } }
$ColWorstAvail = @{Label = 'Avail(Grp)';  Expression = { if ($null -ne $_.WorstAssignmentAvailable) { $_.WorstAssignmentAvailable } else { '-' } } }
$ColGrpsBelow  = @{Label = 'Grps<=Thr';   Expression = { $_.AssignmentsBelowThreshold } }
$ColFlag       = @{Label = 'Flag';        Expression = { if ($_.LowAllocation) { 'LOW' } else { '' } } }

Write-Host "`nVPP allocation report written to: $OutputPath" -ForegroundColor Green
Write-Host "Evaluated $($report.TotalAppsEvaluated) app(s); $($report.AppsFlaggedLow) flagged (app-wide available <= $LowAllocationThreshold, or at least one smart-group assignment at or below that threshold)." -ForegroundColor Yellow
if ($incomplete.Count -gt 0) {
    Write-Warning "$($incomplete.Count) app(s) had incomplete license-count data from the API (Data unavailable) — confirm field names still match with -DumpRawSample and adjust `$FieldMap.Purchased / `$FieldMap.Redeemed / `$FieldMap.Available if Omnissa has changed the schema."
}
if ($flagged.Count -gt 0) {
    Write-Host "`nFlagged (low availability — app-wide or per-assignment). See README.md 'Field reference' for what each column means:" -ForegroundColor Red
    $flagged | Format-Table $ColApp, $ColPurchased, $ColRedeemed, $ColAvailApp, $ColUnalloc, $ColWorstAvail, $ColGrpsBelow -AutoSize
}

if ($ShowAllInConsole) {
    Write-Host "`nAll evaluated apps (the JSON/XML file always contains all of these regardless of this switch; this just also prints them to the console):" -ForegroundColor Cyan
    $reportItems | Format-Table $ColApp, $ColPurchased, $ColRedeemed, $ColAvailApp, $ColAllocated, $ColUnalloc, $ColWorstAvail, $ColFlag -AutoSize
}
