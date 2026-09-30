<#
.SYNOPSIS
    Offline tests for shared/Ws1ApiCore.psm1, Invoke-SmartGroupDeviceCommand.ps1 and
    Get-VppLicenseAllocation.ps1 against tests/mock-uem/mock_uem_server.py.

.DESCRIPTION
    Run through run_tests.sh (starts the HTTPS mock, trusts its cert, runs this).
    The mock is NOT real UEM: throttling status codes/headers are scripted by these
    tests because Omnissa does not document them. Passing here means the code does
    what its design says, not that a tenant behaves this way.
#>
param(
    [string]$Mock = 'https://localhost:8443',
    [string]$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path,
    [string]$Pwsh = (Get-Process -Id $PID).Path
)

$ErrorActionPreference = 'Stop'
$script:pass = 0; $script:fail = 0
Import-Module (Join-Path $RepoRoot 'shared/Ws1ApiCore.psm1') -Force

function Ctl { param($Body) Invoke-RestMethod -Method Post -Uri "$Mock/__control" -Body ($Body | ConvertTo-Json -Depth 6) -ContentType 'application/json' | Out-Null }
# Pipe through ForEach-Object so a JSON array is enumerated the same on every PowerShell version.
function GetLog { @(Invoke-RestMethod -Uri "$Mock/__log" | ForEach-Object { $_ }) }
function Check { param([string]$Name, [bool]$Cond, $Detail = '')
    if ($Cond) { $script:pass++; Write-Host "  PASS  $Name" -ForegroundColor Green }
    else { $script:fail++; Write-Host "  FAIL  $Name  $Detail" -ForegroundColor Red
           if ($env:TEST_VERBOSE -and $script:lastOutput) { Write-Host ($script:lastOutput.Substring(0, [Math]::Min(1500, $script:lastOutput.Length))) -ForegroundColor DarkGray } } }

$hostPort = ($Mock -replace '^https://', '')
$scriptSg = Join-Path $RepoRoot 'remediation/smartgroup-device-commands/Invoke-SmartGroupDeviceCommand.ps1'
$scriptVpp = Join-Path $RepoRoot 'reporting/vpp-license-allocation/Get-VppLicenseAllocation.ps1'
$out = Join-Path ([IO.Path]::GetTempPath()) ('ws1tests_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $out | Out-Null

function Run-Script {
    # Runs a script in a child pwsh so param binding, Read-Host and exit paths are real.
    param([string]$Script, [string]$ArgString, [string]$Stdin = '')
    $cmd = "`$cred = New-Object System.Management.Automation.PSCredential('apiuser',(ConvertTo-SecureString 'apipass' -AsPlainText -Force)); " +
           "`$bad = New-Object System.Management.Automation.PSCredential('apiuser',(ConvertTo-SecureString 'WRONG' -AsPlainText -Force)); " +
           "& '$Script' $ArgString"
    # No -NonInteractive: Read-Host must be able to read the piped confirmation. (With
    # -NonInteractive the script correctly refuses to send anything; see test S2c.)
    $text = ($Stdin | & $Pwsh -NoProfile -Command $cmd 2>&1 | Out-String)
    $script:lastOutput = $text
    return $text
}
$oauth = "-ApiUrl $hostPort -OAuthTokenUrl $Mock/connect/token -ClientId cid -ClientSecret csecret"
$basic = "-ApiUrl $hostPort -Credential `$cred -TenantCode TENANT123"
$common = "-UemVersion 2604 -OutputDirectory '$out' -BatchPauseSeconds 0 -RequestsPerSecond 50"

Write-Host "`n== 1. Shared module ==" -ForegroundColor Cyan
Ctl @{ reset = $true }
$lim = New-Ws1RateLimiter -RequestsPerSecond 50 -MaxRetries 3 -BaseBackoffSeconds 0.1
$auth = New-Ws1AuthContext -Mode OAuth -TokenUrl "$Mock/connect/token" -ClientId cid -ClientSecret csecret
Check 'OAuth context gets a token via Basic client auth' ($auth.Token -eq 'tok123')
Check 'OAuth context holds no plain-text secret property' (-not ($auth | ConvertTo-Json -Depth 3 | Select-String 'csecret'))
$h = Get-Ws1AuthHeaders -Context $auth -Version 2
Check 'OAuth headers: Bearer + versioned Accept, no tenant code' ($h.Authorization -eq 'Bearer tok123' -and $h.Accept -eq 'application/json;version=2' -and -not $h.ContainsKey('aw-tenant-code'))
$cred = New-Object System.Management.Automation.PSCredential('apiuser', (ConvertTo-SecureString 'apipass' -AsPlainText -Force))
$bauth = New-Ws1AuthContext -Mode Basic -Credential $cred -TenantCode TENANT123
$bh = Get-Ws1AuthHeaders -Context $bauth
Check 'Basic headers: Basic base64(user:pass) + aw-tenant-code' ($bh.Authorization -eq ('Basic ' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('apiuser:apipass'))) -and $bh['aw-tenant-code'] -eq 'TENANT123')
Check 'Basic context cannot refresh (no retry on 401)' ((Update-Ws1AuthToken -Context $bauth) -eq $false)
$threw = $false; try { New-Ws1AuthContext -Mode Basic -Credential $cred } catch { $threw = $true }
Check 'Basic mode without TenantCode is rejected' $threw

