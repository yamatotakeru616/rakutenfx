# MT4 Trading Pipeline Automated Runner & Verification Script
param (
    [bool]$Emulate = $true,
    [int]$Ticks = 150,
    [string]$WebhookUrl = ""
)

$ErrorActionPreference = "Stop"
$env:CARGO_TARGET_DIR = "$env:LOCALAPPDATA\cargo-target"

Write-Host "======================================================" -ForegroundColor Cyan
Write-Host ">>> Starting MT4 Trading & Evaluation Pipeline" -ForegroundColor Cyan
Write-Host "======================================================" -ForegroundColor Cyan

# 1. Build Rust Gateway
Write-Host "`n[1/4] Building Rust Gateway..." -ForegroundColor Yellow
cargo build --bin gateway --quiet

$GatewayExe = "$env:CARGO_TARGET_DIR\debug\gateway.exe"
if (-not (Test-Path $GatewayExe)) {
    Write-Error "Gateway executable not found at $GatewayExe"
}

# 2. Check and Start Gateway Server if needed
$AlreadyRunning = $false
try {
    $conn = Test-NetConnection -ComputerName "127.0.0.1" -Port 5555 -WarningAction SilentlyContinue -InformationLevel Quiet
    if ($conn) {
        $AlreadyRunning = $true
        Write-Host "`n[2/4] Rust Gateway is already running on 127.0.0.1:5555. Reusing existing instance." -ForegroundColor Green
    }
} catch {}

$ServerProcess = $null
if (-not $AlreadyRunning) {
    Write-Host "`n[2/4] Starting Rust Gateway Server (127.0.0.1:5555)..." -ForegroundColor Yellow
    $ServerProcess = Start-Process -FilePath $GatewayExe -ArgumentList "serve --bind 127.0.0.1:5555 --db trade_pipeline.db" -PassThru -NoNewWindow
    Start-Sleep -Seconds 2
}

try {
    # 3. Run Emulator if requested
    if ($Emulate) {
        Write-Host "`n[3/4] Running MT4 Virtual Emulator ($Ticks ticks)..." -ForegroundColor Yellow
        & $GatewayExe emulate --symbol "USDJPY" --base-price 155.20 --ticks $Ticks --interval-ms 30
        Start-Sleep -Seconds 1
    } else {
        Write-Host "`n[3/4] Waiting for MT4 Client connection on port 5555... (Press Ctrl+C to stop)" -ForegroundColor Yellow
        Start-Sleep -Seconds 10
    }

    # 4. Run Python Trade Evaluator & AI Notifier
    Write-Host "`n[4/4] Running Python & Gemini AI Trade Evaluator..." -ForegroundColor Yellow
    
    $PythonCmd = "python"
    if (Get-Command py -ErrorAction SilentlyContinue) {
        $PythonCmd = "py"
    }

    $EvalArgs = @("python/evaluator/main.py", "--db", "trade_pipeline.db")
    if ($WebhookUrl -ne "") {
        $EvalArgs += @("--webhook", $WebhookUrl)
    }

    & $PythonCmd @EvalArgs

    Write-Host "`n======================================================" -ForegroundColor Green
    Write-Host "[SUCCESS] MT4 Trading Pipeline execution completed successfully!" -ForegroundColor Green
    Write-Host "======================================================" -ForegroundColor Green
}
finally {
    # Clean up server process
    if ($ServerProcess -and -not $ServerProcess.HasExited) {
        Write-Host "`n[Cleanup] Stopping Gateway Server (PID: $($ServerProcess.Id))..." -ForegroundColor Gray
        Stop-Process -Id $ServerProcess.Id -Force -ErrorAction SilentlyContinue
    }
}
