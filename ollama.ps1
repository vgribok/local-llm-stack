<#
.SYNOPSIS
    Cross-platform wrapper for the ai-stack Ollama setup.

.DESCRIPTION
    On Windows (PC): selects a backend configuration automatically:
      - 2+ NVIDIA GPUs               -> dual-GPU Docker containers (ollama-big / ollama-small)
      - Ollama already on :11434      -> bare-metal overlay (any GPU vendor; think-router on :11435)
      - 1 NVIDIA GPU, no bare-metal  -> single-GPU Docker container (ollama-big; think-router on :11434)

    On macOS: Ollama always runs on bare metal; uses the bare-metal overlay (think-router on :11435).
    The Docker stack (think-router, open-webui) connects to host Ollama via host.docker.internal.

.EXAMPLE
    ./ollama.ps1 pull qwen3:32b           # Docker PC: auto-routed by size; bare-metal/Mac: direct pull
    ./ollama.ps1 pull granite4.1:1b       # dual-GPU Docker: -> small; single-GPU Docker: -> big; bare-metal/Mac: direct
    ./ollama.ps1 list                     # list models (all backends)
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
    [ValidateSet("pull", "list", "ps", "rm", "stop", "show", "run", "size", "version", "start", "up", "diag", "help")]
    [string]$Command,

    [Parameter(Position = 1)]
    [string]$Model,

    [ValidateSet("big", "small", "auto")]
    [string]$Backend = "auto",

    # Models with on-disk size > this go to big; otherwise small. (PC dual-GPU only)
    [double]$ThresholdGB = 8
)

$ErrorActionPreference = "Stop"

#region Platform Detection & Configuration

$Platform = if ($IsMacOS) { "mac" } elseif ($IsWindows -or $env:OS -eq "Windows_NT") { "pc" } else { "pc" }

# Detect NVIDIA GPU count (PC only; stays 0 if nvidia-smi unavailable)
$GpuCount = 0
if ($Platform -eq "pc") {
    try {
        $gpuLines = & nvidia-smi --query-gpu=name --format=csv,noheader 2>$null
        if ($LASTEXITCODE -eq 0) {
            $GpuCount = @($gpuLines | Where-Object { $_.Trim() -ne "" }).Count
        }
    }
    catch { }
}

# Check for bare-metal Ollama on the host (PC only; skipped for dual-GPU for speed)
$OllamaRunning = $false
if ($Platform -eq "pc" -and $GpuCount -lt 2) {
    try {
        $null = Invoke-RestMethod -Uri "http://localhost:11434/api/tags" -TimeoutSec 2
        $OllamaRunning = $true
    }
    catch { }
}

$bareMetalConfig = @{
    ComposeFiles   = @("docker-compose.yml", "docker-compose.bare-metal.yml")
    WebUiUrl       = "http://localhost:3001"
    ThinkRouterUrl = "http://localhost:11435"
    Backends       = @{
        default = @{ url = "http://localhost:11434" }
    }
    BackendOrder   = @("default")
    UsesDocker     = $false
}

$pcSingleConfig = @{
    ComposeFiles   = @("docker-compose.yml", "docker-compose.pc-single.yml")
    WebUiUrl       = "http://localhost:3001"
    ThinkRouterUrl = "http://localhost:11434"
    Backends       = @{
        big = @{ container = "ai-stack-ollama-big-1"; url = "http://localhost:3003" }
    }
    BackendOrder   = @("big")
    UsesDocker     = $true
}

$pcDualConfig = @{
    ComposeFiles   = @("docker-compose.yml", "docker-compose.pc-dual.yml")
    WebUiUrl       = "http://localhost:3001"
    ThinkRouterUrl = "http://localhost:11434"
    Backends       = @{
        big   = @{ container = "ai-stack-ollama-big-1"; url = "http://localhost:3003" }
        small = @{ container = "ai-stack-ollama-small-1"; url = "http://localhost:3004" }
    }
    BackendOrder   = @("big", "small")
    UsesDocker     = $true
}

# PC config: dual GPU wins, then bare-metal Ollama (any vendor), then single NVIDIA GPU
$pcConfig = $null
if ($Platform -eq "pc") {
    $configMode = if     ($GpuCount -ge 2)  { "dual" }
                  elseif ($OllamaRunning)    { "bare-metal" }
                  elseif ($GpuCount -eq 1)  { "single" }
                  else                       { "error" }

    if ($configMode -eq "error") {
        Write-Error "No NVIDIA GPU detected and Ollama is not running on localhost:11434. Install NVIDIA drivers or start Ollama, then retry."
        exit 1
    }

    $pcConfig = switch ($configMode) {
        "dual"       { $pcDualConfig }
        "bare-metal" { $bareMetalConfig }
        "single"     { $pcSingleConfig }
    }

    $configLabel = switch ($configMode) {
        "dual"       { "$GpuCount GPUs detected -> dual-GPU config" }
        "bare-metal" { "Ollama on localhost:11434 -> bare-metal config (think-router on :11435)" }
        "single"     { "1 GPU detected, no bare-metal Ollama -> single-GPU config" }
    }
    Write-Host $configLabel -ForegroundColor DarkGray
}