$r = Invoke-Ws1Request -Method GET -Uri "$Mock/api/mdm/smartgroups/42" -Headers $h -Limiter $lim
Check 'GET 200 succeeds and parses JSON' ($r.Success -and $r.Data.SmartGroupID -eq 42)
Check 'x-ratelimit-* headers captured' ($lim.QuotaLimit -eq 5000 -and $lim.QuotaRemaining -gt 0 -and $lim.QuotaResetUtc -gt [DateTime]::UtcNow)
$r = Invoke-Ws1Request -Method GET -Uri "$Mock/api/mdm/smartgroups/42" -Headers @{ Authorization = 'Bearer nope'; Accept = 'application/json' } -Limiter $lim
Check '401 returned, not retried, no throw' ((-not $r.Success) -and $r.StatusCode -eq 401 -and $r.Attempts -eq 1)

Ctl @{ command_script = @(@{ status = 429; retry_after = 0 }, 202) }
$lim = New-Ws1RateLimiter -RequestsPerSecond 50 -MaxRetries 3 -BaseBackoffSeconds 0.1
$r = Invoke-Ws1Request -Method POST -Uri "$Mock/api/mdm/devices/1/commands?command=DeviceQuery" -Headers $h -Limiter $lim
Check '429 (Retry-After 0) is retried then succeeds' ($r.Success -and $r.Attempts -eq 2 -and $lim.ThrottleEvents -eq 1)
Check 'limiter slowed after 429' ($lim.CurrentIntervalMs -gt $lim.MinIntervalMs)

Ctl @{ command_script = @(503, 202) }
$r = Invoke-Ws1Request -Method POST -Uri "$Mock/api/mdm/devices/1/commands?command=Lock" -Headers $h -Limiter $lim
Check '503 without -RetryOnServerError is NOT retried' ((-not $r.Success) -and $r.StatusCode -eq 503 -and $r.Attempts -eq 1)
Ctl @{ command_script = @(503, 202) }
$r = Invoke-Ws1Request -Method POST -Uri "$Mock/api/mdm/devices/1/commands?command=DeviceQuery" -Headers $h -Limiter $lim -RetryOnServerError
Check '503 with -RetryOnServerError is retried' ($r.Success -and $r.Attempts -eq 2)

Ctl @{ command_script = @(@{ status = 429; retry_after = 900 }, 202) }
$r = Invoke-Ws1Request -Method POST -Uri "$Mock/api/mdm/devices/1/commands?command=DeviceQuery" -Headers $h -Limiter $lim
Check 'Retry-After above limit -> no retry, RetryAfterExceeded' ((-not $r.Success) -and $r.RetryAfterExceeded -and $r.RetryAfterSeconds -eq 900 -and $r.Attempts -eq 1)
Ctl @{ reset = $true }

