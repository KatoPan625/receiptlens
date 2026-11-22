# Week 4 evidence: upload -> RabbitMQ -> OCR worker -> result back in the API, failure paths, least privilege.
# Usage: powershell -File scripts/verify-week4.ps1   (stack must be running: docker compose up -d)
# Uses a SYNTHETIC receipt (tests/fixtures/make_receipt.py). It proves the pipeline works end to end;
# OCR accuracy on real receipts is measured separately with photos in samples/.
$ErrorActionPreference = 'Continue'
$root = Split-Path $PSScriptRoot -Parent
Set-Location $root
$fail = 0
function Check([string]$name, [bool]$ok) {
    "{0,-66} {1}" -f $name, $(if ($ok) { 'PASS' } else { 'FAIL' })
    if (-not $ok) { $script:fail++ }
}
$ca = Join-Path (mkcert -CAROOT) 'rootCA.pem'
$base = 'https://localhost/api'
function Upload([string]$file) {
    (curl.exe -s --ssl-no-revoke --cacert $ca -X POST -F "file=@$file;type=image/png" "$base/receipts") | ConvertFrom-Json
}
function WaitFor([string]$id, [int]$seconds) {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    do {
        Start-Sleep -Milliseconds 500
        $r = (curl.exe -s --ssl-no-revoke --cacert $ca "$base/receipts/$id") | ConvertFrom-Json
    } until ($r.status -ne 'uploaded' -or $sw.Elapsed.TotalSeconds -gt $seconds)
    $r | Add-Member -NotePropertyName seconds -NotePropertyValue ([math]::Round($sw.Elapsed.TotalSeconds, 1)) -PassThru
}
function DeadCount([string]$queue) {
    $line = docker compose exec -T rabbitmq rabbitmqctl -q list_queues name messages | Where-Object { $_ -match "^$([regex]::Escape($queue))\s" }
    if ($line) { [int](($line -split '\s+')[1]) } else { -1 }
}
$tmp = Join-Path $env:TEMP 'receiptlens-w4'
New-Item -ItemType Directory -Force $tmp | Out-Null

"== Happy path: synthetic receipt, total 125.000 VND"
$img = Join-Path $tmp 'receipt.png'
& .\.venv\Scripts\python tests\fixtures\make_receipt.py $img 125000
$up = Upload $img
Check 'upload -> status uploaded' ($up.status -eq 'uploaded')
$r = WaitFor $up.id 30
Check "OCR result stored, status parsed (took $($r.seconds) s)" ($r.status -eq 'parsed')
Check 'end-to-end <= 15 s (G1)' ($r.seconds -le 15)
Check "total_vnd = 125000 (got $($r.total_vnd))" ($r.total_vnd -eq 125000)
Check "purchased_at = 2026-11-20 09:30 +07:00 (got $($r.purchased_at))" ([datetimeoffset]$r.purchased_at -eq [datetimeoffset]'2026-11-20T09:30:00+07:00')
Check "merchant read (got '$($r.merchant)')" ($r.merchant -match 'PH')
Check 'raw OCR text kept for review' ($r.raw_text -match '125')

"`n== Failure path: valid PNG signature, undecodable body"
$bad = Join-Path $tmp 'broken.png'
[IO.File]::WriteAllBytes($bad, [byte[]](0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A) + [byte[]](1..200))
$b = WaitFor (Upload $bad).id 30
Check "broken image ends as failed, not stuck (took $($b.seconds) s)" ($b.status -eq 'failed')

"`n== Poison message goes to the dead-letter queue"
$before = DeadCount 'ocr.requests.dead'
docker compose exec -T api python -c "from app.events import publisher; publisher.publish('receipt.uploaded', 'not-a-receipt-object')" 2>$null
Start-Sleep -Seconds 4
$after = DeadCount 'ocr.requests.dead'
Check "malformed request dead-lettered ($before -> $after)" ($after -eq $before + 1)

"`n== Least privilege"
$py = "import pika,os; c=pika.BlockingConnection(pika.ConnectionParameters('rabbitmq',credentials=pika.PlainCredentials('ocr',os.environ['RABBIT_PASSWORD']))); c.channel().basic_get('api.results')"
$o = docker compose exec -T ocr-worker python -c $py 2>&1
Check 'RabbitMQ user ocr cannot read api.results' ("$o" -match 'ACCESS_REFUSED|403')
$py = "import pika,os; c=pika.BlockingConnection(pika.ConnectionParameters('rabbitmq',credentials=pika.PlainCredentials('api',os.environ['RABBIT_PASSWORD']))); c.channel().queue_declare('rogue')"
$o = docker compose exec -T api python -c $py 2>&1
Check 'RabbitMQ user api cannot create queues' ("$o" -match 'ACCESS_REFUSED|403')
$py = "import boto3,os; from botocore.config import Config; boto3.client('s3',endpoint_url='http://storage:8333',aws_access_key_id=os.environ['S3_KEY'],aws_secret_access_key=os.environ['S3_SECRET'],region_name='us-east-1',config=Config(s3={'addressing_style':'path'})).put_object(Bucket='receipts-raw',Key='x',Body=b'x')"
$o = docker compose exec -T ocr-worker python -c $py 2>&1
Check 'S3 key of the OCR worker is read-only' ("$o" -match 'AccessDenied|403')
docker compose exec -T ocr-worker python -c "import urllib.request; urllib.request.urlopen('https://example.com', timeout=5)" 2>$null
Check 'OCR worker has no Internet egress' ($LASTEXITCODE -ne 0)

"`n== Queues drained"
$q = docker compose exec -T rabbitmq rabbitmqctl -q list_queues name messages | Where-Object { $_ -match '^(ocr\.requests|api\.results)\s' }
Check "work queues empty ($(($q -replace '\s+', '=') -join ', '))" (@($q | Where-Object { [int](($_ -split '\s+')[1]) -ne 0 }).Count -eq 0)

Remove-Item -Recurse -Force $tmp
"`n$(if ($fail) { "$fail check(s) FAILED" } else { 'All checks passed' })"
exit $fail
