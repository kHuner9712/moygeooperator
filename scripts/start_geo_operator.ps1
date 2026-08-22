param(
    [switch]$NoBrowser
)

$ErrorActionPreference = "Stop"
$projectRoot = Split-Path -Parent $PSScriptRoot
$healthUrl = "http://127.0.0.1:8765/api/health"
$dashboardUrl = "http://127.0.0.1:8765"
$logDir = Join-Path $projectRoot "logs"
$launcherLog = Join-Path $logDir "launcher.log"
$serverStdoutLog = Join-Path $logDir "server.stdout.log"
$serverStderrLog = Join-Path $logDir "server.stderr.log"
$workerStdoutLog = Join-Path $logDir "worker.stdout.log"
$workerStderrLog = Join-Path $logDir "worker.stderr.log"

New-Item -ItemType Directory -Path $logDir -Force | Out-Null

function Write-LauncherLog {
    param([string]$Message)
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Add-Content -Path $launcherLog -Value "[$timestamp] $Message" -Encoding UTF8
}

function Test-GeoOperatorHealth {
    try {
        $response = Invoke-WebRequest -Uri $healthUrl -UseBasicParsing -TimeoutSec 2
        return $response.StatusCode -eq 200
    }
    catch {
        return $false
    }
}

function Test-WorkerRunning {
    $worker = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
        Where-Object {
            $_.CommandLine -and
            $_.CommandLine -like "*$projectRoot\.venv\Scripts\geo-operator-worker*"
        } |
        Select-Object -First 1
    return $null -ne $worker
}

function Resolve-UvPath {
    $uvCommand = Get-Command "uv.exe" -ErrorAction SilentlyContinue
    if ($null -ne $uvCommand) {
        return $uvCommand.Source
    }

    $fallbackUv = Join-Path $env:USERPROFILE ".local\bin\uv.exe"
    if (Test-Path -Path $fallbackUv -PathType Leaf) {
        return $fallbackUv
    }

    throw "uv.exe was not found. Install uv or add it to PATH."
}

function Ensure-ControlService {
    param([string]$UvPath)

    if (Test-GeoOperatorHealth) {
        Write-LauncherLog "Control service already healthy; reusing the running instance."
        return
    }

    Write-LauncherLog "Starting GEO Operator control service from $projectRoot"
    $serverProcess = Start-Process `
        -FilePath $UvPath `
        -ArgumentList @("run", "geo-operator") `
        -WorkingDirectory $projectRoot `
        -WindowStyle Hidden `
        -RedirectStandardOutput $serverStdoutLog `
        -RedirectStandardError $serverStderrLog `
        -PassThru

    for ($attempt = 1; $attempt -le 40; $attempt++) {
        if (Test-GeoOperatorHealth) {
            Write-LauncherLog "Control service healthy. Launcher PID=$($serverProcess.Id)."
            return
        }

        if ($serverProcess.HasExited) {
            throw "GEO Operator control service exited during startup with code $($serverProcess.ExitCode)."
        }

        Start-Sleep -Milliseconds 500
    }

    throw "GEO Operator control service did not become healthy within 20 seconds."
}

function Ensure-BrowserWorker {
    param([string]$UvPath)

    if (Test-WorkerRunning) {
        Write-LauncherLog "Browser Worker already running; reusing the existing process."
        return
    }

    Write-LauncherLog "Starting GEO Operator Browser Worker."
    $workerProcess = Start-Process `
        -FilePath $UvPath `
        -ArgumentList @("run", "geo-operator-worker") `
        -WorkingDirectory $projectRoot `
        -WindowStyle Hidden `
        -RedirectStandardOutput $workerStdoutLog `
        -RedirectStandardError $workerStderrLog `
        -PassThru

    for ($attempt = 1; $attempt -le 40; $attempt++) {
        if (Test-WorkerRunning) {
            Start-Sleep -Milliseconds 750
            if (Test-WorkerRunning) {
                Write-LauncherLog "Browser Worker running. Launcher PID=$($workerProcess.Id)."
                return
            }
        }

        if ($workerProcess.HasExited) {
            throw "Browser Worker exited during startup with code $($workerProcess.ExitCode)."
        }

        Start-Sleep -Milliseconds 250
    }

    throw "Browser Worker did not remain running within 10 seconds."
}

function Open-Dashboard {
    if (-not $NoBrowser) {
        Start-Process $dashboardUrl
    }
}

try {
    $uvPath = Resolve-UvPath
    Ensure-ControlService -UvPath $uvPath
    Ensure-BrowserWorker -UvPath $uvPath
    Open-Dashboard
    exit 0
}
catch {
    Write-LauncherLog "START FAILED: $($_.Exception.Message)"
    Write-Error $_.Exception.Message
    exit 1
}