Ctl @{ command_script = @(429, 429, 429, 429, 429) }
$lim = New-Ws1RateLimiter -RequestsPerSecond 50 -MaxRetries 2 -BaseBackoffSeconds 0.05
$r = Invoke-Ws1Request -Method POST -Uri "$Mock/api/mdm/devices/1/commands?command=DeviceQuery" -Headers $h -Limiter $lim
Check 'Persistent 429 gives up after MaxRetries (3 attempts)' ((-not $r.Success) -and $r.Attempts -eq 3 -and $r.Throttled)
Ctl @{ reset = $true }

Write-Host "`n== 2. Invoke-SmartGroupDeviceCommand.ps1 ==" -ForegroundColor Cyan

Ctl @{ reset = $true }
$t = Run-Script $scriptSg "$oauth $common -SmartGroup 42 -Platform Apple -Command DeviceQuery"
$log = GetLog; $posts = @($log | Where-Object { $_.command })
Check 'S1 dry run sends no commands' ($posts.Count -eq 0 -and $t -match 'DRY RUN')
Check 'S1 plan shows 12 Apple devices and quota window' ($t -match 'Devices to send  : 12' -and $t -match 'API quota window')

Ctl @{ reset = $true }
$t = Run-Script $scriptSg "$oauth $common -SmartGroup 42 -Platform Apple -Command DeviceQuery -Execute -BatchSize 5" 'YES'
$posts = @(GetLog | Where-Object { $_.command })
Check 'S2 OAuth execute sends 12 commands, Apple only' ($posts.Count -eq 12 -and -not ($posts | Where-Object { [int]$_.device -ge 2000 }))
Check 'S2 uses Bearer, no tenant header, version=1 Accept' (-not ($posts | Where-Object { $_.auth -ne 'bearer' -or $_.tenant_header -or $_.accept -ne 'application/json;version=1' }))
Check 'S2 summary + result files written' ($t -match 'Accepted\s*:\s*12' -and (Get-ChildItem $out -Filter 'SmartGroupCommand_42_Apple_DeviceQuery_*.csv').Count -ge 1)
$resJson = Get-ChildItem $out -Filter 'SmartGroupCommand_42_Apple_DeviceQuery_*.json' | Sort-Object LastWriteTime | Select-Object -Last 1
$res = Get-Content $resJson.FullName -Raw | ConvertFrom-Json
Check 'S2 results JSON records AuthMode=OAuth and quota, no secrets' ($res.AuthMode -eq 'OAuth' -and $res.RateLimiter.QuotaLimit -eq 5000 -and -not ((Get-Content $resJson.FullName -Raw) -match 'csecret|tok123|apipass|TENANT123'))
Check 'S2 device names redacted by default' (-not ((Get-Content $resJson.FullName -Raw) -match 'dev-\d'))

Ctl @{ reset = $true }
$t = Run-Script $scriptSg "$oauth $common -SmartGroup 42 -Platform Apple -Command DeviceQuery -Execute" 'no'
$posts = @(GetLog | Where-Object { $_.command })
Check 'S2b wrong confirmation sends nothing' ($posts.Count -eq 0 -and $t -match 'Aborted')

Ctl @{ reset = $true }
$cmd = "& '$scriptSg' $oauth $common -SmartGroup 42 -Platform Apple -Command DeviceQuery -Execute"
$t = ('YES' | & $Pwsh -NoProfile -NonInteractive -Command $cmd 2>&1 | Out-String)
Check 'S2c non-interactive session cannot send (no confirmation possible)' (@(GetLog | Where-Object { $_.command }).Count -eq 0 -and $t -match 'refusing to send')

