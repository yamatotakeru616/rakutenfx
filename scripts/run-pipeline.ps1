<#
.SYNOPSIS
  Docker Agent 開発パイプライン実行スクリプト (PowerShell)
.DESCRIPTION
  実行ごとに runs/ フォルダ配下に独立したセッションDB・成果物・監査ログディレクトリを作成し、
  docker-agent を起動します。
#>

param (
    [string]$AgentYaml = "agent.yaml",
    [string]$Prompt = "",
    [switch]$ResumeLastSession
)

$ErrorActionPreference = "Stop"

# PATH 環境変数の更新（winget などの新規インストール反映）
$env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path","User")

# .env ファイルの読み込み (存在する場合)
if (Test-Path ".env") {
    Get-Content ".env" | ForEach-Object {
        $line = $_.Trim()
        if ($line -and -not $line.StartsWith("#") -and $line.Contains("=")) {
            $parts = $line.Split("=", 2)
            $name = $parts[0].Trim()
            $val = $parts[1].Trim()
            [System.Environment]::SetEnvironmentVariable($name, $val, [System.EnvironmentVariableTarget]::Process)
        }
    }
}

# 実行コマンドの検出 (docker agent または docker-agent)
$AgentCmd = $null
if (Get-Command docker-agent -ErrorAction SilentlyContinue) {
    $AgentCmd = "docker-agent"
} elseif (Get-Command docker -ErrorAction SilentlyContinue) {
    $AgentCmd = "docker agent"
} else {
    Write-Error "Docker Agent CLI (docker agent / docker-agent) が見つかりませんでした。インストールを確認してください。"
}

$Timestamp = Get-Date -Format "yyyy-MM-dd-HHmmss"
$ShortId = [System.Guid]::NewGuid().ToString().Substring(0, 8)
$RunDir = "runs/$Timestamp-$ShortId"

if ($ResumeLastSession) {
    Write-Host ">>> 直前のセッションを再開します..." -ForegroundColor Cyan
    if ($AgentCmd -eq "docker agent") {
        docker agent run $AgentYaml --session -1
    } else {
        docker-agent run $AgentYaml --session -1
    }
} else {
    New-Item -ItemType Directory -Path "$RunDir/artifacts" -Force | Out-Null
    $SessionDb = "$RunDir/session.db"
    
    Write-Host "============================================================" -ForegroundColor Green
    Write-Host " Docker Agent Pipeline Starting" -ForegroundColor Green
    Write-Host " Run Directory : $RunDir" -ForegroundColor Yellow
    Write-Host " Session DB    : $SessionDb" -ForegroundColor Yellow
    Write-Host "============================================================" -ForegroundColor Green

    $Meta = @{
        timestamp = $Timestamp
        run_id = $ShortId
        agent_config = $AgentYaml
        prompt = $Prompt
    } | ConvertTo-Json
    $Meta | Out-File -FilePath "$RunDir/meta.json" -Encoding utf8

    $CmdArgs = @("run", $AgentYaml, "--session-db", $SessionDb)
    if ($Prompt) {
        $CmdArgs += @("--prompt", $Prompt)
    }

    if ($AgentCmd -eq "docker agent") {
        & docker agent @CmdArgs
    } else {
        & docker-agent @CmdArgs
    }
}
