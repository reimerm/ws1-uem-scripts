<#
    Ws1ApiCore.psm1
    ----------------
    Reusable OAuth + field-resolution helpers shared across the ws1-uem-apis
    scripts in this repo. Extracted from reporting/vpp-license-allocation/
    Get-VppLicenseAllocation.ps1 on 2026-09-28. Nothing in here is specific to
    VPP/MAM — it's generic Workspace ONE UEM REST API plumbing (OAuth token
    acquisition, standard auth headers, and a tolerant property-path resolver
    for WS1's inconsistent PascalCase/snake_case/{Value=X}-wrapped JSON shapes).

    Import from a script with (adjust the relative ../.. to your script's
    actual depth under the repo root):
        Import-Module (Join-Path $PSScriptRoot '..\..\shared\Ws1ApiCore.psm1') -Force
#>

function Get-AccessTokenViaClientCredentials {
    <#
        Confirmed by the Bruno collection's collection-level auth config
        (auth:oauth2, credentials_placement: basic_auth_header): client_id and
        client_secret are sent as an HTTP Basic Authorization header on the
        token request, not as body fields. Only grant_type goes in the body.
        Confirmed 2026-09-28 against a live 2604 tenant.
    #>
    param([string]$TokenUrl, [string]$Id, [string]$Secret)

    Write-Verbose "Requesting OAuth token from $TokenUrl"
    $basicAuthValue = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes("$Id`:$Secret"))
    $tokenHeaders = @{ Authorization = "Basic $basicAuthValue" }
    $body = @{ grant_type = 'client_credentials' }

    try {
        $resp = Invoke-RestMethod -Method Post -Uri $TokenUrl -Headers $tokenHeaders -Body $body `
            -ContentType 'application/x-www-form-urlencoded'
    }
    catch {
        throw "OAuth token request failed: $($_.Exception.Message). Verify -OAuthTokenUrl, -ClientId, -ClientSecret, and that this client is authorized in your environment."
    }

    if (-not $resp.access_token) {
        throw "OAuth token response did not contain an access_token. Data unavailable — response was: $($resp | ConvertTo-Json -Depth 5 -Compress)"
    }
    return $resp.access_token
}

function Get-AuthHeaders {
    <#
        Standard bearer-token header set for WS1 UEM REST API calls.
        -Version selects the Accept header's versioned media type (most MAM
        endpoints default to version=1; pass 2 for endpoints with a V2
        response shape, e.g. GET /mam/apps/purchased/{uuid}).
        Confirmed: this collection uses OAuth only, no aw-tenant-code header.
    #>
    param([string]$Token, [int]$Version = 1)
    return @{
        Authorization = "Bearer $Token"
        Accept        = "application/json;version=$Version"
    }
}

function Get-BasicAuthHeaders {
    <#
        Header set for the legacy Basic-auth mode: an admin username/password
        as "Authorization: Basic base64(user:password)" plus the tenant API key in
        the "aw-tenant-code" header.

        What the published specs confirm (euc-dev/ws1-uem-apis, 2410-2607, every
        mdm/mam/system file): securityDefinitions declares BasicAuth (type basic)
        and ApiKeyAuth (header "aw-tenant-code"), and nearly every operation lists
        both. The Bruno collection describes aw-tenant-code as the legacy API key
        for older header-based authentication. What the specs do NOT spell out is
        whether both must be sent together (Swagger 2.0 lists them as alternatives);
        sending both is the long-standing WS1 convention. Confirm against your own
        tenant's https://<as-host>/api/help page before relying on it.

        Where the tenant code comes from: Groups & Settings > All Settings >
        System > Advanced > API > REST API (API key / tenant code), at Customer OG
        or below. Take care: the tenant code is a credential. Do not log it.

        -Version selects the versioned Accept header, as in Get-AuthHeaders.
    #>
    param(
        [Parameter(Mandatory = $true)][System.Management.Automation.PSCredential]$Credential,
        [Parameter(Mandatory = $true)][string]$TenantCode,
        [int]$Version = 1
    )

    $pair = "{0}:{1}" -f $Credential.UserName, $Credential.GetNetworkCredential().Password
    $basic = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($pair))
    return @{
        Authorization   = "Basic $basic"
        'aw-tenant-code' = $TenantCode
        Accept          = "application/json;version=$Version"
    }
}

function New-Ws1AuthContext {
    <#
        Single entry point every script in this repo should use for authentication,
        so all scripts offer the same modes. Returns a context object to pass to
        Get-Ws1AuthHeaders. Exactly one mode's inputs must be supplied:

          OAuth  -TokenUrl -ClientId -ClientSecret   client_credentials; token is
                                                     fetched now and can be refreshed
          Token  -AccessToken                        pre-acquired bearer token
          Basic  -Credential -TenantCode             admin user/password plus the
                                                     aw-tenant-code API key header

        Per the UEM API Help "Getting Started" page: Basic = Base64 user:password in
        Authorization, and the tenant API key goes in aw-tenant-code. OAuth does not
        need aw-tenant-code and it is never sent for OAuth/Token modes.
        The client secret is held only inside a PSCredential, and the object has no
        secret in plain-text properties, so printing or serialising it does not leak it.
    #>
    param(
        [Parameter(Mandatory = $true)][ValidateSet('OAuth', 'Token', 'Basic')][string]$Mode,
        [string]$TokenUrl,
        [string]$ClientId,
        [string]$ClientSecret,
        [string]$AccessToken,
        [System.Management.Automation.PSCredential]$Credential,
        [string]$TenantCode
    )

    $token = $null
    $oauthClient = $null
    switch ($Mode) {
        'OAuth' {
            if (-not $TokenUrl -or -not $ClientId -or -not $ClientSecret) {
                throw "OAuth mode needs -TokenUrl, -ClientId and -ClientSecret."
            }
            $token = Get-AccessTokenViaClientCredentials -TokenUrl $TokenUrl -Id $ClientId -Secret $ClientSecret
            $oauthClient = New-Object System.Management.Automation.PSCredential($ClientId, (ConvertTo-SecureString $ClientSecret -AsPlainText -Force))
        }
        'Token' {
            if (-not $AccessToken) { throw "Token mode needs -AccessToken." }
            $token = $AccessToken
        }
        'Basic' {
            if ($null -eq $Credential -or -not $TenantCode) {
                throw "Basic mode needs both -Credential and -TenantCode (the aw-tenant-code API key)."
            }
        }
    }

    return [PSCustomObject]@{
        Mode        = $Mode
        Token       = $token
        Credential  = $Credential
        TenantCode  = $TenantCode
        TokenUrl    = $TokenUrl
        OAuthClient = $oauthClient
        CanRefresh  = ($Mode -eq 'OAuth')
    }
}

function Get-Ws1AuthHeaders {
    <#
        Header set for a request under the given auth context (see New-Ws1AuthContext).
        -Version selects the versioned Accept header as in Get-AuthHeaders.
    #>
    param(
        [Parameter(Mandatory = $true)]$Context,
        [int]$Version = 1
    )

    if ($Context.Mode -eq 'Basic') {
        return Get-BasicAuthHeaders -Credential $Context.Credential -TenantCode $Context.TenantCode -Version $Version
    }
    return Get-AuthHeaders -Token $Context.Token -Version $Version
}

function Update-Ws1AuthToken {
    <#
        Fetches a fresh OAuth token for an OAuth context. Returns $true if refreshed,
        $false when the mode cannot refresh (Token, Basic). Basic auth is never
        "retried": repeated failed logins can lock the admin account.
    #>
    param([Parameter(Mandatory = $true)]$Context)

    if (-not $Context.CanRefresh) { return $false }
    $Context.Token = Get-AccessTokenViaClientCredentials -TokenUrl $Context.TokenUrl `
        -Id $Context.OAuthClient.UserName -Secret $Context.OAuthClient.GetNetworkCredential().Password
    return $true
}