Ctl @{ reset = $true }
$t = Run-Script $scriptSg "$basic $common -SmartGroup 42 -Platform Apple -Command SyncDevice -Execute -SkipCanary" 'YES'
$log = GetLog; $posts = @($log | Where-Object { $_.command })
Check 'S3 Basic execute sends 12 commands with Basic + aw-tenant-code' ($posts.Count -eq 12 -and -not ($posts | Where-Object { $_.auth -ne 'basic' -or -not $_.tenant_header -or -not $_.auth_ok }))
Check 'S3 Basic run makes no token request' (-not ($log | Where-Object { $_.path -eq '/connect/token' }))

Ctl @{ reset = $true }
$t = Run-Script $scriptSg "-ApiUrl $hostPort -Credential `$bad -TenantCode TENANT123 $common -SmartGroup 42 -Platform Apple -Command DeviceQuery -Execute" 'YES'
$log = GetLog
Check 'S3b Basic wrong password: exactly ONE request, not retried' ($log.Count -eq 1 -and $log[0].status -eq 401 -and $t -match 'Not retrying')

Ctl @{ reset = $true }
$t = Run-Script $scriptSg "$basic $common -SmartGroup $('59720b59-88e5-4ea8-b6d7-66d6b5fe1614') -Platform Android -Command DeviceQuery -Execute" 'YES'
$posts = @(GetLog | Where-Object { $_.command })
Check 'S4 UUID lookup + Android filter -> 3 devices' ($posts.Count -eq 3 -and -not ($posts | Where-Object { [int]$_.device -lt 2000 }))
Ctl @{ reset = $true; search_ignores_page = $true }
$t = Run-Script $scriptSg "$oauth $common -SmartGroup 59720b59-88e5-4ea8-b6d7-66d6b5fe1614 -Platform Apple -Command List"
Check 'S4b UUID lookup terminates when paging is 1-based/ignored' ($t -match 'Member list written')
Ctl @{ reset = $true }
$t = Run-Script $scriptSg "$oauth $common -SmartGroup 42 -Platform AppleOsX -Command DeviceQuery"
Check 'S5 platform with no members is refused, lists platforms seen' ($t -match 'No members matched' -and $t -match 'Android')
$t = Run-Script $scriptSg "$oauth $common -SmartGroup 42 -Platform Android -Command SyncSensors"
Check 'S5b command not valid for platform is refused' ($t -match 'AppleOsX only')
$t = Run-Script $scriptSg "$oauth $common -SmartGroup 42 -Platform Apple -Command DeviceWipe -Execute" 'YES'
Check 'S5c disruptive command without -AllowDisruptive is refused' ($t -match 'disruptive' -and (@(GetLog | Where-Object { $_.command }).Count -eq 0))

# Wipe-class hardening: -AllowWipe, no -SkipCanary, banner, two typed confirmations.
Ctl @{ reset = $true }
$t = Run-Script $scriptSg "$oauth $common -SmartGroup 42 -Platform Android -Command EnterpriseWipe -Execute -AllowDisruptive" 'YES'
Check 'S5d wipe without -AllowWipe is refused, nothing sent' ($t -match 'AllowWipe' -and (@(GetLog | Where-Object { $_.command }).Count -eq 0))
$t = Run-Script $scriptSg "$oauth $common -SmartGroup 42 -Platform Android -Command EnterpriseWipe -Execute -AllowDisruptive -AllowWipe -SkipCanary" 'x'
Check 'S5e wipe with -SkipCanary is refused, nothing sent' ($t -match 'SkipCanary is not allowed' -and (@(GetLog | Where-Object { $_.command }).Count -eq 0))
$t = Run-Script $scriptSg "$oauth $common -SmartGroup 42 -Platform Android -Command EnterpriseWipe -Execute -AllowDisruptive -AllowWipe" "EXECUTE EnterpriseWipe 3`n42"
Check 'S5f wipe: the ordinary disruptive phrase is NOT enough (warning shown, nothing sent)' ($t -match 'DESTRUCTIVE ACTION' -and $t -match 'NOT an Omnissa product' -and $t -match 'Aborted' -and (@(GetLog | Where-Object { $_.command }).Count -eq 0))
$t = Run-Script $scriptSg "$oauth $common -SmartGroup 42 -Platform Android -Command EnterpriseWipe -Execute -AllowDisruptive -AllowWipe" "WIPE EnterpriseWipe 3`n99"
Check 'S5g wipe: right phrase but wrong smart group ID -> aborted, nothing sent' ($t -match 'Confirmation 2 of 2' -and $t -match 'Aborted' -and (@(GetLog | Where-Object { $_.command }).Count -eq 0))
$t = Run-Script $scriptSg "$oauth $common -SmartGroup 42 -Platform Android -Command EnterpriseWipe -Execute -AllowDisruptive -AllowWipe" "WIPE EnterpriseWipe 3`n42"
$posts = @(GetLog | Where-Object { $_.command })
Check 'S5h wipe: both confirmations correct -> sent to the 3 Android devices only (canary first)' ($posts.Count -eq 3 -and -not ($posts | Where-Object { [int]$_.device -lt 2000 }) -and $posts[0].command -eq 'EnterpriseWipe')

