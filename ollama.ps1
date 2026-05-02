<#
.SYNOPSIS
    Wrapper around the two-Ollama-backend setup (ollama-big / ollama-small).

.DESCRIPTION
    Routes Ollama operations to the correct Docker container based on model size.
    Big models (> ThresholdGB on disk) -> ollama-big (3090 Ti, 24 GB).
    Small / embedding models -> ollama-small (5060 Ti, 16 GB).

    For commands that operate on an existing model (rm, stop, show, run),
    auto-detects which backend has it. Override with -Backend big|small.

.EXAMPLE
    .\ollama.ps1 pull qwen3:32b           # auto -> big
    .\ollama.ps1 pull granite4.1:1b       # auto -> small
    .\ollama.ps1 pull nomic-embed-text    # name pattern -> small
    .\ollama.ps1 pull qwen3:14b -Backend small   # force override
    .\ollama.ps1 list                     # list models on both backends
    .\ollama.ps1 ps                       # show loaded models on both GPUs
    .\ollama.ps1 rm granite4.1:3b         # delete model from disk (auto-finds backend)
    .\ollama.ps1 stop qwen3.6:27b         # unload from VRAM only; weights stay on disk
    .\ollama.ps1 run granite4.1:3b        # interactive chat
    .\ollama.ps1 size qwen3:32b           # check registry size without pulling
    .\ollama.ps1 start                    # docker compose up -d, wait healthy, open OWUI
    .\ollama.ps1 up                       # synonym for 'start'
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory=$true, Position=0)]
    [ValidateSet("pull", "list", "ps", "rm", "stop", "show", "run", "size", "start", "up", "help")]
    [string]$Command,

    [Parameter(Position=1)]
    [string]$Model,

    [ValidateSet("big", "small", "auto")]
    [string]$Backend = "auto",

    # Models with on-disk size > this go to big; otherwise small.
    # 8 GB covers ~13B Q4 weights; 27B+ goes to big.
    [double]$ThresholdGB = 8
)

$ErrorActionPreference = "Stop"

$Backends = @{
    big   = @{ container = "ai-stack-ollama-big-1";   url = "http://localhost:3003" }
    small = @{ container = "ai-stack-ollama-small-1"; url = "http://localhost:3004" }
}

$ComposeFile = Join-Path $PSScriptRoot "docker-compose.yml"
$WebUiUrl    = "http://localhost:3001"

function Normalize-Name([string]$n) {
    if ($n -notlike "*:*") { return "${n}:latest" }
    return $n
}

function Get-ModelSizeGB([string]$name) {
    $parts = $name -split ":", 2
    $modelName = $parts[0]
    $tag = if ($parts.Length -gt 1) { $parts[1] } else { "latest" }
    if ($modelName -notlike "*/*") { $modelName = "library/$modelName" }

    try {
        $hdr = @{ Accept = "application/vnd.docker.distribution.manifest.v2+json" }
        $r = Invoke-RestMethod -Uri "https://registry.ollama.ai/v2/$modelName/manifests/$tag" -Headers $hdr -TimeoutSec 10
        $bytes = ($r.layers | Measure-Object -Property size -Sum).Sum
        return [math]::Round($bytes / 1GB, 2)
    } catch {
        return $null
    }
}

function Resolve-PullBackend([string]$name) {
    if ($Backend -ne "auto") { return $Backend }

    # Embedding / reranker models always go to small.
    if ($name -match "(?i)embed|bge|e5-|gte-|rerank|jina") {
        Write-Host "[$name] embedding/reranker pattern -> small"
        return "small"
    }

    $sizeGB = Get-ModelSizeGB $name
    if ($null -eq $sizeGB) {
        Write-Warning "Could not look up size of '$name' from registry; defaulting to big. Override with -Backend small if needed."
        return "big"
    }

    $target = if ($sizeGB -gt $ThresholdGB) { "big" } else { "small" }
    Write-Host "[$name] registry size: $sizeGB GB (threshold: $ThresholdGB GB) -> $target"
    return $target
}

