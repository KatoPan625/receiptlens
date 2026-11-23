# Week 3 evidence: WAF, rate limiting, load balancing across replicas, failover, metrics.
# Usage: powershell -File scripts/verify-week3.ps1   (stack must be running: docker compose up -d)
# Load test and autoscaling evidence come from k6 + autoscaler/autoscale.py (see docs/SETUP.md).
$ErrorActionPreference = 'Continue'
$root = Split-Path $PSScriptRoot -Parent
Set-Location $root
$fail = 0
function Check([string]$name, [bool]$ok) {
    "{0,-64} {1}" -f $name, $(if ($ok) { 'PASS' } else { 'FAIL' })
    if (-not $ok) { $script:fail++ }
}
$ca = Join-Path (mkcert -CAROOT) 'rootCA.pem'
function Code([string]$url, [string[]]$extra = @()) {
    [int](curl.exe -s --ssl-no-revoke --cacert $ca -o NUL -w '%{http_code}' @extra $url)
}
function ServedBy() {
    $h = curl.exe -s --ssl-no-revoke --cacert $ca -D - -o NUL https://localhost/api/healthz
    (($h | Where-Object { $_ -match '^x-served-by:' }) -replace '^x-served-by:\s*', '').Trim()
}

"== WAF (ModSecurity + OWASP CRS)"
Check 'normal request -> 200' ((Code 'https://localhost/api/receipts?limit=1') -eq 200)
$c = Code "https://localhost/api/receipts?month=1'%20OR%201=1--"
Check "SQL injection in query -> 403 (got $c)" ($c -eq 403)
$c = Code 'https://localhost/api/receipts?q=%3Cscript%3Ealert(1)%3C/script%3E'
Check "XSS in query -> 403 (got $c)" ($c -eq 403)
$c = Code 'https://localhost/api/receipts?file=../../etc/passwd'
Check "path traversal -> 403 (got $c)" ($c -eq 403)
$png = Join-Path $env:TEMP 'rl-one.png'
[IO.File]::WriteAllBytes($png, [Convert]::FromBase64String('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=='))
Check 'real PNG upload still passes the WAF -> 201' ((Code 'https://localhost/api/receipts' @('-X', 'POST', '-F', "file=@$png;type=image/png")) -eq 201)
Check '/api/metrics is not exposed -> 404' ((Code 'https://localhost/api/metrics') -eq 404)
Check 'DELETE is not an allowed method -> 403' ((Code 'https://localhost/api/receipts' @('-X', 'DELETE')) -eq 403)

"`n== Rate limit on uploads (2/s, burst 10)"
Start-Sleep -Seconds 6   # let the bucket refill after the upload above
$txt = Join-Path $env:TEMP 'rl-not-image.txt'
Set-Content $txt 'not an image' -Encoding ascii
$codes = 1..25 | ForEach-Object { Code 'https://localhost/api/receipts' @('-X', 'POST', '-F', "file=@$txt") }
$n429 = @($codes | Where-Object { $_ -eq 429 }).Count
Check "25 rapid uploads -> some 429 (got $n429)" ($n429 -gt 0)
Check 'reads are not throttled by the upload limit' ((Code 'https://localhost/api/receipts?limit=1') -eq 200)

"`n== Load balancing (HAProxy, 2 replicas)"
docker compose up -d --no-deps --no-recreate --scale api=2 api 2>$null | Out-Null
$deadline = (Get-Date).AddSeconds(60)
do { Start-Sleep 2; $healthy = @(docker compose ps api --format '{{.Health}}' | Where-Object { $_ -eq 'healthy' }).Count } until ($healthy -ge 2 -or (Get-Date) -gt $deadline)
Start-Sleep 7   # HAProxy: 2 passing checks, 3 s apart
$seen = 1..12 | ForEach-Object { ServedBy } | Group-Object
Check "12 requests spread over 2 replicas ($(($seen | ForEach-Object { "$($_.Name)x$($_.Count)" }) -join ', '))" ($seen.Count -eq 2)

"`n== Failover: one replica dies, requests keep succeeding"
$victim = (docker compose ps api -q | Select-Object -First 1)
docker kill $victim 2>$null | Out-Null
$ok = @(1..30 | ForEach-Object { Code 'https://localhost/api/healthz'; Start-Sleep -Milliseconds 200 } | Where-Object { $_ -eq 200 }).Count
Check "30 requests over 6 s after killing a replica -> all 200 (got $ok)" ($ok -eq 30)
docker compose up -d --no-deps --scale api=2 api 2>$null | Out-Null

"`n== Metrics"
$targets = docker compose exec -T prometheus wget -qO- 'http://localhost:9090/api/v1/targets?state=active' | ConvertFrom-Json
$up = @($targets.data.activeTargets | Where-Object { $_.health -eq 'up' })
Check "Prometheus scrapes api replicas + haproxy ($($up.Count) targets up)" ((@($up | Where-Object { $_.labels.job -eq 'api' }).Count -ge 1) -and (@($up | Where-Object { $_.labels.job -eq 'haproxy' }).Count -eq 1))

Remove-Item $png, $txt -ErrorAction SilentlyContinue
"`n$(if ($fail) { "$fail check(s) FAILED" } else { 'All checks passed' })"
exit $fail