$PlatformConfig = @{
    mac = $bareMetalConfig
    pc  = $pcConfig
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

    if ($Backend -ne "auto") {
        if (-not $Config.Backends.ContainsKey($Backend)) {
            throw "Backend '$Backend' is not available. Available: $($Config.Backends.Keys -join ', ')"
        }
        return $Backend
    }

    # Single-backend mode: all models go to the only available backend
    if ($Config.BackendOrder.Count -eq 1) { return $Config.BackendOrder[0] }

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

    if ($Backend -ne "auto") {
        if (-not $Config.Backends.ContainsKey($Backend)) {
            throw "Backend '$Backend' is not available. Available: $($Config.Backends.Keys -join ', ')"
        }
        return $Backend
    }

    $found = Find-ModelBackend $name
    if (-not $found) {
        throw "Model '$name' not found on either backend. Pull it first or specify -Backend."
    }
    return $found
}

function Get-EndpointProbe([string]$BaseUrl) {
    <#
    .SYNOPSIS
        Probe an Ollama-compatible endpoint and return version/server/model-count details.
    #>
    $versionUrl = "$BaseUrl/api/version"
    $tagsUrl = "$BaseUrl/api/tags"

    try {
        $versionResp = Invoke-WebRequest -Uri $versionUrl -TimeoutSec 2

        $server = ""
        if ($versionResp.Headers["Server"]) {
            $server = [string]$versionResp.Headers["Server"]
        }

        $version = $null
        try {
            $version = (ConvertFrom-Json $versionResp.Content).version
        }
        catch { }

        $modelCount = $null
        try {
            $tags = Invoke-RestMethod -Uri $tagsUrl -TimeoutSec 2
            $modelCount = @($tags.models).Count
        }
        catch { }

        return [pscustomobject]@{
            BaseUrl    = $BaseUrl
            Reachable  = $true
            Version    = $version
            Server     = $server
            ModelCount = $modelCount
            Error      = ""
        }
    }
    catch {
        return [pscustomobject]@{
            BaseUrl    = $BaseUrl
            Reachable  = $false
            Version    = $null
            Server     = ""
            ModelCount = $null
            Error      = $_.Exception.Message
        }
    }
}

function Test-LoopbackPortConflict([int]$Port) {
    <#
    .SYNOPSIS
        Detect split-loopback conflicts where localhost/127.0.0.1/::1 on the same port
        resolve to different Ollama-compatible services.
    #>
    $targets = @(
        "http://localhost:$Port",
        "http://127.0.0.1:$Port",
        "http://[::1]:$Port"
    )

    $probes = foreach ($t in $targets) { Get-EndpointProbe $t }
    $reachable = @($probes | Where-Object { $_.Reachable })

    if ($reachable.Count -lt 2) {
        return $false
    }

    $fingerprints = @(
        $reachable | ForEach-Object {
            $v = if ($null -ne $_.Version) { [string]$_.Version } else { "<none>" }
            $s = if ([string]::IsNullOrWhiteSpace($_.Server)) { "<none>" } else { $_.Server }
            $m = if ($null -ne $_.ModelCount) { [string]$_.ModelCount } else { "<unknown>" }
            "$v|$s|$m"
        }
    )

    if ((@($fingerprints | Select-Object -Unique)).Count -gt 1) {
        Write-Warning "Detected loopback endpoint conflict on port ${Port}: localhost / 127.0.0.1 / ::1 are not equivalent."
        $reachable |
            Select-Object BaseUrl, Version, Server, ModelCount |
            Format-Table -AutoSize

        Write-Host "Remediation (cross-platform):" -ForegroundColor Yellow
        Write-Host "  1) Point all clients to a single canonical URL (recommended: http://localhost:$Port)."
        Write-Host "  2) Stop whichever duplicate Ollama/Router service is unintentionally bound on the same port."
        Write-Host "  3) If using CLI, set OLLAMA_HOST explicitly to that canonical URL."
        return $true
    }

    return $false
}

function Invoke-LoopbackDiagnostics([int[]]$Ports) {
    <#
    .SYNOPSIS
        Run split-loopback diagnostics across one or more ports.
    #>
    $uniquePorts = @($Ports | Sort-Object -Unique)
    if ($uniquePorts.Count -eq 0) {
        return
    }

    $conflicts = 0
    foreach ($port in $uniquePorts) {
        if (Test-LoopbackPortConflict -Port $port) {
            $conflicts++
        }
    }

    if ($conflicts -eq 0) {
        Write-Host "Loopback diagnostics: OK - no split-brain conflicts detected on tested ports ($($uniquePorts -join ', '))." -ForegroundColor DarkGray
    }
}

function Get-DiagnosticPorts {
    <#
    .SYNOPSIS
        Build the list of ports to probe from the active config (router + backend URLs).
    #>
    $ports = @()

    try {
        $ports += ([uri]$Config.ThinkRouterUrl).Port
    }
    catch { }

    foreach ($backend in $Config.Backends.Values) {
        if (-not $backend.url) { continue }
        try {
            $ports += ([uri]$backend.url).Port
        }
        catch { }
    }

    return @($ports | Where-Object { $_ -gt 0 } | Sort-Object -Unique)
}

