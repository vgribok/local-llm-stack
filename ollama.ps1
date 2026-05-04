<#
.SYNOPSIS
    Cross-platform wrapper for the ai-stack Ollama setup.

.DESCRIPTION
    On Windows (PC): Routes Ollama operations to Docker containers (ollama-big / ollama-small)
    based on model size. Big models (> ThresholdGB) -> ollama-big, small/embedding -> ollama-small.

    On macOS: Ollama runs on bare metal; all operations use the native `ollama` CLI directly.
    The Docker stack (think-router, open-webui) connects to host Ollama via host.docker.internal.

.EXAMPLE
    ./ollama.ps1 pull qwen3:32b           # PC: auto -> big; Mac: direct pull
    ./ollama.ps1 pull granite4.1:1b       # PC: auto -> small; Mac: direct pull
    ./ollama.ps1 list                     # list models (both backends on PC, single on Mac)
    ./ollama.ps1 ps                       # show loaded models
    ./ollama.ps1 rm granite4.1:3b         # delete model from disk
    ./ollama.ps1 stop qwen3.6:27b         # unload from VRAM
    ./ollama.ps1 run granite4.1:3b        # interactive chat
    ./ollama.ps1 size qwen3:32b           # check registry size without pulling
    ./ollama.ps1 start                    # docker compose up, wait healthy, open OWUI
    ./ollama.ps1 up                       # synonym for 'start'
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [ValidateSet("pull", "list", "ps", "rm", "stop", "show", "run", "size", "start", "up", "help")]
    [string]$Command,

    [Parameter(Position = 1)]
    [string]$Model,

    [ValidateSet("big", "small", "auto")]
    [string]$Backend = "auto",

    # Models with on-disk size > this go to big; otherwise small. (PC only)
    [double]$ThresholdGB = 8
)

$ErrorActionPreference = "Stop"

#region Platform Detection & Configuration

$Platform = if ($IsMacOS) { "mac" } elseif ($IsWindows -or $env:OS -eq "Windows_NT") { "pc" } else { "pc" }

# Platform-specific configuration
$PlatformConfig = @{
    mac = @{
        ComposeFiles    = @("docker-compose.yml", "docker-compose.mac.yml")
        WebUiUrl        = "http://localhost:3001"
        ThinkRouterUrl  = "http://localhost:11435"
        # Single backend - all models in one place
        Backends        = @{
            default = @{ url = "http://localhost:11434" }
        }
        # On Mac, Ollama runs on bare metal
        UsesDocker      = $false
    }
    pc  = @{
        ComposeFiles    = @("docker-compose.yml", "docker-compose.pc.yml")
        WebUiUrl        = "http://localhost:3001"
        ThinkRouterUrl  = "http://localhost:11434"
        # Dual backends - big GPU and small GPU
        Backends        = @{
            big   = @{ container = "ai-stack-ollama-big-1"; url = "http://localhost:3003" }
            small = @{ container = "ai-stack-ollama-small-1"; url = "http://localhost:3004" }
        }
        # On PC, Ollama runs in Docker containers
        UsesDocker      = $true
    }
}

$Config = $PlatformConfig[$Platform]

#endregion

#region Helper Functions

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
    }
    catch {
        return $null
    }
}

function Invoke-Ollama {
    <#
    .SYNOPSIS
        Execute an Ollama command, routing to the correct backend based on platform.
    .PARAMETER BackendKey
        On PC: 'big' or 'small'. On Mac: ignored (uses native CLI).
    .PARAMETER Arguments
        Arguments to pass to ollama.
    .PARAMETER Interactive
        If true, uses docker exec -it for interactive sessions (PC only).
    #>
    param(
        [string]$BackendKey = "default",
        [string[]]$Arguments,
        [switch]$Interactive
    )

    if ($Config.UsesDocker) {
        # PC: route to Docker container
        $container = $Config.Backends[$BackendKey].container
        $execArgs = if ($Interactive) { @("-it") } else { @() }
        Write-Host "==> docker exec $execArgs $container ollama $($Arguments -join ' ')" -ForegroundColor DarkGray
        & docker exec @execArgs $container ollama @Arguments
    }
    else {
        # Mac: direct CLI
        Write-Host "==> ollama $($Arguments -join ' ')" -ForegroundColor DarkGray
        & ollama @Arguments
    }
}

function Get-OllamaModels([string]$BackendKey) {
    <#
    .SYNOPSIS
        Get list of models from a backend via API.
    #>
    $url = $Config.Backends[$BackendKey].url
    try {
        $r = Invoke-RestMethod -Uri "$url/api/tags" -TimeoutSec 5
        return $r.models
    }
    catch {
        return @()
    }
}

function Find-ModelBackend([string]$name) {
    <#
    .SYNOPSIS
        Find which backend has a model. Returns backend key or $null.
    #>
    $needle = Normalize-Name $name

    foreach ($key in $Config.Backends.Keys) {
        $models = Get-OllamaModels $key
        if ($models | Where-Object { $_.name -eq $needle }) {
            return $key
        }
    }
    return $null
}

