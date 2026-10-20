<#
.SYNOPSIS
    Golden path: run the whole project end to end from a clean checkout.

.DESCRIPTION
    Stages (each logged to logs\<stage>.log and summarised in logs\golden_path.log):
      setup        create .venv (Python 3.11) and install requirements
      tests        ruff lint + pytest with coverage
      pipeline     download TLC data, clean, aggregate, build features, split
      train        tune/train XGBoost + LightGBM, register winners in MLflow
      api_health   start the FastAPI app on a spare port and require /health status ok
      predict      one live fare prediction against that API
      batch        recursive batch demand forecast into predictions.db
      responsible  SHAP + subgroup fairness + model cards
      drift        synthetic drift report (PSI/KS) for both problems
    Exits non-zero if any stage fails.

.EXAMPLE
    .\scripts\run_all.ps1
    .\scripts\run_all.ps1 -SkipDownload -SkipInstall      # rerun with cached data and existing venv
#>

[CmdletBinding()]
param(
    [int]$NTrials = 1,
    [int]$ApiPort = 8010,
    [switch]$SkipDownload,
    [switch]$SkipInstall,
    [switch]$KeepApi
)

# Native tools write logs to stderr; "Continue" stops PowerShell treating that as a failure.
# Each stage is judged by its exit code instead.
$ErrorActionPreference = "Continue"

$Root = Split-Path -Parent $PSScriptRoot
Set-Location $Root
New-Item -ItemType Directory -Force -Path logs | Out-Null

$Log = Join-Path $Root "logs\golden_path.log"
$Py = Join-Path $Root ".venv\Scripts\python.exe"
$Commit = (git rev-parse HEAD 2>$null)
if (-not $Commit) { $Commit = "unknown (not a git checkout)" }

"Golden path run started $(Get-Date -Format s)" | Set-Content $Log
"Commit: $Commit" | Add-Content $Log
"Host: $env:COMPUTERNAME  NTrials: $NTrials  ApiPort: $ApiPort" | Add-Content $Log

$script:Results = [ordered]@{}
$script:Failed = $false

function Invoke-Stage {
    param([string]$Name, [scriptblock]$Action)
    if ($script:Failed) {
        $script:Results[$Name] = "SKIPPED"
        "STAGE $Name SKIPPED (earlier stage failed)" | Add-Content $Log
        return
    }
    $start = Get-Date
    Write-Host ""
    Write-Host "=== STAGE: $Name ===" -ForegroundColor Cyan
    "STAGE $Name STARTED $($start.ToString('s'))" | Add-Content $Log
    $global:LASTEXITCODE = 0
    & $Action *>&1 | Tee-Object -FilePath (Join-Path $Root "logs\$Name.log") | Out-Host
    $code = $LASTEXITCODE
    $secs = [int]((Get-Date) - $start).TotalSeconds
    if ($code -eq 0) {
        $script:Results[$Name] = "PASS"
        Write-Host "PASS: $Name (${secs}s)" -ForegroundColor Green
        "STAGE $Name PASS in ${secs}s" | Add-Content $Log
    }
    else {
        $script:Results[$Name] = "FAIL"
        $script:Failed = $true
        Write-Host "FAIL: $Name (exit $code, ${secs}s) - see logs\$Name.log" -ForegroundColor Red
        "STAGE $Name FAIL exit=$code in ${secs}s" | Add-Content $Log
    }
}

Invoke-Stage "setup" {
    if (-not (Test-Path $Py)) { py -3.11 -m venv .venv }
    if (-not (Test-Path $Py)) { Write-Error "Could not create .venv with Python 3.11"; $global:LASTEXITCODE = 1; return }
    if (-not $SkipInstall) {
        & $Py -m pip install --upgrade pip
        & $Py -m pip install -r requirements.txt
        if ($LASTEXITCODE -ne 0) { return }
        & $Py -m pip install -r requirements-dashboard.txt
        if ($LASTEXITCODE -ne 0) { return }
    }
    & $Py --version
}