function Find-ExistingBackend([string]$name) {
    $needle = Normalize-Name $name
    foreach ($b in @("big", "small")) {
        try {
            $r = Invoke-RestMethod -Uri "$($Backends[$b].url)/api/tags" -TimeoutSec 5
            if ($r.models | Where-Object { $_.name -eq $needle }) {
                return $b
            }
        } catch {}
    }
    return $null
}

function Resolve-ExistingBackend([string]$name) {
    if ($Backend -ne "auto") { return $Backend }
    $b = Find-ExistingBackend $name
    if (-not $b) { throw "Model '$name' not found on either backend. Pull it first or specify -Backend." }
    return $b
}

function Invoke-OnBackend($b, [string[]]$cmdArgs) {
    $c = $Backends[$b].container
    Write-Host "==> docker exec $c ollama $($cmdArgs -join ' ')" -ForegroundColor DarkGray
    & docker exec $c ollama @cmdArgs
}

switch ($Command) {

    "help" {
        Get-Help $PSCommandPath -Detailed
    }

    "pull" {
        if (-not $Model) { throw "Model name required: .\ollama.ps1 pull <model>" }
        $target = Resolve-PullBackend $Model
        Invoke-OnBackend $target @("pull", $Model)
    }

    "list" {
        foreach ($b in @("big", "small")) {
            Write-Host "=== $b ($($Backends[$b].container)) ===" -ForegroundColor Cyan
            Invoke-OnBackend $b @("list")
            Write-Host ""
        }
    }

    "ps" {
        foreach ($b in @("big", "small")) {
            Write-Host "=== $b loaded ===" -ForegroundColor Cyan
            Invoke-OnBackend $b @("ps")
            Write-Host ""
        }
    }

    "rm" {
        if (-not $Model) { throw "Model name required: .\ollama.ps1 rm <model>" }
        $target = Resolve-ExistingBackend $Model
        Invoke-OnBackend $target @("rm", $Model)
    }

    "stop" {
        if (-not $Model) { throw "Model name required: .\ollama.ps1 stop <model>" }
        $target = Resolve-ExistingBackend $Model
        Invoke-OnBackend $target @("stop", $Model)
    }

    "show" {
        if (-not $Model) { throw "Model name required: .\ollama.ps1 show <model>" }
        $target = Resolve-ExistingBackend $Model
        Invoke-OnBackend $target @("show", $Model)
    }

    "run" {
        if (-not $Model) { throw "Model name required: .\ollama.ps1 run <model>" }
        $target = Find-ExistingBackend $Model
        if (-not $target) {
            # Not pulled yet - pull first into the right backend, then run.
            $target = Resolve-PullBackend $Model
            Write-Host "Model not found on either backend. Pulling into '$target'..." -ForegroundColor Yellow
            Invoke-OnBackend $target @("pull", $Model)
        }
        $c = $Backends[$target].container
        Write-Host "==> docker exec -it $c ollama run $Model" -ForegroundColor DarkGray
        & docker exec -it $c ollama run $Model
    }

    "size" {
        if (-not $Model) { throw "Model name required: .\ollama.ps1 size <model>" }
        $sizeGB = Get-ModelSizeGB $Model
        if ($null -eq $sizeGB) {
            Write-Warning "Could not look up size of '$Model'."
        } else {
            Write-Host "$Model -> $sizeGB GB on disk (threshold: $ThresholdGB GB)"
            Write-Host "Auto-route would pick: $(if ($sizeGB -gt $ThresholdGB) { 'big' } else { 'small' })"
        }
    }

    { $_ -in "start", "up" } {
        Write-Host "==> docker compose -f $ComposeFile up -d --build --remove-orphans --wait" -ForegroundColor DarkGray
        & docker compose -f $ComposeFile up -d --build --remove-orphans --wait
        if ($LASTEXITCODE -ne 0) {
            throw "docker compose up failed (exit $LASTEXITCODE). Stack is not ready; not opening browser."
        }
        Write-Host "All containers healthy. Opening $WebUiUrl ..." -ForegroundColor Green
        Start-Process $WebUiUrl
    }
}