function Test-NativeOllamaConflictOnPort([int]$Port) {
    <#
    .SYNOPSIS
        Dedicated guardrail for a common conflict: native Ollama bound on IPv4 loopback
        while think-router is reached via localhost/IPv6 on the same port.
    #>
    $localhostProbe = Get-EndpointProbe "http://localhost:$Port"
    $ipv4Probe = Get-EndpointProbe "http://127.0.0.1:$Port"

    if (-not ($localhostProbe.Reachable -and $ipv4Probe.Reachable)) {
        return $false
    }

    $localhostFp = "{0}|{1}|{2}" -f (
        $(if ($null -ne $localhostProbe.Version) { [string]$localhostProbe.Version } else { "<none>" }),
        $(if ([string]::IsNullOrWhiteSpace($localhostProbe.Server)) { "<none>" } else { $localhostProbe.Server }),
        $(if ($null -ne $localhostProbe.ModelCount) { [string]$localhostProbe.ModelCount } else { "<unknown>" })
    )

    $ipv4Fp = "{0}|{1}|{2}" -f (
        $(if ($null -ne $ipv4Probe.Version) { [string]$ipv4Probe.Version } else { "<none>" }),
        $(if ([string]::IsNullOrWhiteSpace($ipv4Probe.Server)) { "<none>" } else { $ipv4Probe.Server }),
        $(if ($null -ne $ipv4Probe.ModelCount) { [string]$ipv4Probe.ModelCount } else { "<unknown>" })
    )

    if ($localhostFp -eq $ipv4Fp) {
        return $false
    }

    Write-Warning "Native Ollama conflict check: localhost and 127.0.0.1 differ on port ${Port}."
    Write-Host "This usually means two Ollama-compatible services are bound to the same port (e.g., native Ollama + think-router)." -ForegroundColor Yellow

    @($localhostProbe, $ipv4Probe) |
        Select-Object BaseUrl, Version, Server, ModelCount |
        Format-Table -AutoSize

    Write-Host "Recommended action:" -ForegroundColor Yellow
    Write-Host "  - Keep only one intended service on port ${Port}."
    Write-Host "  - Point all clients/CLI to one canonical URL (recommended: http://localhost:${Port})."
    Write-Host "  - If needed, set OLLAMA_HOST explicitly for CLI sessions."

    return $true
}

function Start-Stack {
    <#
    .SYNOPSIS
        Start the Docker Compose stack with platform-appropriate compose files.
    #>
    $portsToCheck = Get-DiagnosticPorts
    $routerPort = ([uri]$Config.ThinkRouterUrl).Port

    Write-Host "Running preflight loopback diagnostics..." -ForegroundColor DarkGray
    Invoke-LoopbackDiagnostics -Ports $portsToCheck
    Test-NativeOllamaConflictOnPort -Port $routerPort | Out-Null

    $composeArgs = @()
    foreach ($f in $Config.ComposeFiles) {
        $composeArgs += @("-f", (Join-Path $PSScriptRoot $f))
    }

    Write-Host "==> docker compose $($composeArgs -join ' ') up -d --build --remove-orphans --wait" -ForegroundColor DarkGray
    & docker compose @composeArgs up -d --build --remove-orphans --wait

    if ($LASTEXITCODE -ne 0) {
        throw "docker compose up failed (exit $LASTEXITCODE). Stack is not ready; not opening browser."
    }

    Write-Host "Running post-start loopback diagnostics..." -ForegroundColor DarkGray
    Invoke-LoopbackDiagnostics -Ports $portsToCheck
    Test-NativeOllamaConflictOnPort -Port $routerPort | Out-Null

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

    "diag" {
        $portsToCheck = Get-DiagnosticPorts
        Invoke-LoopbackDiagnostics -Ports $portsToCheck
    }

    "version" {
        if ($Config.UsesDocker) {
            foreach ($key in $Config.BackendOrder) {
                Write-Host "=== $key version ===" -ForegroundColor Cyan
                Invoke-Ollama -BackendKey $key -Arguments @("--version")
                Write-Host ""
            }
        }
        else {
            Invoke-Ollama -Arguments @("--version")
        }
    }

    "pull" {
        if (-not $Model) { throw "Model name required: ./ollama.ps1 pull <model>" }
        $target = Resolve-PullBackend $Model
        Invoke-Ollama -BackendKey $target -Arguments @("pull", $Model)
    }

    "list" {
        if ($Config.UsesDocker) {
            foreach ($key in $Config.BackendOrder) {
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
            foreach ($key in $Config.BackendOrder) {
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
                if ($Config.BackendOrder.Count -gt 1) {
                    Write-Host "Auto-route would pick: $(if ($sizeGB -gt $ThresholdGB) { 'big' } else { 'small' }) (threshold: $ThresholdGB GB)"
                } else {
                    Write-Host "Single-GPU mode: would go to $($Config.BackendOrder[0])"
                }
            }
        }
    }

    { $_ -in "start", "up" } {
        Start-Stack
    }
}

#endregion