#requires -version 5.1

[CmdletBinding()]
param(
    [string]$TargetRoot = ""
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

$sourceRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$wheelhouse = Join-Path $sourceRoot "wheels\dependencies"
$manifestPath = Join-Path $sourceRoot "step2-wheel-sha256.txt"
$lockPath = Join-Path $sourceRoot "step2-wheel-lock.txt"

function Write-LocalWheelLog {
    param([string]$Message, [string]$Level = "INFO")
    Write-Host ("[{0}] [{1}] {2}" -f (Get-Date -Format "HH:mm:ss"), $Level, $Message)
}

function Test-MiniMaxTargetRoot {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    return (
        (Test-Path -LiteralPath (Join-Path $Path "ComfyUI\custom_nodes")) -and
        (Test-Path -LiteralPath (Join-Path $Path "runtime\venv\Scripts\python.exe"))
    )
}

function Resolve-MiniMaxTargetRoot {
    param([string]$RequestedRoot)

    if (-not [string]::IsNullOrWhiteSpace($RequestedRoot)) {
        $full = [IO.Path]::GetFullPath($RequestedRoot)
        if (-not (Test-MiniMaxTargetRoot $full)) { throw "MiniMax H3 installation was not found at: $full" }
        return $full
    }

    $candidates = @()
    if (-not [string]::IsNullOrWhiteSpace($env:MINIMAX_H3_ROOT)) { $candidates += $env:MINIMAX_H3_ROOT }
    $candidates += "D:\MiniMaxH3"
    foreach ($drive in Get-PSDrive -PSProvider FileSystem) { $candidates += (Join-Path $drive.Root "MiniMaxH3") }

    $valid = @(
        $candidates |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        ForEach-Object { [IO.Path]::GetFullPath($_) } |
        Select-Object -Unique |
        Where-Object { Test-MiniMaxTargetRoot $_ }
    )
    if ($valid.Count -eq 0) { throw "Could not find a MiniMax H3 installation. Set MINIMAX_H3_ROOT if it is installed in a custom folder." }
    return $valid[0]
}

function Invoke-LocalPythonProbe {
    param(
        [string]$Python,
        [string[]]$Arguments
    )

    # Windows PowerShell 5.1 can surface native stderr as a terminating
    # ErrorRecord when the script-level ErrorActionPreference is Stop. Python
    # warnings (for example torch's pynvml FutureWarning) are not failures, so
    # temporarily continue and judge the probe only by the native exit code.
    $previousPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        $rawOutput = @(& $Python @Arguments 2>$null)
        $exitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previousPreference
    }

    return [PSCustomObject]@{
        ExitCode = [int]$exitCode
        Output = @($rawOutput | ForEach-Object { [string]$_ })
    }
}

function Invoke-LocalPip {
    param(
        [string]$Python,
        [string[]]$Arguments,
        [string]$WorkingDirectory
    )

    $previousPreference = $ErrorActionPreference
    try {
        # Windows PowerShell 5.1 can wrap harmless native stderr text as an
        # ErrorRecord. Judge pip success by its real process exit code instead.
        $ErrorActionPreference = "Continue"
        $output = @(& $Python @Arguments 2>&1)
        $exitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previousPreference
    }

    foreach ($line in $output) {
        if (-not [string]::IsNullOrWhiteSpace([string]$line)) { Write-Host ([string]$line) }
    }
    return [int]$exitCode
}

function Test-OptionalWheelManifest {
    param([string]$WheelRoot, [string]$Manifest)

    if (-not (Test-Path -LiteralPath $Manifest -PathType Leaf)) {
        Write-LocalWheelLog "No step2-wheel-sha256.txt was bundled; local wheels will be validated by pip compatibility/resolution." "WARN"
        return $true
    }

    $checked = 0
    foreach ($rawLine in Get-Content -LiteralPath $Manifest) {
        $line = [string]$rawLine
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $match = [regex]::Match($line, '^([0-9a-fA-F]{64})\s{2,}(.+\.whl)$')
        if (-not $match.Success) { continue }

        $expected = $match.Groups[1].Value.ToLowerInvariant()
        $name = $match.Groups[2].Value.Trim()
        $path = Join-Path $WheelRoot $name
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            Write-LocalWheelLog "Manifest wheel is missing: $name" "WARN"
            return $false
        }
        $actual = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($actual -ne $expected) {
            Write-LocalWheelLog "SHA256 mismatch for local wheel: $name" "WARN"
            return $false
        }
        $checked++
    }

    Write-LocalWheelLog "Verified $checked local dependency wheel hashes from step2-wheel-sha256.txt."
    return $true
}

if (-not (Test-Path -LiteralPath $wheelhouse -PathType Container)) {
    Write-LocalWheelLog "Local dependency wheelhouse not found: $wheelhouse. Step 2 will use the configured mirror/network fallback." "WARN"
    exit 2
}

