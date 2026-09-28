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

Export-ModuleMember -Function Get-AccessTokenViaClientCredentials, Get-AuthHeaders, Resolve-Field
