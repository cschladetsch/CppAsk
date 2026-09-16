<#
.SYNOPSIS
    Installs 'ask' to ~/bin and writes ~/.ask.json with sensible defaults.
 
.DESCRIPTION
    1. Copies ask.ps1 to the install directory (default: ~/bin)
    2. Adds the directory to user PATH permanently
    3. Adds a global 'ask' function + alias to $PROFILE
    4. Prompts for config values and writes ~/.ask.json
    5. Makes 'ask' available in the current session immediately
 
.PARAMETER Destination
    Directory to install into.  Default: ~/bin
 
.PARAMETER Force
    Overwrite existing files without prompting.
 
.EXAMPLE
    .\install.ps1
    .\install.ps1 -Destination C:\tools
    .\install.ps1 -Force
#>
param(
    [string] $Destination = (Join-Path $HOME "bin"),
    [switch] $Force
)
 
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
 
function Prompt-WithDefault([string]$msg, [string]$default) {
    $display = if ($default -ne "") { "$msg [$default]" } else { $msg }
    $ans = Read-Host $display
    if ([string]::IsNullOrWhiteSpace($ans)) { $default } else { $ans.Trim() }
}
 
function Prompt-YN([string]$msg, [bool]$defaultYes = $true) {
    $hint = if ($defaultYes) { "[Y/n]" } else { "[y/N]" }
    $ans = Read-Host "$msg $hint"
    if ([string]::IsNullOrWhiteSpace($ans)) { return $defaultYes }
    return $ans -match '^[Yy]'
}
 
# ── Banner ────────────────────────────────────────────────────────────────────
 
Write-Host ""
Write-Host "  ask installer" -ForegroundColor Cyan
Write-Host "  ─────────────────────────────────────────" -ForegroundColor DarkGray
Write-Host ""
 
# ── Verify source ─────────────────────────────────────────────────────────────
 
$src = Join-Path $PSScriptRoot "ask.ps1"
if (-not (Test-Path $src)) {
    Write-Error "ask.ps1 not found at $src -- run install.ps1 from the repo root."
    exit 1
}
 
# ── Install directory ─────────────────────────────────────────────────────────
 
if (-not (Test-Path $Destination)) {
    New-Item $Destination -ItemType Directory | Out-Null
    Write-Host "  Created $Destination" -ForegroundColor Cyan
}
 
$dest = Join-Path $Destination "ask.ps1"
if ((Test-Path $dest) -and -not $Force) {
    if (-not (Prompt-YN "  ask.ps1 already exists at $dest. Overwrite?")) {
        Write-Host "  Aborted." -ForegroundColor Yellow; exit 0
    }
}
Copy-Item $src $dest -Force
Write-Host "  Copied ask.ps1 -> $dest" -ForegroundColor Green
 
# ── PATH ──────────────────────────────────────────────────────────────────────
 
$userPath  = [Environment]::GetEnvironmentVariable("PATH", "User") ?? ""
$pathParts = $userPath -split ";" | Where-Object { $_ -ne "" }
 
if ($Destination -notin $pathParts) {
    [Environment]::SetEnvironmentVariable("PATH", ($pathParts + $Destination) -join ";", "User")
    Write-Host "  Added $Destination to user PATH." -ForegroundColor Green
} else {
    Write-Host "  $Destination already in PATH." -ForegroundColor DarkGray
}
 
if ($Destination -notin ($env:PATH -split ";")) {
    $env:PATH = "$env:PATH;$Destination"
}
 
# ── $PROFILE alias ────────────────────────────────────────────────────────────
 
$profileDir = Split-Path $PROFILE -Parent
if (-not (Test-Path $profileDir)) { New-Item $profileDir -ItemType Directory | Out-Null }
if (-not (Test-Path $PROFILE))    { New-Item $PROFILE    -ItemType File      | Out-Null }
 
$marker = "# CppAsk"
if (Select-String -Path $PROFILE -Pattern ([regex]::Escape($marker)) -Quiet) {
    Write-Host "  Profile already has ask entry." -ForegroundColor DarkGray
} elseif (Prompt-YN "  Add 'ask' alias to $PROFILE?") {
    $snippet = @"
 
$marker
function global:ask { & '$dest' @args }
Set-Alias -Name ask -Value global:ask -Scope Global -Option AllScope -Force
"@
    Add-Content $PROFILE $snippet
    Write-Host "  Added ask to $PROFILE" -ForegroundColor Green
}
 
Invoke-Expression "function global:ask { & '$dest' @args }"
Set-Alias -Name ask -Value global:ask -Scope Global -Option AllScope -Force
 
# ── ~/.ask.json config ────────────────────────────────────────────────────────
 
Write-Host ""
Write-Host "  Configuration  (~/.ask.json)" -ForegroundColor Cyan
Write-Host "  ─────────────────────────────────────────" -ForegroundColor DarkGray
Write-Host "  Press Enter to accept the default shown in [brackets]."
Write-Host ""
 
# Discover available Ollama models for the prompt hint
$modelHint = "dolphin-8b:latest"
try {
    $ollamaOut = & ollama list 2>$null | Select-Object -Skip 1
    $models = $ollamaOut | ForEach-Object { ($_ -split '\s+')[0] } | Where-Object { $_ -ne "" }
    if ($models.Count -gt 0) {
        Write-Host "  Available Ollama models:" -ForegroundColor DarkGray
        $models | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
        Write-Host ""
        # Prefer dolphin-8b if present, otherwise first in list
        $modelHint = if ($models -contains "dolphin-8b:latest") { "dolphin-8b:latest" } else { $models[0] }
    }
} catch {
    Write-Host "  (Could not query ollama list -- enter model name manually)" -ForegroundColor DarkGray
}
 
$cfgModel      = Prompt-WithDefault "  Default model      " $modelHint
$cfgHost       = Prompt-WithDefault "  Ollama host        " "127.0.0.1"
$cfgPortDirect = Prompt-WithDefault "  Ollama port        " "11434"
$cfgPortServe  = Prompt-WithDefault "  cppcoder port      " "8765"
$cfgSystem     = Prompt-WithDefault "  System prompt      " ""
 
$config = [ordered]@{
    model        = $cfgModel
    host         = $cfgHost
    port_direct  = [int]$cfgPortDirect
    port_serve   = [int]$cfgPortServe
    system       = $cfgSystem
}
 
$configPath = Join-Path $HOME ".ask.json"
$config | ConvertTo-Json | Set-Content $configPath
Write-Host ""
Write-Host "  Wrote $configPath" -ForegroundColor Green
 
# ── Done ──────────────────────────────────────────────────────────────────────
 
Write-Host ""
Write-Host "  Done. Try it now:" -ForegroundColor Cyan
Write-Host "    ask what is the rule of five"
Write-Host "    ask explain CRTP -Model $cfgModel"
Write-Host "    ask -SetModel qwen2.5-coder:7b"
Write-Host ""
Write-Host "  New shells: restart your terminal or run: . `$PROFILE" -ForegroundColor DarkGray
Write-Host ""