function Resolve-Field {
    <#
        Returns the first non-null value found on $Object for any of the
        candidate property paths in $Names, or $null if none are present.
        A name may be a dotted path (e.g. 'ManagedDistribution.Purchased') to
        reach into a nested object; each path segment is resolved in turn and
        the walk is abandoned (falls through to the next candidate) if any
        intermediate segment is missing. Handles WS1's occasional
        { Value = X } wrapper objects (e.g. Id.Value) at the final segment.
    #>
    param($Object, [string[]]$Names)

    foreach ($n in $Names) {
        $current = $Object
        $found = $true
        foreach ($segment in $n -split '\.') {
            if ($null -ne $current -and $current.PSObject.Properties.Name -contains $segment) {
                $current = $current.$segment
            }
            else {
                $found = $false
                break
            }
        }
        if ($found -and $null -ne $current) {
            if ($current.PSObject.Properties.Name -contains 'Value') {
                return $current.Value
            }
            return $current
        }
    }
    return $null
}

function New-Ws1RateLimiter {
    <#
        Creates the state object used by Invoke-Ws1Request to pace calls.
        This is a client-side politeness control, NOT a documented server limit:
        Omnissa's published specs list HTTP 429 on some endpoints but publish no
        per-tenant request budget for the MDM command endpoints, so the defaults
        below are conservative assumptions (see DESIGN.md of the consuming script).

          -RequestsPerSecond   steady-state ceiling (min spacing = 1000/rps ms)
          -MaxRetries          retries per request after the first attempt
          -BaseBackoffSeconds  first backoff when the server gives no Retry-After;
                               doubles each attempt (plus up to 1s jitter)
          -MaxBackoffSeconds   cap for a single backoff wait
          -MaxRetryAfterSeconds  if the server's Retry-After on a 429/503 exceeds this,
                               stop retrying at once (RetryAfterExceeded = $true) so
                               the caller can abort safely. Default 300.
          -MaxSlowdownFactor   how far adaptive slowdown may stretch the spacing
                               after 429/503 responses (8 => at most 8x slower)
    #>
    param(
        [double]$RequestsPerSecond = 2,
        [int]$MaxRetries = 5,
        [double]$BaseBackoffSeconds = 2,
        [double]$MaxBackoffSeconds = 120,
        [double]$MaxSlowdownFactor = 8,
        [double]$MaxRetryAfterSeconds = 300
    )

    if ($RequestsPerSecond -le 0) { throw "RequestsPerSecond must be greater than 0." }
    $minMs = 1000.0 / $RequestsPerSecond

    return [PSCustomObject]@{
        MinIntervalMs      = $minMs
        CurrentIntervalMs  = $minMs
        MaxIntervalMs      = $minMs * [math]::Max(1.0, $MaxSlowdownFactor)
        MaxRetries         = $MaxRetries
        BaseBackoffSeconds = $BaseBackoffSeconds
        MaxBackoffSeconds  = $MaxBackoffSeconds
        MaxRetryAfterSeconds = $MaxRetryAfterSeconds
        NextAllowedUtc     = [DateTime]::UtcNow
        SuccessStreak      = 0
        TotalRequests      = 0
        ThrottleEvents     = 0
        Retries            = 0
        TotalWaitSeconds   = 0.0
        QuotaLimit         = $null
        QuotaRemaining     = $null
        QuotaResetUtc      = $null
    }
}