function Resolve-PullBackend([string]$name) {
    <#
    .SYNOPSIS
        Determine which backend to pull a model to. PC only - uses size heuristics.
    #>
    if (-not $Config.UsesDocker) {
        return "default"
    }

    if ($Backend -ne "auto") { return $Backend }

    # Embedding / reranker models always go to small
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

function Resolve-ExistingBackend([string]$name) {
    <#
    .SYNOPSIS
        Find which backend has an existing model, or throw if not found.
    #>
    if (-not $Config.UsesDocker) {
        return "default"
    }

    if ($Backend -ne "auto") { return $Backend }

    $found = Find-ModelBackend $name
    if (-not $found) {
        throw "Model '$name' not found on either backend. Pull it first or specify -Backend."
    }
    return $found
}

function Start-Stack {
    <#
    .SYNOPSIS
        Start the Docker Compose stack with platform-appropriate compose files.
    #>
    $composeArgs = @()
    foreach ($f in $Config.ComposeFiles) {
        $composeArgs += @("-f", (Join-Path $PSScriptRoot $f))
    }

    Write-Host "==> docker compose $($composeArgs -join ' ') up -d --build --remove-orphans --wait" -ForegroundColor DarkGray
    & docker compose @composeArgs up -d --build --remove-orphans --wait

    if ($LASTEXITCODE -ne 0) {
        throw "docker compose up failed (exit $LASTEXITCODE). Stack is not ready; not opening browser."
    }

    Write-Host "All containers healthy. Opening $($Config.WebUiUrl) ..." -ForegroundColor Green

    # Cross-platform browser open
    if ($IsMacOS) {
        & open $Config.WebUiUrl
    }
    else {
        Start-Process $Config.WebUiUrl
    }
}

#endregion

#region Command Handlers

switch ($Command) {

    "help" {
        Get-Help $PSCommandPath -Detailed
    }

    "pull" {
        if (-not $Model) { throw "Model name required: ./ollama.ps1 pull <model>" }
        $target = Resolve-PullBackend $Model
        Invoke-Ollama -BackendKey $target -Arguments @("pull", $Model)
    }

    "list" {
        if ($Config.UsesDocker) {
            # PC: show both backends
            foreach ($key in @("big", "small")) {
                Write-Host "=== $key ($($Config.Backends[$key].container)) ===" -ForegroundColor Cyan
                Invoke-Ollama -BackendKey $key -Arguments @("list")
                Write-Host ""
            }
        }
        else {
            # Mac: single backend
            Invoke-Ollama -Arguments @("list")
        }
    }

    "ps" {
        if ($Config.UsesDocker) {
            # PC: show both backends
            foreach ($key in @("big", "small")) {
                Write-Host "=== $key loaded ===" -ForegroundColor Cyan
                Invoke-Ollama -BackendKey $key -Arguments @("ps")
                Write-Host ""
            }
        }
        else {
            # Mac: single backend
            Invoke-Ollama -Arguments @("ps")
        }
    }

    "rm" {
        if (-not $Model) { throw "Model name required: ./ollama.ps1 rm <model>" }
        $target = Resolve-ExistingBackend $Model
        Invoke-Ollama -BackendKey $target -Arguments @("rm", $Model)
    }

    "stop" {
        if (-not $Model) { throw "Model name required: ./ollama.ps1 stop <model>" }
        $target = Resolve-ExistingBackend $Model
        Invoke-Ollama -BackendKey $target -Arguments @("stop", $Model)
    }

    "show" {
        if (-not $Model) { throw "Model name required: ./ollama.ps1 show <model>" }
        $target = Resolve-ExistingBackend $Model
        Invoke-Ollama -BackendKey $target -Arguments @("show", $Model)
    }

    "run" {
        if (-not $Model) { throw "Model name required: ./ollama.ps1 run <model>" }

        if ($Config.UsesDocker) {
            # PC: find or pull, then run interactively
            $target = Find-ModelBackend $Model
            if (-not $target) {
                $target = Resolve-PullBackend $Model
                Write-Host "Model not found on either backend. Pulling into '$target'..." -ForegroundColor Yellow
                Invoke-Ollama -BackendKey $target -Arguments @("pull", $Model)
            }
            Invoke-Ollama -BackendKey $target -Arguments @("run", $Model) -Interactive
        }
        else {
            # Mac: direct run (ollama will pull if needed)
            Invoke-Ollama -Arguments @("run", $Model) -Interactive
        }
    }

    "size" {
        if (-not $Model) { throw "Model name required: ./ollama.ps1 size <model>" }
        $sizeGB = Get-ModelSizeGB $Model
        if ($null -eq $sizeGB) {
            Write-Warning "Could not look up size of '$Model'."
        }
        else {
            Write-Host "$Model -> $sizeGB GB on disk"
            if ($Config.UsesDocker) {
                Write-Host "Auto-route would pick: $(if ($sizeGB -gt $ThresholdGB) { 'big' } else { 'small' }) (threshold: $ThresholdGB GB)"
            }
        }
    }

    { $_ -in "start", "up" } {
        Start-Stack
    }
}

#endregion