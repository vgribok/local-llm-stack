<#
.SYNOPSIS
    Run local validation for ai-stack without starting or stopping services.
#>

[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"

function Invoke-Checked {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Label,

        [Parameter(Mandatory = $true)]
        [scriptblock]$Command
    )

    Write-Host "==> $Label" -ForegroundColor Cyan
    & $Command
    if ($LASTEXITCODE -ne 0) {
        throw "$Label failed (exit $LASTEXITCODE)."
    }
}

Push-Location $PSScriptRoot
try {
    $parseErrors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile(
        (Join-Path $PSScriptRoot "ollama.ps1"),
        [ref]$null,
        [ref]$parseErrors
    )
    if ($parseErrors.Count -gt 0) {
        throw "ollama.ps1 parse failed: $($parseErrors -join [Environment]::NewLine)"
    }
    Write-Host "==> PowerShell syntax" -ForegroundColor Cyan
    Write-Host "ollama.ps1 parsed successfully."

    $python = if (Get-Command python -ErrorAction SilentlyContinue) {
        "python"
    }
    elseif (Get-Command python3 -ErrorAction SilentlyContinue) {
        "python3"
    }
    else {
        throw "Python was not found on PATH."
    }

    Invoke-Checked "think-router unit tests" {
        & $python -m unittest discover -s think-router -p "test_*.py"
    }
    Invoke-Checked "think-router syntax" {
        & $python -m py_compile think-router/app.py
    }

    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
        throw "Docker was not found on PATH."
    }

    $envArgs = @()
    $localEnvPath = Join-Path $PSScriptRoot ".env"
    if (Test-Path -LiteralPath $localEnvPath) {
        $envArgs += @("--env-file", $localEnvPath)
    }
    $envArgs += @("--env-file", (Join-Path $PSScriptRoot "image-pins.env"))

    $overlays = @(
        "docker-compose.pc-dual.yml",
        "docker-compose.pc-single.yml",
        "docker-compose.bare-metal.yml"
    )
    foreach ($overlay in $overlays) {
        Invoke-Checked "Compose config: $overlay" {
            & docker compose @envArgs -f (Join-Path $PSScriptRoot "docker-compose.yml") -f (Join-Path $PSScriptRoot $overlay) config --quiet
        }
    }

    Write-Host "All validation passed." -ForegroundColor Green
}
finally {
    Pop-Location
}