function Wait-Ws1RateLimit {
    <#
        Blocks until the limiter's next slot is free, then reserves the slot
        after that one (now + CurrentIntervalMs). Sequential callers only.
    #>
    param($Limiter)

    $now = [DateTime]::UtcNow
    if ($Limiter.NextAllowedUtc -gt $now) {
        $ms = ($Limiter.NextAllowedUtc - $now).TotalMilliseconds
        Start-Sleep -Milliseconds ([int][math]::Ceiling($ms))
        $Limiter.TotalWaitSeconds += ($ms / 1000.0)
    }
    $Limiter.NextAllowedUtc = [DateTime]::UtcNow.AddMilliseconds($Limiter.CurrentIntervalMs)
}

function Get-Ws1HeaderValue {
    <#
        Reads one header value (first value if several) from any header container
        the two PowerShell editions hand back: WebHeaderCollection and
        Dictionary<string,string> (Windows PowerShell 5.1), Dictionary<string,string[]>
        from Invoke-WebRequest and HttpResponseHeaders from an HTTP error (PowerShell 7).
        Returns $null when the header is absent.
    #>
    param($Headers, [string]$Name)

    if ($null -eq $Headers) { return $null }
    try {
        if ($Headers.PSObject.Methods.Name -contains 'TryGetValues') {
            $vals = $null
            if ($Headers.TryGetValues($Name, [ref]$vals)) { return [string]($vals | Select-Object -First 1) }
            return $null
        }
        $v = $Headers[$Name]
        if ($null -eq $v) { return $null }
        return [string]($v | Select-Object -First 1)
    }
    catch { return $null }
}