Invoke-Stage "tests" {
    & $Py -m ruff check .
    if ($LASTEXITCODE -ne 0) {
        # Reported, not hidden: the lint result is written to logs\tests.log and the summary.
        Write-Host "WARNING: ruff reported findings (see above). Tests still run." -ForegroundColor Yellow
        "LINT WARN ruff reported findings" | Add-Content $Log
    }
    & $Py -m pytest --cov=src --cov-report=term-missing
}

Invoke-Stage "pipeline" {
    $raw = Test-Path "data\raw\yellow_tripdata_2024-01.parquet"
    if ($SkipDownload -and $raw) {
        & $Py -m scripts.run_pipeline --year 2024 --month 1 --skip-download
    }
    else {
        & $Py -m scripts.run_pipeline --year 2024 --month 1
    }
    if ($LASTEXITCODE -eq 0) { Get-Content "data\processed\pipeline_summary.json" }
}

Invoke-Stage "train" {
    & $Py -m scripts.train_models --n-trials $NTrials
}

$script:Api = $null
Invoke-Stage "api_health" {
    $out = Join-Path $Root "logs\api_server.out.log"
    $err = Join-Path $Root "logs\api_server.err.log"
    $script:Api = Start-Process -FilePath $Py `
        -ArgumentList "-m", "uvicorn", "src.serving.api:app", "--host", "127.0.0.1", "--port", "$ApiPort" `
        -WorkingDirectory $Root -PassThru -WindowStyle Hidden `
        -RedirectStandardOutput $out -RedirectStandardError $err
    $ok = $false
    for ($i = 0; $i -lt 60; $i++) {
        Start-Sleep -Seconds 3
        try {
            $h = Invoke-RestMethod -Uri "http://127.0.0.1:$ApiPort/health" -TimeoutSec 5
            if ($h.status -eq "ok" -and $h.demand_model_loaded -and $h.fare_model_loaded) {
                $h | ConvertTo-Json
                $ok = $true
                break
            }
        }
        catch { }
    }
    if ($ok) { $global:LASTEXITCODE = 0 } else { Write-Host "API did not become healthy; see $err"; $global:LASTEXITCODE = 1 }
}

Invoke-Stage "predict" {
    $fare = @{
        trip_distance = 17.0; pu_location_id = 132; do_location_id = 230
        passenger_count = 1; pickup_datetime = "2024-01-15T18:30:00"
    } | ConvertTo-Json
    try {
        Invoke-RestMethod -Method Post -Uri "http://127.0.0.1:$ApiPort/predict/fare" `
            -ContentType "application/json" -Body $fare | ConvertTo-Json
        $global:LASTEXITCODE = 0
    }
    catch { Write-Host "Prediction failed: $_"; $global:LASTEXITCODE = 1 }
}

Invoke-Stage "batch" {
    & $Py -m scripts.batch_forecast --horizon 3
}

Invoke-Stage "responsible" {
    & $Py -m scripts.responsible.run_analysis
}

Invoke-Stage "drift" {
    & $Py -m scripts.monitoring.demo_drift_report --problem all --mode drift
}

if ($script:Api -and -not $KeepApi) {
    Stop-Process -Id $script:Api.Id -Force -ErrorAction SilentlyContinue
}

Write-Host ""
Write-Host "=== GOLDEN PATH SUMMARY (commit $Commit) ===" -ForegroundColor Cyan
"SUMMARY finished $(Get-Date -Format s)" | Add-Content $Log
foreach ($k in $script:Results.Keys) {
    $v = $script:Results[$k]
    $color = switch ($v) { "PASS" { "Green" } "FAIL" { "Red" } default { "Yellow" } }
    Write-Host ("{0,-12} {1}" -f $k, $v) -ForegroundColor $color
    ("SUMMARY {0,-12} {1}" -f $k, $v) | Add-Content $Log
}

if ($script:Failed) {
    Write-Host "GOLDEN PATH FAILED" -ForegroundColor Red
    "RESULT FAIL" | Add-Content $Log
    exit 1
}
Write-Host "GOLDEN PATH PASSED - all stages complete" -ForegroundColor Green
"RESULT PASS" | Add-Content $Log
exit 0
