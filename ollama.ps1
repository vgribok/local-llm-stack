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
    [Parameter(Position = 0)]
    [string]$Command,

    [Parameter(Position = 1)]
    [string]$Model,

    [ValidateSet("big", "small", "auto")]
    [string]$Backend = "auto",

    # Models with on-disk size > this go to big; otherwise small. (PC dual-GPU only)
    [double]$ThresholdGB = 8
)

$ErrorActionPreference = "Stop"

$ImagePinsPath = Join-Path $PSScriptRoot "image-pins.env"
if (-not (Test-Path -LiteralPath $ImagePinsPath)) {
    throw "Image pins file not found: $ImagePinsPath"
}

$ImagePins = @{}
foreach ($line in Get-Content -LiteralPath $ImagePinsPath) {
    $trimmedLine = $line.Trim()
    if ($trimmedLine -eq "" -or $trimmedLine.StartsWith("#")) {
        continue
    }

    $name, $value = $trimmedLine -split "=", 2
    if ($name -and $value) {
        $ImagePins[$name.Trim()] = $value.Trim()
    }
}

foreach ($name in @("OLLAMA_IMAGE", "OPEN_WEBUI_IMAGE")) {
    if ($ImagePins[$name] -notmatch "^[^@\s]+@sha256:[a-f0-9]{64}$") {
        throw "Missing or invalid $name in $ImagePinsPath"
    }
}

$OllamaImageRef = $ImagePins["OLLAMA_IMAGE"]
$OpenWebUIImageRef = $ImagePins["OPEN_WEBUI_IMAGE"]
$OllamaImageDigest = ($OllamaImageRef -split "@", 2)[1]
$OpenWebUIImageDigest = ($OpenWebUIImageRef -split "@", 2)[1]

$ValidCommands = @("pull", "list", "ps", "rm", "stop", "show", "run", "size", "version", "start", "up", "diag", "help")
$CommandDescriptions = [ordered]@{
    pull    = "Pull a model (auto-routed to backend when applicable)."
    list    = "List installed models across backend(s)."
    ps      = "Show currently loaded/running models."
    rm      = "Delete a model from disk."
    stop    = "Unload a model from memory/VRAM."
    show    = "Show metadata/details for a model."
    run     = "Run interactive chat with a model (pulls first if needed)."
    size    = "Query registry size for a model (without pulling)."
    version = "Show Ollama version per backend."
    start   = "Start stack with selected compose files and diagnostics."
    up      = "Alias for start."
    diag    = "Run loopback/native-conflict diagnostics."
    help    = "Show this help with command reference."
}

function Show-AvailableCommands {
    param([switch]$WithDescriptions)

    Write-Host "Available commands:" -ForegroundColor Cyan
    foreach ($c in $ValidCommands) {
        if ($WithDescriptions) {
            Write-Host ("  {0,-8} {1}" -f $c, $CommandDescriptions[$c])
        }
        else {
            Write-Host "  - $c"
        }
    }
}

function Show-WrapperHelp {
    Write-Host "NAME"
    Write-Host "    ollama.ps1"
    Write-Host ""

    Write-Host "SYNOPSIS"
    Write-Host "    Cross-platform wrapper for the ai-stack Ollama setup."
    Write-Host ""

    Write-Host "SYNTAX"
    Write-Host "    ./ollama.ps1 [command] [model] [-Backend big|small|auto] [-ThresholdGB <number>]"
    Write-Host ""

    Write-Host "DESCRIPTION"
    Write-Host "    Auto-selects platform mode (dual/single Docker backend or bare-metal)"
    Write-Host "    and provides unified commands for model and stack operations."
    Write-Host ""

    Write-Host "PARAMETERS"
    Write-Host "    Command      Operation to execute. If omitted, script prompts interactively."
    Write-Host "    Model        Model name for model-specific commands (pull/rm/show/run/etc.)."
    Write-Host "    -Backend     Force backend target (big|small|auto) where supported."
    Write-Host "    -ThresholdGB Size threshold used by auto-routing in dual-GPU mode."
    Write-Host ""

    Write-Host "COMMANDS"
    Show-AvailableCommands -WithDescriptions
    Write-Host ""

    Write-Host "EXAMPLES"
    Write-Host "    ./ollama.ps1 start"
    Write-Host "    ./ollama.ps1 list"
    Write-Host "    ./ollama.ps1 pull qwen3.6:27b"
    Write-Host "    ./ollama.ps1 diag   # loopback/native-conflict diagnostics"
    Write-Host ""
}