function Update-Ws1RateLimitState {
    <#
        Records the UEM x-ratelimit-* headers from a response onto the limiter
        (QuotaLimit, QuotaRemaining, QuotaResetUtc).
        The Workspace ONE UEM API Help "Getting Started" page documents them as the
        24-hour quota:
          x-ratelimit-limit      calls allowed in the window
          x-ratelimit-remaining  calls left in the window
          x-ratelimit-reset      epoch time when the window resets
        BUT a real tenant returned ~5000 that behaves like a much shorter window
        (reported by the user, 2026-09-30; reset interval not measured here). So
        callers must NOT assume 24 h; use QuotaResetUtc to decide how long to wait.
        The same page says limiting is per Organization Group, keyed on the API key
        used, and that there is also a per-minute "Server Throttling" limit whose
        value is NOT exposed in these headers.
    #>
    param($Limiter, $Headers)

    if ($null -eq $Limiter -or $null -eq $Headers) { return }
    $n = 0L
    $v = Get-Ws1HeaderValue -Headers $Headers -Name 'x-ratelimit-limit'
    if ($v -and [long]::TryParse($v, [ref]$n)) { $Limiter.QuotaLimit = $n }
    $v = Get-Ws1HeaderValue -Headers $Headers -Name 'x-ratelimit-remaining'
    if ($v -and [long]::TryParse($v, [ref]$n)) { $Limiter.QuotaRemaining = $n }
    $v = Get-Ws1HeaderValue -Headers $Headers -Name 'x-ratelimit-reset'
    if ($v -and [long]::TryParse($v, [ref]$n)) {
        try {
            # Documented example is epoch seconds; tolerate milliseconds.
            if ($n -gt 100000000000) { $n = [long]($n / 1000) }
            $Limiter.QuotaResetUtc = [DateTimeOffset]::FromUnixTimeSeconds($n).UtcDateTime
        }
        catch { }
    }
}

function Get-Ws1RetryAfterSeconds {
    <#
        Reads a Retry-After header (delta-seconds or HTTP-date) from a failed
        response. Works for Windows PowerShell 5.1 (WebHeaderCollection) and
        PowerShell 7 (HttpResponseHeaders). Returns $null when absent/unparseable.
    #>
    param($Response)

    if ($null -eq $Response) { return $null }
    $raw = Get-Ws1HeaderValue -Headers $Response.Headers -Name 'Retry-After'
    if (-not $raw) { return $null }
    $secs = 0.0
    if ([double]::TryParse([string]$raw, [ref]$secs)) { return [math]::Max(0.0, $secs) }
    $dt = [DateTime]::MinValue
    if ([DateTime]::TryParse([string]$raw, [ref]$dt)) {
        return [math]::Max(0.0, ($dt.ToUniversalTime() - [DateTime]::UtcNow).TotalSeconds)
    }
    return $null
}

