# Week 5 evidence: dashboard + CSP, Grafana behind login, metrics coverage, image scan, lint and tests.
# Usage: powershell -File scripts/verify-week5.ps1   (stack must be running; images built)
$ErrorActionPreference = 'Continue'
$root = Split-Path $PSScriptRoot -Parent
Set-Location $root
$fail = 0
function Check([string]$name, [bool]$ok) {
    "{0,-66} {1}" -f $name, $(if ($ok) { 'PASS' } else { 'FAIL' })
    if (-not $ok) { $script:fail++ }
}
$ca = Join-Path (mkcert -CAROOT) 'rootCA.pem'
function Code([string]$url, [string[]]$extra = @()) {
    [int](curl.exe -s --ssl-no-revoke --cacert $ca -o NUL -w '%{http_code}' @extra $url)
}

"== Dashboard"
Check 'GET / -> 200' ((Code 'https://localhost/') -eq 200)
Check 'app.js and style.css served' (((Code 'https://localhost/app.js') -eq 200) -and ((Code 'https://localhost/style.css') -eq 200))
$csp = ((curl.exe -s --ssl-no-revoke --cacert $ca -D - -o NUL https://localhost/) | Where-Object { $_ -match '^content-security-policy:' }) -join ''
Check "CSP present: script-src 'self', no unsafe-inline" ($csp -match "script-src 'self'" -and $csp -notmatch 'unsafe-inline')
Check 'app.js never writes data with innerHTML' (-not (Select-String -Path web\app.js -Pattern 'innerHTML\s*=' -Quiet))
$xss = Join-Path $env:TEMP 'w5-xss.json'
[IO.File]::WriteAllText($xss, '{"merchant":"<img src=x onerror=alert(1)>"}')
$any = (curl.exe -s --ssl-no-revoke --cacert $ca 'https://localhost/api/receipts?limit=1' | ConvertFrom-Json)[0].id
Check 'stored-XSS payload in PATCH blocked by WAF -> 403' ((Code "https://localhost/api/receipts/$any" @('-X', 'PATCH', '-H', 'Content-Type: application/json', '--data-binary', "@$xss")) -eq 403)
Remove-Item $xss

"`n== Grafana (only through the edge, behind its login)"
Check 'GET /grafana/api/health -> 200' ((Code 'https://localhost/grafana/api/health') -eq 200)
Check 'API without login -> 401' ((Code 'https://localhost/grafana/api/search') -eq 401)
$pw = (Get-Content .env | Where-Object { $_ -like 'GRAFANA_ADMIN_PASSWORD=*' }) -replace '^GRAFANA_ADMIN_PASSWORD=', ''
$auth = 'Authorization: Basic ' + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("admin:$pw"))
$dash = curl.exe -s --ssl-no-revoke --cacert $ca -H $auth 'https://localhost/grafana/api/dashboards/uid/receiptlens' | ConvertFrom-Json
Check "provisioned dashboard has 8 panels (got $(@($dash.dashboard.panels).Count))" (@($dash.dashboard.panels).Count -eq 8)
$ds = curl.exe -s --ssl-no-revoke --cacert $ca -H $auth 'https://localhost/grafana/api/datasources/uid/prometheus/health' | ConvertFrom-Json
Check "Prometheus datasource healthy ($($ds.status))" ($ds.status -eq 'OK')

"`n== Metrics coverage"
$t = docker compose exec -T prometheus wget -qO- 'http://localhost:9090/api/v1/targets?state=active' | ConvertFrom-Json
$jobs = @($t.data.activeTargets | Where-Object health -eq 'up' | ForEach-Object { $_.labels.job } | Sort-Object -Unique)
Check "targets up: $($jobs -join ', ')" ((Compare-Object $jobs @('api', 'haproxy', 'rabbitmq')) -eq $null)

"`n== Supply chain (same gates as CI)"
foreach ($img in 'receiptlens-api', 'receiptlens-ocr-worker') {
    $j = trivy image --quiet --scanners vuln --severity HIGH,CRITICAL --ignore-unfixed --format json $img | ConvertFrom-Json
    $n = @($j.Results | ForEach-Object { $_.Vulnerabilities } | Where-Object { $_ }).Count
    Check "$img`: fixable HIGH/CRITICAL = $n" ($n -eq 0)
}
& .\.venv\Scripts\python -m ruff check . -q
Check 'ruff check' ($LASTEXITCODE -eq 0)
& .\.venv\Scripts\python -m ruff format --check . -q
Check 'ruff format --check' ($LASTEXITCODE -eq 0)
& .\.venv\Scripts\python -m pytest -q tests *> $null
Check 'pytest tests (parser, worker, autoscaler)' ($LASTEXITCODE -eq 0)
Push-Location api; & ..\.venv\Scripts\python -m pytest -q tests *> $null; $code = $LASTEXITCODE; Pop-Location
Check 'pytest api/tests' ($code -eq 0)

"`n$(if ($fail) { "$fail check(s) FAILED" } else { 'All checks passed' })"
exit $fail