if ([string]::IsNullOrWhiteSpace($Command)) {
    Show-WrapperHelp

    do {
        $Command = (Read-Host "Enter command").Trim().ToLowerInvariant()
    } while ([string]::IsNullOrWhiteSpace($Command))
}

$Command = $Command.Trim().ToLowerInvariant()
if ($Command -notin $ValidCommands) {
    throw "Invalid command '$Command'. Valid commands: $($ValidCommands -join ', ')"
}

if ($Command -eq "help") {
    Show-WrapperHelp
    return
}

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
        Write-Host "  2) !!! STOP whichever duplicate/NATIVE Ollama/Router service is unintentionally bound on the same port." !!!
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

function Get-DockerServerPlatform {
    <#
    .SYNOPSIS
        Return Docker server platform (os/arch), normalized for manifest matching.
    #>
    try {
        $platformRaw = (& docker version --format "{{.Server.Os}}/{{.Server.Arch}}" 2>$null)
        if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($platformRaw)) {
            return $null
        }

        $parts = $platformRaw.Trim().Split("/", 2)
        if ($parts.Count -ne 2) {
            return $null
        }

        $os = $parts[0].ToLowerInvariant()
        $arch = $parts[1].ToLowerInvariant()

        switch ($arch) {
            "x86_64" { $arch = "amd64" }
            "aarch64" { $arch = "arm64" }
        }

        return [pscustomobject]@{
            Os   = $os
            Arch = $arch
        }
    }
    catch {
        return $null
    }
}

function Get-LocalImageDigest {
    <#
    .SYNOPSIS
        Get the local repo digest (sha256:...) for an image repository if pulled.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Repository,

        [Parameter(Mandatory = $true)]
        [string]$Tag
    )

    $imageRef = "${Repository}:${Tag}"

    try {
        $repoDigestsJson = (& docker image inspect --format "{{json .RepoDigests}}" $imageRef 2>$null)
        if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($repoDigestsJson)) {
            return $null
        }

        $repoDigests = @($repoDigestsJson | ConvertFrom-Json)
        if ($repoDigests.Count -eq 0) {
            return $null
        }

        $match = $repoDigests | Where-Object { $_ -like "${Repository}@*" } | Select-Object -First 1
        if (-not $match) {
            # Fallback: if repo prefix differs unexpectedly, still use first digest entry.
            $match = $repoDigests | Select-Object -First 1
        }

        if ($match -notlike "*@*") {
            return $null
        }

        return (($match -split "@", 2)[1])
    }
    catch {
        return $null
    }
}

function Get-RemoteImageDigest {
    <#
    .SYNOPSIS
        Get remote tag/index digest (sha256:...) for an image tag.
        This matches Docker local RepoDigests semantics (repo:tag@sha256:<index-or-manifest-digest>).
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Repository,

        [Parameter(Mandatory = $true)]
        [string]$Tag,

        [Parameter(Mandatory = $false)]
        [string]$PlatformOs,

        [Parameter(Mandatory = $false)]
        [string]$PlatformArch
    )

    $imageRef = "${Repository}:${Tag}"

    try {
        # Preferred: Docker imagetools reports the tag/index digest directly:
        #   Digest: sha256:<...>
        # This is the same digest Docker records in local RepoDigests.
        $inspectText = (& docker buildx imagetools inspect $imageRef 2>$null | Out-String)
        if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($inspectText)) {
            $m = [regex]::Match($inspectText, "(?m)^Digest:\s*(sha256:[a-f0-9]{64})\s*$")
            if ($m.Success) {
                return $m.Groups[1].Value
            }
        }

        # Fallback: try docker manifest inspect (less preferred here, but keeps compatibility).
        # This path may not always expose tag/index digest; when unavailable we return $null.
        $manifestJson = (& docker manifest inspect $imageRef 2>$null | Out-String)
        if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($manifestJson)) {
            return $null
        }

        $manifestRaw = $manifestJson | ConvertFrom-Json

        # Rarely, some responses include an explicit digest property.
        if ($manifestRaw -and $manifestRaw.digest) {
            return [string]$manifestRaw.digest
        }

        return $null
    }
    catch {
        return $null
    }
}