function Invoke-Ws1Request {
    <#
        One HTTP call to the UEM REST API with client-side pacing and retry.

        - Every attempt waits for the limiter (if -Limiter is given).
        - 429 is treated as throttling and always retried: honour Retry-After when
          the server sends it, otherwise exponential backoff + jitter; the limiter's
          spacing is doubled (up to MaxIntervalMs) and eases back down after 20
          consecutive successes.
        - 503 is retried the same way ONLY with -RetryOnServerError (it may have
          been processed). Without it, a 503 is returned immediately.
        - If a 429/503 carries a Retry-After above the limiter's MaxRetryAfterSeconds,
          no retry is made; the result has RetryAfterExceeded = $true and
          RetryAfterSeconds set, so the caller can stop safely.
        - 500/502/504 and connection-level failures (no HTTP status) are retried
          only when -RetryOnServerError is set. Leave it off for non-idempotent
          or disruptive POSTs: a 500 may still have queued the command.
        - 401 and other 4xx are returned immediately, never retried, so the
          caller can refresh a token or record the failure.

        Never throws for HTTP/network errors; returns an object:
          Success, StatusCode, Data (parsed JSON or $null), Content (raw string),
          Error (message, truncated), Attempts, Throttled, RetryAfterSeconds,
          RetryAfterExceeded
    #>
    param(
        [Parameter(Mandatory = $true)][ValidateSet('GET', 'POST', 'PUT', 'PATCH', 'DELETE')][string]$Method,
        [Parameter(Mandatory = $true)][string]$Uri,
        [Parameter(Mandatory = $true)][hashtable]$Headers,
        $Body = $null,
        [string]$ContentType = 'application/json',
        $Limiter = $null,
        [switch]$RetryOnServerError,
        [scriptblock]$OnRetry = $null
    )

    $maxRetries = if ($Limiter) { [int]$Limiter.MaxRetries } else { 0 }
    $attempt = 0
    $everThrottled = $false

    while ($true) {
        $attempt++
        if ($Limiter) {
            Wait-Ws1RateLimit -Limiter $Limiter
            $Limiter.TotalRequests++
        }

        $status = $null
        $content = $null
        $errMsg = $null
        $retryAfter = $null
        $ok = $false

        try {
            $iwrParams = @{
                Method          = $Method
                Uri             = $Uri
                Headers         = $Headers
                UseBasicParsing = $true
                ErrorAction     = 'Stop'
            }
            if ($null -ne $Body) {
                $iwrParams['Body'] = $Body
                $iwrParams['ContentType'] = $ContentType
            }
            elseif ($Method -in @('POST', 'PUT', 'PATCH')) {
                $iwrParams['Body'] = ''
                $iwrParams['ContentType'] = $ContentType
            }
            $resp = Invoke-WebRequest @iwrParams
            $status = [int]$resp.StatusCode
            $content = $resp.Content
            $ok = $true
            Update-Ws1RateLimitState -Limiter $Limiter -Headers $resp.Headers
        }
        catch {
            $ex = $_.Exception
            $r = $null
            if ($ex.PSObject.Properties.Name -contains 'Response') { $r = $ex.Response }
            if ($null -ne $r) {
                try { $status = [int]$r.StatusCode } catch { $status = $null }
                $retryAfter = Get-Ws1RetryAfterSeconds -Response $r
                Update-Ws1RateLimitState -Limiter $Limiter -Headers $r.Headers
            }
            if ($_.ErrorDetails -and $_.ErrorDetails.Message) {
                $errMsg = $_.ErrorDetails.Message
            }
            elseif ($null -ne $r -and $r.PSObject.Methods.Name -contains 'GetResponseStream') {
                try {
                    $sr = New-Object System.IO.StreamReader($r.GetResponseStream())
                    $errMsg = $sr.ReadToEnd()
                    $sr.Close()
                }
                catch { $errMsg = $null }
            }
            if (-not $errMsg) { $errMsg = $ex.Message }
        }

        if ($ok) {
            if ($Limiter) {
                $Limiter.SuccessStreak++
                if ($Limiter.SuccessStreak -ge 20 -and $Limiter.CurrentIntervalMs -gt $Limiter.MinIntervalMs) {
                    $Limiter.CurrentIntervalMs = [math]::Max($Limiter.MinIntervalMs, $Limiter.CurrentIntervalMs * 0.8)
                    $Limiter.SuccessStreak = 0
                }
            }
            $data = $null
            if ($content -is [string] -and $content.Trim().Length -gt 0 -and $content.TrimStart()[0] -in @('{', '[')) {
                try { $data = $content | ConvertFrom-Json } catch { $data = $null }
            }
            return [PSCustomObject]@{
                Success = $true; StatusCode = $status; Data = $data; Content = $content
                Error = $null; Attempts = $attempt; Throttled = $everThrottled
                RetryAfterSeconds = $null; RetryAfterExceeded = $false
            }
        }

        # 429 = "slow down", the request was not processed: always safe to retry.
        # 503 = "unavailable": may or may not have been processed, so it is retried only
        # when the caller says repeating the call is safe (-RetryOnServerError).
        $is429 = ($status -eq 429)
        $is503 = ($status -eq 503)
        $isThrottleStatus = ($is429 -or $is503)
        $isThrottle = ($is429 -or ($is503 -and $RetryOnServerError))
        $isTransient = ($null -eq $status) -or ($status -eq 500) -or ($status -eq 502) -or ($status -eq 504)
        $canRetry = ($attempt -le $maxRetries) -and ($isThrottle -or ($isTransient -and $RetryOnServerError))

        # The server asked for a wait longer than we are willing to sit through: stop
        # now so the caller can abort safely instead of hammering or stalling.
        $retryAfterExceeded = $false
        if ($isThrottleStatus -and $null -ne $retryAfter -and $Limiter -and $retryAfter -gt $Limiter.MaxRetryAfterSeconds) {
            $retryAfterExceeded = $true
            $canRetry = $false
            $Limiter.ThrottleEvents++
        }

        if (-not $canRetry) {
            if ($errMsg -and $errMsg.Length -gt 500) { $errMsg = $errMsg.Substring(0, 500) }
            return [PSCustomObject]@{
                Success = $false; StatusCode = $status; Data = $null; Content = $null
                Error = $errMsg; Attempts = $attempt; Throttled = ($everThrottled -or $isThrottleStatus)
                RetryAfterSeconds = $retryAfter; RetryAfterExceeded = $retryAfterExceeded
            }
        }

        $Limiter.Retries++
        $wait = $null
        if ($null -ne $retryAfter) { $wait = [math]::Min($Limiter.MaxBackoffSeconds, $retryAfter) }
        else {
            $wait = [math]::Min($Limiter.MaxBackoffSeconds, $Limiter.BaseBackoffSeconds * [math]::Pow(2, $attempt - 1))
            $wait += (Get-Random -Minimum 0.0 -Maximum 1.0)
        }
        if ($isThrottle) {
            $everThrottled = $true
            $Limiter.ThrottleEvents++
            $Limiter.SuccessStreak = 0
            $Limiter.CurrentIntervalMs = [math]::Min($Limiter.MaxIntervalMs, $Limiter.CurrentIntervalMs * 2)
        }
        # Push the limiter's next slot out so every following call also honours the wait.
        $Limiter.NextAllowedUtc = [DateTime]::UtcNow.AddSeconds($wait)
        if ($OnRetry) { & $OnRetry $attempt $status $wait }
    }
}

Export-ModuleMember -Function Get-AccessTokenViaClientCredentials, Get-AuthHeaders, Get-BasicAuthHeaders, New-Ws1AuthContext, Get-Ws1AuthHeaders, Update-Ws1AuthToken, Resolve-Field, New-Ws1RateLimiter, Wait-Ws1RateLimit, Get-Ws1HeaderValue, Update-Ws1RateLimitState, Get-Ws1RetryAfterSeconds, Invoke-Ws1Request
