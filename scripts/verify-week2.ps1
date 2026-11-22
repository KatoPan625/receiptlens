# Week 2 evidence: upload flow through the TLS edge, input validation, least privilege.
# Usage: powershell -File scripts/verify-week2.ps1   (stack must be running: docker compose up -d)
$ErrorActionPreference = 'Continue'
$root = Split-Path $PSScriptRoot -Parent
Set-Location $root
$fail = 0
function Check([string]$name, [bool]$ok) {
    "{0,-62} {1}" -f $name, $(if ($ok) { 'PASS' } else { 'FAIL' })
    if (-not $ok) { $script:fail++ }
}
$base = 'https://localhost/api'
$ca = Join-Path (mkcert -CAROOT) 'rootCA.pem'
# curl wrapper: returns @{code; body}. --ssl-no-revoke: Schannel can't check revocation of a local CA.
function Api([string[]]$curlArgs) {
    $out = curl.exe -s --ssl-no-revoke --cacert $ca -w "`n%{http_code}" @curlArgs
    $lines = @($out)
    @{ code = [int]$lines[-1]; body = ($lines[0..($lines.Count - 2)] -join "`n") }
}
$tmp = Join-Path $env:TEMP "receiptlens-verify"
New-Item -ItemType Directory -Force $tmp | Out-Null

"== Health through the edge"
Check 'GET /api/healthz -> 200' ((Api @("$base/healthz")).code -eq 200)

"`n== Upload, read back, correct"
# Smallest valid PNG (1x1 transparent pixel)
$png = Join-Path $tmp 'one.png'
[IO.File]::WriteAllBytes($png, [Convert]::FromBase64String('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=='))
$r = Api @('-X', 'POST', '-F', "file=@$png;type=image/png", "$base/receipts")
Check 'POST /api/receipts (PNG) -> 201' ($r.code -eq 201)
$id = ($r.body | ConvertFrom-Json).id
Check 'new receipt has status uploaded' (($r.body | ConvertFrom-Json).status -eq 'uploaded')

$list = Api @("$base/receipts")
Check 'GET /api/receipts lists it' ($list.code -eq 200 -and $list.body -match $id)

$back = Join-Path $tmp 'back.png'
curl.exe -s --ssl-no-revoke --cacert $ca -o $back "$base/receipts/$id/image"
Check 'GET image returns the exact bytes uploaded (S3 round trip)' ((Get-FileHash $png).Hash -eq (Get-FileHash $back).Hash)

# JSON goes through a file: Windows PowerShell 5.1 strips double quotes from native-command arguments.
function JsonFile([string]$json) { $f = Join-Path $tmp "$([guid]::NewGuid()).json"; [IO.File]::WriteAllText($f, $json); "@$f" }
$body = JsonFile '{"merchant":"Verify Cafe","total_vnd":125000,"purchased_at":"2026-11-20T09:30:00+07:00"}'
$p = Api @('-X', 'PATCH', '-H', 'Content-Type: application/json', '--data-binary', $body, "$base/receipts/$id")
Check 'PATCH -> 200 and status corrected' ($p.code -eq 200 -and ($p.body | ConvertFrom-Json).status -eq 'corrected')
$s = Api @("$base/stats/monthly")
Check 'GET /api/stats/monthly includes 2026-11' ($s.code -eq 200 -and $s.body -match '2026-11')

"`n== Input validation"
$fake = Join-Path $tmp 'evil.png'
Set-Content -Path $fake -Value '<?php system($_GET["c"]); ?>' -Encoding ascii
Check 'script disguised as .png -> 415' ((Api @('-X', 'POST', '-F', "file=@$fake;type=image/png", "$base/receipts")).code -eq 415)
$big = Join-Path $tmp 'big.png'
$bytes = New-Object byte[] (11MB); [Array]::Copy([IO.File]::ReadAllBytes($png), $bytes, 8)
[IO.File]::WriteAllBytes($big, $bytes)
Check '11 MB upload -> 413' ((Api @('-X', 'POST', '-F', "file=@$big;type=image/png", "$base/receipts")).code -eq 413)
Check 'negative total -> 422' ((Api @('-X', 'PATCH', '-H', 'Content-Type: application/json', '--data-binary', (JsonFile '{"total_vnd":-1}'), "$base/receipts/$id")).code -eq 422)

"`n== Least privilege"
$apiPw = (Get-Content .env | Where-Object { $_ -like 'API_DB_PASSWORD=*' }) -replace '^API_DB_PASSWORD=', ''
$del = docker compose exec -T -e PGPASSWORD=$apiPw postgres psql -h 127.0.0.1 -U api_rw -d receiptlens -c 'DELETE FROM receipts' 2>&1
Check 'DB role api_rw cannot DELETE' ("$del" -match 'permission denied')
$drop = docker compose exec -T -e PGPASSWORD=$apiPw postgres psql -h 127.0.0.1 -U api_rw -d receiptlens -c 'DROP TABLE receipts' 2>&1
Check 'DB role api_rw cannot DROP TABLE' ("$drop" -match 'must be owner|permission denied')
$py = "from app.storage import get_storage; s = get_storage(); s.client.create_bucket(Bucket='not-allowed')"
$mk = docker compose exec -T api python -c $py 2>&1
Check 'S3 key of api cannot create buckets' ("$mk" -match 'AccessDenied|Forbidden|403')
docker compose exec -T api python -c "import urllib.request; urllib.request.urlopen('https://example.com', timeout=5)" 2>$null
Check 'api container has no Internet egress' ($LASTEXITCODE -ne 0)

Remove-Item -Recurse -Force $tmp
"`n$(if ($fail) { "$fail check(s) FAILED" } else { 'All checks passed' })"
exit $fail
