# 🚀 楽天MT4 AIクオンツ パイプライン - Windowsタスクスケジューラ自動起動 解除スクリプト
$TaskName = "RakutenFXQuantPipeline"

Write-Host "======================================================================" -ForegroundColor Cyan
Write-Host " 🚀 楽天MT4 AIクオンツ パイプライン - 自動起動タスクの解除" -ForegroundColor Cyan
Write-Host "======================================================================" -ForegroundColor Cyan
Write-Host ""

try {
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction Stop
    Write-Host "✅ [Success] 自動起動タスク '$TaskName' の解除が完了しました。" -ForegroundColor Green
} catch {
    Write-Host "ℹ️ [Info] 登録済みタスク '$TaskName' は見つかりませんでした。" -ForegroundColor Yellow
}

Write-Host ""
pause
