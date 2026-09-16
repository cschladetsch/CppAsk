<#
.SYNOPSIS
    Ask the local LLM a one-shot question, streaming the reply to stdout.
 
.DESCRIPTION
    Sends a question to Ollama's /api/chat (default) or a running cppcoder
    --serve instance.  Config is loaded from ~/.ask.json; any parameter
    passed on the command line overrides the config for that run.
 
.PARAMETER Question
    The question to ask.  Quotes optional -- unquoted words are joined.
    Can also be piped in.
 
.PARAMETER Model
    Ollama model tag.  Overrides config.
 
.PARAMETER OllamaHost
    Ollama hostname.  Overrides config.
 
.PARAMETER Port
    Ollama port.  Overrides config.
 
.PARAMETER Direct
    Talk straight to Ollama (default: true).  -Direct:$false routes via
    cppcoder --serve on port 8765.
 
.PARAMETER System
    System prompt prepended to the conversation.  Overrides config.
 
.PARAMETER NoStream
    Collect full reply before printing.
 
.PARAMETER SetModel
    Persist a new default model to ~/.ask.json, then exit.
    Example: ask -SetModel qwen2.5-coder:7b
 
.EXAMPLE
    ask what is 1+2
    ask explain CRTP in modern C++
    ask what does PatchApplier do -Model codellama:7b
    ask -SetModel dolphin-8b:latest
#>
 
[CmdletBinding()]
param(
    [Parameter(Position = 0, ValueFromPipeline = $true, ValueFromRemainingArguments = $true)]
    [string[]] $Question,
 
    [string] $Model       = "",
    [string] $OllamaHost  = "",
    [int]    $Port        = 0,
    [switch] $Direct      = $true,
    [string] $System      = "",
    [switch] $NoStream,
    [string] $SetModel    = ""
)
 
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
 
# ── Load ~/.ask.json ──────────────────────────────────────────────────────────
 
$configPath = Join-Path $HOME ".ask.json"
 
$defaults = @{
    model      = "dolphin-8b:latest"
    host       = "127.0.0.1"
    port_direct = 11434
    port_serve  = 8765
    system     = ""
}
 
if (Test-Path $configPath) {
    try {
        $saved = Get-Content $configPath -Raw | ConvertFrom-Json
        foreach ($key in $defaults.Keys) {
            if ($null -ne $saved.$key) { $defaults[$key] = $saved.$key }
        }
    } catch {
        Write-Warning "Could not parse ${configPath}: $_"
    }
}
 
# ── Handle -SetModel ──────────────────────────────────────────────────────────
 
if ($SetModel -ne "") {
    $defaults["model"] = $SetModel
    $defaults | ConvertTo-Json | Set-Content $configPath
    Write-Host "Default model set to '$SetModel' in $configPath" -ForegroundColor Green
    return
}
 
# ── Require a question ────────────────────────────────────────────────────────
 
if (-not $Question) {
    Write-Error "No question provided. Usage: ask what is the rule of five"
    exit 1
}
 
# ── Resolve effective settings (CLI overrides config) ─────────────────────────
 
$effectiveModel  = if ($Model      -ne "") { $Model     } else { $defaults["model"]  }
$effectiveHost   = if ($OllamaHost -ne "") { $OllamaHost} else { $defaults["host"]   }
$effectiveSystem = if ($System     -ne "") { $System    } else { $defaults["system"] }
 
$effectivePort = if ($Port -ne 0) {
    $Port
} elseif ($Direct) {
    $defaults["port_direct"]
} else {
    $defaults["port_serve"]
}
 
$url = "http://${effectiveHost}:${effectivePort}/api/chat"
 
# ── Build request ─────────────────────────────────────────────────────────────
 
$questionText = $Question -join " "
 
$messages = @()
if ($effectiveSystem -ne "") {
    $messages += @{ role = "system"; content = $effectiveSystem }
}
$messages += @{ role = "user"; content = $questionText }
 
$body = @{
    model    = $effectiveModel
    messages = $messages
    stream   = -not $NoStream.IsPresent
} | ConvertTo-Json -Depth 5 -Compress
 
# ── Send ──────────────────────────────────────────────────────────────────────
 
try {
    $req = [System.Net.HttpWebRequest]::Create($url)
    $req.Method      = "POST"
    $req.ContentType = "application/json"
    $req.Timeout     = [System.Threading.Timeout]::Infinite
 
    $bodyBytes = [System.Text.Encoding]::UTF8.GetBytes($body)
    $req.ContentLength = $bodyBytes.Length
 
    $s = $req.GetRequestStream()
    $s.Write($bodyBytes, 0, $bodyBytes.Length)
    $s.Close()
} catch [System.Net.WebException] {
    $ep = if ($Direct) { "Ollama at $url" } else { "cppcoder at $url (is cppcoder --serve running?)" }
    Write-Error "Could not connect to ${ep}`n$($_.Exception.Message)"
    exit 1
}
 
# ── Stream response ───────────────────────────────────────────────────────────
 
try {
    $response = $req.GetResponse()
    $reader   = [System.IO.StreamReader]::new($response.GetResponseStream())
 
    if ($NoStream) {
        $raw = $reader.ReadToEnd()
        $obj = $raw | ConvertFrom-Json -ErrorAction SilentlyContinue
        if ($obj -and $obj.message -and $obj.message.content) {
            Write-Host $obj.message.content
        } else {
            Write-Host $raw
        }
    } else {
        while (-not $reader.EndOfStream) {
            $line = $reader.ReadLine()
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
 
            $obj = $line | ConvertFrom-Json -ErrorAction SilentlyContinue
            if (-not $obj) { continue }
 
            if ($obj.message -and $obj.message.content) {
                Write-Host -NoNewline $obj.message.content
            }
 
            if ($obj.done -eq $true) {
                Write-Host ""
                break
            }
        }
    }
 
    $reader.Close()
    $response.Close()
} catch [System.Net.WebException] {
    Write-Error "Stream read failed: $($_.Exception.Message)"
    exit 1
}