function Invoke-ImageFreshnessDiagnostics {
    <#
    .SYNOPSIS
        Warn when pulled Docker images are older than the current remote tag digest.
    #>
    if (-not $Config.UsesDocker) {
        Write-Host "Image diagnostics: skipped (current mode is non-Docker backend)." -ForegroundColor DarkGray
        return
    }

    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
        Write-Host "Image diagnostics: docker CLI not found; skipping image freshness checks." -ForegroundColor DarkGray
        return
    }

    $platform = Get-DockerServerPlatform
    if (-not $platform) {
        Write-Host "Image diagnostics: could not determine Docker server platform; skipping image freshness checks." -ForegroundColor DarkGray
        return
    }

    $imageTargets = @()
    $imageTargets += [pscustomobject]@{
        Label          = "Ollama"
        Repository     = "ollama/ollama"
        PinnedRef      = $OllamaImageRef
        ExpectedDigest = $OllamaImageDigest
    }
    $imageTargets += [pscustomobject]@{
        Label          = "Open WebUI"
        Repository     = "ghcr.io/open-webui/open-webui"
        PinnedRef      = $OpenWebUIImageRef
        ExpectedDigest = $OpenWebUIImageDigest
    }

    foreach ($img in $imageTargets) {
        $localDigest = $null
        try {
            $repoDigestsJson = (& docker image inspect --format "{{json .RepoDigests}}" $img.PinnedRef 2>$null)
            if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($repoDigestsJson)) {
                $repoDigests = @($repoDigestsJson | ConvertFrom-Json)
                $match = $repoDigests | Where-Object { $_ -like "$($img.Repository)@*" } | Select-Object -First 1
                if (-not $match) {
                    $match = $repoDigests | Select-Object -First 1
                }
                if ($match -like "*@*") {
                    $localDigest = (($match -split "@", 2)[1])
                }
            }
        }
        catch {
            $localDigest = $null
        }

        if (-not $localDigest) {
            Write-Warning "Image diagnostics: pinned $($img.Label) image is not pulled locally ($($img.PinnedRef))."
            Write-Host "Pull pinned image: docker pull $($img.PinnedRef)" -ForegroundColor Yellow
            continue
        }

        if ($localDigest -ne $img.ExpectedDigest) {
            Write-Warning "$($img.Label) image digest differs from pinned version: local $localDigest != expected $($img.ExpectedDigest)"
            Write-Host "Update with pinned image: docker pull $($img.PinnedRef)" -ForegroundColor Yellow

            $serviceRefreshHint = switch ($img.Label) {
                "Ollama" {
                    if ($Config.BackendOrder.Count -gt 1) {
                        "docker compose up -d --no-deps ollama-big ollama-small"
                    }
                    else {
                        "docker compose up -d --no-deps ollama-big"
                    }
                }
                "Open WebUI" { "docker compose up -d --no-deps open-webui" }
                default { $null }
            }

            if ($serviceRefreshHint) {
                Write-Host "Less disruptive apply: $serviceRefreshHint" -ForegroundColor DarkYellow
            }

            Write-Host "Fallback/full refresh: ./ollama.ps1 start" -ForegroundColor Yellow
        }
        else {
            Write-Host "Image diagnostics: $($img.Label) image matches pinned digest ($localDigest)." -ForegroundColor DarkGray
        }
    }
}

function Invoke-SharedDiagnostics {
    <#
    .SYNOPSIS
        Shared diagnostics for both `diag` and `start`.
    #>
    param()

    $portsToCheck = Get-DiagnosticPorts
    $routerPort = ([uri]$Config.ThinkRouterUrl).Port

    Invoke-LoopbackDiagnostics -Ports $portsToCheck
    Test-NativeOllamaConflictOnPort -Port $routerPort | Out-Null

}

function Start-Stack {
    <#
    .SYNOPSIS
        Start the Docker Compose stack with platform-appropriate compose files.
    #>
    Write-Host "Running preflight loopback diagnostics..." -ForegroundColor DarkGray
    Invoke-SharedDiagnostics

    $composeArgs = @()
    $localEnvPath = Join-Path $PSScriptRoot ".env"
    if (Test-Path -LiteralPath $localEnvPath) {
        $composeArgs += @("--env-file", $localEnvPath)
    }
    $composeArgs += @("--env-file", $ImagePinsPath)

    foreach ($f in $Config.ComposeFiles) {
        $composeArgs += @("-f", (Join-Path $PSScriptRoot $f))
    }

    Write-Host "==> docker compose $($composeArgs -join ' ') up -d --build --remove-orphans --wait" -ForegroundColor DarkGray
    & docker compose @composeArgs up -d --build --remove-orphans --wait

    if ($LASTEXITCODE -ne 0) {
        throw "docker compose up failed (exit $LASTEXITCODE). Stack is not ready; not opening browser."
    }

    Write-Host "Running post-start loopback diagnostics..." -ForegroundColor DarkGray
    Invoke-SharedDiagnostics

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
        Show-WrapperHelp
    }

    "diag" {
        Invoke-SharedDiagnostics
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
