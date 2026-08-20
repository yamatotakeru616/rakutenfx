# 🚀 楽天MT4 AIクオンツ パイプライン - Windowsタスクスケジューラ自動起動 登録スクリプト
$TaskName = "RakutenFXQuantPipeline"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectDir = Split-Path -Parent $ScriptDir
$BatPath = Join-Path $ScriptDir "start_all.bat"

Write-Host "======================================================================" -ForegroundColor Cyan
Write-Host " 🚀 楽天MT4 AIクオンツ パイプライン - 自動起動タスクの登録" -ForegroundColor Cyan
Write-Host "======================================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "登録対象スクリプト: $BatPath" -ForegroundColor Yellow

$Action = New-ScheduledTaskAction -Execute "cmd.exe" -Argument "/c `"$BatPath`"" -WorkingDirectory $ProjectDir
$Trigger = New-ScheduledTaskTrigger -AtLogOn
$Settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Days 365)
$Principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Highest

try {
    # 既存タスクがあれば削除
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue

    # 新規登録
    Register-ScheduledTask -TaskName $TaskName -Action $Action -Trigger $Trigger -Settings $Settings -Principal $Principal | Out-Null
    Write-Host ""
    Write-Host "✅ [Success] Windowsログオン時の自動起動タスク '$TaskName' の登録が完了しました！" -ForegroundColor Green
    Write-Host "次回PC起動時より、ログインと同時にRust GatewayとPython IPCが自動起動します。" -ForegroundColor Green
} catch {
    Write-Host ""
    Write-Host "❌ [Error] タスクの登録に失敗しました: $_" -ForegroundColor Red
    Write-Host "PowerShellを「管理者として実行」してお試しください。" -ForegroundColor Yellow
}

Write-Host ""
pause
