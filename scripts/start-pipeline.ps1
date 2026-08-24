param (
    [switch]$Emulate,
    [int]$Ticks = 150,
    [string]$WebhookUrl = ""
)

$ErrorActionPreference = "Stop"

Write-Host "======================================================" -ForegroundColor Cyan
Write-Host ">>> Starting MT4 Trading & Go Evaluation Pipeline" -ForegroundColor Cyan
Write-Host "======================================================" -ForegroundColor Cyan

# 1. Check or Build Rust Gateway & Go Server
Write-Host "`n[1/4] Checking Binaries..." -ForegroundColor Yellow
if (-not (Test-Path "target/debug/gateway.exe")) {
    cargo build --bin gateway --quiet
}
if (-not (Test-Path "rakutenfx.exe")) {
    go build -ldflags="-s -w" -o rakutenfx.exe ./cmd/server
}

# 2. Check and Start Go Server (Port 8080 & 5556)
$GoServerRunning = $false
try {
    $conn = Test-NetConnection -ComputerName "127.0.0.1" -Port 8080 -WarningAction SilentlyContinue -InformationLevel Quiet
    if ($conn) {
        $GoServerRunning = $true
        Write-Host "`n[2/4] Go Server is already running on http://localhost:8080. Reusing existing instance." -ForegroundColor Green
    }
} catch {}

$GoProcess = $null
if (-not $GoServerRunning) {
    Write-Host "`n[2/4] Starting Go Server (rakutenfx.exe)..." -ForegroundColor Yellow
    $GoProcess = Start-Process -FilePath ".\rakutenfx.exe" -PassThru -NoNewWindow
    Start-Sleep -Seconds 2
}

# 3. Check and Start Gateway Server (Port 5555)
$GatewayRunning = $false
try {
    $conn = Test-NetConnection -ComputerName "127.0.0.1" -Port 5555 -WarningAction SilentlyContinue -InformationLevel Quiet
    if ($conn) {
        $GatewayRunning = $true
        Write-Host "`n[3/4] Rust Gateway is already running on 127.0.0.1:5555. Reusing existing instance." -ForegroundColor Green
    }
} catch {}

$GatewayProcess = $null
if (-not $GatewayRunning) {
    Write-Host "`n[3/4] Starting Rust Gateway Server (target\debug\gateway.exe)..." -ForegroundColor Yellow
    $GatewayProcess = Start-Process -FilePath ".\target\debug\gateway.exe" -ArgumentList "serve" -PassThru -NoNewWindow
    Start-Sleep -Seconds 2
}

try {
    # 4. Run Virtual Emulator if requested
    if ($Emulate) {
        Write-Host "`n[4/4] Running MT4 Virtual Emulator ($Ticks ticks)..." -ForegroundColor Yellow
        & ".\target\debug\gateway.exe" emulate --symbol "USDJPY" --base-price 158.60 --ticks $Ticks --interval-ms 30
        Start-Sleep -Seconds 1
    }

    # Verify Metrics via Go REST API
    $metrics = Invoke-RestMethod -Uri "http://localhost:8080/api/metrics" -Method Get
    Write-Host "`n======================================================" -ForegroundColor Green
    Write-Host "✅ Pipeline execution verified successfully via Go REST API!" -ForegroundColor Green
    Write-Host "   Total Trades: $($metrics.total_trades) | Win Rate: $($metrics.win_rate)% | Profit Factor: $($metrics.profit_factor)" -ForegroundColor Green
    Write-Host "   Web Cockpit : http://localhost:8080" -ForegroundColor Cyan
    Write-Host "======================================================" -ForegroundColor Green
}
finally {
    if ($GatewayProcess -and -not $GatewayProcess.HasExited) {
        Stop-Process -Id $GatewayProcess.Id -Force -ErrorAction SilentlyContinue
    }
    if ($GoProcess -and -not $GoProcess.HasExited) {
        Stop-Process -Id $GoProcess.Id -Force -ErrorAction SilentlyContinue
    }
}