Write-Host "`n-- 429/503 safe abort --" -ForegroundColor Cyan
Ctl @{ reset = $true; command_script = @(202) + (1..6 | ForEach-Object { @{ status = 429; retry_after = 0 } }) }
$t = Run-Script $scriptSg "$oauth $common -SmartGroup 42 -Platform Apple -Command DeviceQuery -Execute -MaxRetries 1" 'YES'
$posts = @(GetLog | Where-Object { $_.command })
Check 'S6 three devices in a row 429 after retries -> stop (1 ok + 3x2 attempts = 7 POSTs)' ($posts.Count -eq 7 -and $t -match 'in a row' -and $t -match 'RUN STOPPED EARLY')
Ctl @{ command_script = @() }
$t = Run-Script $scriptSg "$oauth $common -SmartGroup 42 -Platform Apple -Command DeviceQuery -Execute -Resume" 'YES'
$posts2 = @(GetLog | Where-Object { $_.command }) | Select-Object -Skip 7
Check 'S6b -Resume sends only devices not yet accepted (11, canary device skipped)' ($posts2.Count -eq 11 -and -not ($posts2 | Where-Object { $_.device -eq '1001' }))

Ctl @{ reset = $true; command_script = @(202, @{ status = 429; retry_after = 900 }) }
$t = Run-Script $scriptSg "$oauth $common -SmartGroup 42 -Platform Apple -Command DeviceQuery -Execute" 'YES'
$posts = @(GetLog | Where-Object { $_.command })
Check 'S7 huge Retry-After -> stop at once, no waiting/retry (2 POSTs)' ($posts.Count -eq 2 -and $t -match 'Retry-After is longer')

Ctl @{ reset = $true; command_script = @(503) }
$t = Run-Script $scriptSg "$oauth $common -SmartGroup 42 -Platform Apple -Command Lock -Execute -AllowDisruptive -SkipCanary" 'EXECUTE Lock 12'
$posts = @(GetLog | Where-Object { $_.command })
Check 'S8 503 on disruptive command -> 1 POST, not retried, stops' ($posts.Count -eq 1 -and $t -match 'check that device')

Ctl @{ reset = $true; command_script = @(503, 202) }
$t = Run-Script $scriptSg "$oauth $common -SmartGroup 42 -Platform Apple -Command DeviceQuery -Execute -SkipCanary -BatchSize 20" 'YES'
$posts = @(GetLog | Where-Object { $_.command })
Check 'S9 503 on standard command IS retried and run completes (13 POSTs)' ($posts.Count -eq 13 -and $t -match 'Accepted\s*:\s*12')