$wheelFiles = @(Get-ChildItem -LiteralPath $wheelhouse -Filter "*.whl" -File -ErrorAction SilentlyContinue)
if ($wheelFiles.Count -eq 0) {
    Write-LocalWheelLog "Local dependency wheelhouse is empty. Step 2 will use the configured mirror/network fallback." "WARN"
    exit 2
}

if (-not (Test-OptionalWheelManifest -WheelRoot $wheelhouse -Manifest $manifestPath)) {
    Write-LocalWheelLog "Local wheel verification failed. Ignoring the wheelhouse and continuing with network fallback." "WARN"
    exit 2
}

$root = Resolve-MiniMaxTargetRoot -RequestedRoot $TargetRoot
$python = Join-Path $root "runtime\venv\Scripts\python.exe"
$runtimeConstraints = Join-Path $root "runtime\constraints-selected.txt"
$tempConstraints = Join-Path $env:TEMP ("minimax-step2-local-wheel-constraints-" + [Guid]::NewGuid().ToString("N") + ".txt")

try {
    $runtimeProbe = Invoke-LocalPythonProbe -Python $python -Arguments @(
        "-c",
        "import json,torch,torchvision,torchaudio; print(json.dumps({'torch':torch.__version__,'torchvision':torchvision.__version__,'torchaudio':torchaudio.__version__}))"
    )
    if ($runtimeProbe.ExitCode -ne 0) { throw "Could not inspect the installed PyTorch runtime (Python exit $($runtimeProbe.ExitCode))." }
    $runtimeJson = @($runtimeProbe.Output | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Select-Object -Last 1)[0]
    if (-not $runtimeJson) { throw "Could not inspect the installed PyTorch runtime." }
    $runtime = $runtimeJson | ConvertFrom-Json

    @"
torch==$($runtime.torch)
torchvision==$($runtime.torchvision)
torchaudio==$($runtime.torchaudio)
"@ | Set-Content -LiteralPath $tempConstraints -Encoding ASCII

    if (Test-Path -LiteralPath $runtimeConstraints -PathType Leaf) {
        Get-Content -LiteralPath $runtimeConstraints |
            Where-Object { $_ -notmatch '^(torch|torchvision|torchaudio)==' } |
            Add-Content -LiteralPath $tempConstraints -Encoding ASCII
    }

    if (Test-Path -LiteralPath $lockPath -PathType Leaf) {
        Get-Content -LiteralPath $lockPath |
            Where-Object { $_ -and -not ([string]$_).Trim().StartsWith('#') } |
            Add-Content -LiteralPath $tempConstraints -Encoding ASCII
        Write-LocalWheelLog "Applied validated Step 2 dependency versions from step2-wheel-lock.txt."
    } else {
        Write-LocalWheelLog "step2-wheel-lock.txt is missing; using plugin requirements without the validated dependency pins." "WARN"
    }

    $pluginNames = @(
        "comfyui_essentials",
        "comfyui-crystools",
        "comfyui-custom-scripts",
        "comfyui-manager",
        "comfyui-VideoHelperSuite",
        "rgthree-comfy",
        "comfyui-minimax-h3-audio-T8",
        "comfyui-minimax-h3-blockcache-T8",
        "ComfyUI-MiniMaxH3-AVCache-CN",
        "SageAttention-MiniMaxH3-Safe",
        "minimax_h3_workflow_autoload",
        "TE-Speed-MiniMaxH3-OSS"
    )

    Write-LocalWheelLog "Local dependency wheelhouse detected: $($wheelFiles.Count) wheels at $wheelhouse"
    Write-LocalWheelLog "Trying Step 2 plugin requirements completely offline before any package index is used."

    foreach ($name in $pluginNames) {
        $requirements = Join-Path (Join-Path $sourceRoot $name) "requirements.txt"
        if (-not (Test-Path -LiteralPath $requirements -PathType Leaf)) { continue }

        Write-LocalWheelLog "Installing local dependency wheels for: $name"
        $args = @(
            "-m", "pip", "install",
            "-r", $requirements,
            "-c", $tempConstraints,
            "--no-index",
            "--find-links", $wheelhouse,
            "--upgrade-strategy", "only-if-needed",
            "--disable-pip-version-check"
        )
        $exitCode = Invoke-LocalPip -Python $python -Arguments $args -WorkingDirectory $root
        if ($exitCode -ne 0) {
            Write-LocalWheelLog "The local wheelhouse could not satisfy $name completely (pip exit $exitCode). Network fallback will finish the installation." "WARN"
            exit 2
        }
    }

    Write-LocalWheelLog "Local dependency wheelhouse satisfied all Step 2 plugin requirements. Network package downloads should not be needed."
    exit 0
} finally {
    Remove-Item -LiteralPath $tempConstraints -Force -ErrorAction SilentlyContinue
}
