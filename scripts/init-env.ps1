# Generates .env with random secrets and a local TLS certificate for the edge.
# Safe to re-run: an existing .env or certificate is kept, never overwritten.
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent

function New-Secret([int]$bytes = 24) {
    $b = New-Object byte[] $bytes
    # Create().GetBytes works on both Windows PowerShell 5.1 and PowerShell 7
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create(); $rng.GetBytes($b); $rng.Dispose()
    # URL-safe, no characters that break .env or JSON
    ([Convert]::ToBase64String($b)).TrimEnd('=').Replace('+', '-').Replace('/', '_')
}

$envFile = Join-Path $root '.env'
$wanted = [ordered]@{
    POSTGRES_USER     = 'receiptlens'
    POSTGRES_PASSWORD = New-Secret
    API_DB_PASSWORD   = New-Secret
    RABBITMQ_USER     = 'receiptlens'
    RABBITMQ_PASSWORD = New-Secret
    S3_ADMIN_KEY      = "admin$(New-Secret 9)"
    S3_ADMIN_SECRET   = New-Secret
    S3_API_KEY        = "api$(New-Secret 9)"
    S3_API_SECRET     = New-Secret
    S3_OCR_KEY        = "ocr$(New-Secret 9)"
    S3_OCR_SECRET     = New-Secret
}
# Keep every existing value; only append keys that are missing (e.g. added in a later week).
$have = @{}
if (Test-Path $envFile) {
    Get-Content $envFile | Where-Object { $_ -match '^([A-Z0-9_]+)=' } | ForEach-Object { $have[$Matches[1]] = $true }
}
$missing = @($wanted.Keys | Where-Object { -not $have.ContainsKey($_) } | ForEach-Object { "$_=$($wanted[$_])" })
if ($missing.Count) {
    Add-Content -Path $envFile -Value $missing -Encoding ascii
    Write-Host "Added $($missing.Count) new secret(s) to .env (values not printed)."
} else {
    Write-Host '.env already complete, keeping it.'
}

$certDir = Join-Path $root 'edge\certs'
New-Item -ItemType Directory -Force $certDir | Out-Null
$cert = Join-Path $certDir 'edge.pem'
if (Test-Path $cert) {
    Write-Host 'Edge certificate already exists, keeping it.'
} else {
    if (-not (Get-Command mkcert -ErrorAction SilentlyContinue)) { throw 'mkcert not found. Install it: winget install --id FiloSottile.mkcert -e' }
    # Creates a local CA on first use but does NOT add it to the Windows trust store.
    # To trust it in your browser, run `mkcert -install` yourself.
    mkcert -cert-file $cert -key-file (Join-Path $certDir 'edge-key.pem') localhost 127.0.0.1 ::1
}