Ctl @{ reset = $true; command_script = @(401) }
$t = Run-Script $scriptSg "$oauth $common -SmartGroup 42 -Platform Apple -Command DeviceQuery -Execute -SkipCanary" 'YES'
$log = GetLog
Check 'S10 OAuth 401 mid-run: token re-requested once, command retried' (@($log | Where-Object { $_.path -eq '/connect/token' }).Count -eq 2 -and $t -match 'Accepted\s*:\s*12')

Write-Host "`n-- quota --" -ForegroundColor Cyan
Ctl @{ reset = $true; quota_limit = 5000; quota_remaining = 150 }
$t = Run-Script $scriptSg "$oauth $common -SmartGroup 42 -Platform Apple -Command DeviceQuery -Execute -QuotaReserve 200 -MaxQuotaWaitMinutes 0" 'YES'
Check 'S11 remaining below reserve and reset far away -> refused before sending' ($t -match 'API quota too low' -and (@(GetLog | Where-Object { $_.command }).Count -eq 0))
Ctl @{ reset = $true; quota_limit = 5000; quota_remaining = 205; quota_reset = ([DateTimeOffset]::UtcNow.ToUnixTimeSeconds() + 20) }  # 2 lookups + a few sends cross the 200 reserve
$t = Run-Script $scriptSg "$oauth $common -SmartGroup 42 -Platform Apple -Command DeviceQuery -Execute -QuotaReserve 200 -MaxQuotaWaitMinutes 5 -SkipCanary" 'YES'
Check 'S12 near reset: pauses at reserve, waits for reset, finishes all 12' ($t -match 'Pausing' -and $t -match 'Accepted\s*:\s*12')
Ctl @{ reset = $true; quota_limit = 100 }
$t = Run-Script $scriptSg "$oauth $common -SmartGroup 42 -Platform Apple -Command DeviceQuery -Execute -QuotaReserve 200" 'YES'
Check 'S13 limit not above reserve -> clear error' ($t -match 'could never proceed')

Write-Host "`n== 3. Get-VppLicenseAllocation.ps1 (uniform auth) ==" -ForegroundColor Cyan
Ctl @{ reset = $true }
$t = Run-Script $scriptVpp "$oauth -OutputPath '$out/vpp_oauth.json' -SkipDetailLookup"
$log = GetLog
Check 'V1 OAuth mode writes a report using Bearer, no tenant header' ((Test-Path "$out/vpp_oauth.json") -and -not ($log | Where-Object { $_.path -like '*purchased*' -and ($_.auth -ne 'bearer' -or $_.tenant_header) }))
Ctl @{ reset = $true }
$t = Run-Script $scriptVpp "$basic -OutputPath '$out/vpp_basic.json' -SkipDetailLookup"
$log = GetLog
Check 'V2 Basic mode writes a report using Basic + aw-tenant-code' ((Test-Path "$out/vpp_basic.json") -and -not ($log | Where-Object { $_.path -like '*purchased*' -and ($_.auth -ne 'basic' -or -not $_.tenant_header -or -not $_.auth_ok) }))
$rep = Get-Content "$out/vpp_basic.json" -Raw | ConvertFrom-Json
Check 'V3 report content correct (2 apps, App Flex flagged low)' ($rep.TotalAppsEvaluated -eq 2 -and (@($rep.Apps | Where-Object LowAllocation).ApplicationName -contains 'App Flex'))
Ctl @{ reset = $true }
$t = Run-Script $scriptVpp "$basic -OutputPath '$out/vpp_detail.json' -IncludeAllocationDetail"
$log = GetLog
Check 'V4 V2 detail lookup sends Accept version=2 with Basic auth' ((@($log | Where-Object { $_.path -like '*purchased/*' -and $_.accept -eq 'application/json;version=2' -and $_.auth -eq 'basic' })).Count -ge 1)

Write-Host ("`nRESULT: {0} passed, {1} failed" -f $script:pass, $script:fail) -ForegroundColor $(if ($script:fail) { 'Red' } else { 'Green' })
Remove-Item $out -Recurse -Force -ErrorAction SilentlyContinue
exit $script:fail
