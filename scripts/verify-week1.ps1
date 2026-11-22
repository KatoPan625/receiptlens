# Week 1 evidence: only 443 is reachable, and the data tier cannot reach the Internet.
# Usage: powershell -File scripts/verify-week1.ps1   (stack must be running: docker compose up -d)
$ErrorActionPreference = 'Continue'
$root = Split-Path $PSScriptRoot -Parent
Set-Location $root
$fail = 0
function Check([string]$name, [bool]$ok) {
    "{0,-58} {1}" -f $name, $(if ($ok) { 'PASS' } else { 'FAIL' })
    if (-not $ok) { $script:fail++ }
}

"== Services healthy"
$ps = docker compose ps --format json | ForEach-Object { $_ | ConvertFrom-Json }
foreach ($s in 'edge', 'postgres', 'rabbitmq', 'storage') {
    $h = ($ps | Where-Object Service -eq $s).Health
    Check "$s is healthy (got: $h)" ($h -eq 'healthy')
}

"`n== Published ports: the stack exposes only 443"
# Checks what THIS stack publishes, so other containers on the host (e.g. another project's Postgres) don't skew it.
$published = @($ps | ForEach-Object { $_.Publishers } | Where-Object { $_.PublishedPort -gt 0 } |
    ForEach-Object { $_.PublishedPort } | Sort-Object -Unique)
Check "published ports = 443 (got: $($published -join ', '))" (($published -join ',') -eq '443')
$c = New-Object Net.Sockets.TcpClient
$up = $c.ConnectAsync('127.0.0.1', 443).Wait(1500) -and $c.Connected
$c.Close()
Check "port 443 answers on the host" $up

"`n== Edge answers over TLS (verified against the local mkcert CA)"
$ca = Join-Path (mkcert -CAROOT) 'rootCA.pem'
# --ssl-no-revoke: Windows Schannel otherwise fails because a local CA has no revocation list.
$body = (curl.exe -s --ssl-no-revoke --cacert $ca https://localhost/healthz) -join "`n"
Check "GET https://localhost/healthz -> ok" ($body -match '^ok')

"`n== Internal networks have no Internet egress"
foreach ($s in 'postgres', 'storage') {
    docker compose exec -T $s sh -c 'wget -q -T 5 -O /dev/null https://example.com' 2>$null
    Check "$s cannot reach https://example.com" ($LASTEXITCODE -ne 0)
}
# The edge image (ModSecurity CRS) ships curl but not wget/nc.
docker compose exec -T edge curl -s -m 5 -o /dev/null https://example.com 2>$null
Check "edge CAN reach the Internet (control)" ($LASTEXITCODE -eq 0)

"`n== Edge cannot reach the data tier directly"
# Only curl's network errors count as "blocked": 6 = name not resolvable (not on the network),
# 7 = connection refused, 28 = timeout. Any other code (e.g. 127 = tool missing) is a FAIL.
docker compose exec -T edge curl -s --connect-timeout 3 -o /dev/null http://postgres:5432 2>$null
Check "edge -> postgres:5432 blocked (curl exit $LASTEXITCODE)" (@(6, 7, 28) -contains $LASTEXITCODE)
docker compose exec -T edge curl -s --connect-timeout 3 -o /dev/null http://storage:9333 2>$null
Check "edge -> storage admin port 9333 blocked (curl exit $LASTEXITCODE)" (@(6, 7, 28) -contains $LASTEXITCODE)

"`n$(if ($fail) { "$fail check(s) FAILED" } else { 'All checks passed' })"
exit $fail
