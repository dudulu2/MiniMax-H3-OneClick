#requires -version 5.1

[CmdletBinding()]
param(
    [ValidateSet("Pre", "Post")]
    [string]$Phase = "Pre",
    [string]$TargetRoot = ""
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

$requiredPython = "3.13.9"
$requiredTorch = "2.12.0+cu130"
$requiredTorchvision = "0.27.0+cu130"
$requiredTorchaudio = "2.11.0+cu130"
$requiredCudaPrefix = "13.0"
$requiredTriton = "3.7.1.post27"
$requiredSage = "2.2.0+cu130torch2.10.0andhigher.post6"

function Test-Step2Root {
    param([string]$Path)
    return (
        (Test-Path -LiteralPath (Join-Path $Path "ComfyUI\custom_nodes")) -and
        (Test-Path -LiteralPath (Join-Path $Path "runtime\venv\Scripts\python.exe"))
    )
}

function Resolve-Step2Root {
    param([string]$RequestedRoot)

    if (-not [string]::IsNullOrWhiteSpace($RequestedRoot)) {
        $full = [IO.Path]::GetFullPath($RequestedRoot)
        if (-not (Test-Step2Root $full)) { throw "MiniMax H3 installation was not found at: $full" }
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
        Where-Object { Test-Step2Root $_ }
    )
    if ($valid.Count -eq 0) { throw "Could not find a MiniMax H3 installation. Set MINIMAX_H3_ROOT first if it is installed in a custom folder." }
    return $valid[0]
}

function Get-PackageVersion {
    param([string]$Python, [string]$PackageName)
    $code = "import importlib.metadata as m,sys`ntry:`n print(m.version(sys.argv[1]))`nexcept Exception:`n print('')"
    $value = (& $Python -c $code $PackageName 2>$null | Select-Object -Last 1)
    if ($null -eq $value) { return "" }
    return [string]$value
}

function Get-LatestPluginInstallLog {
    param([string]$Root)
    $logDir = Join-Path $Root "logs"
    if (-not (Test-Path -LiteralPath $logDir)) { return $null }
    return (Get-ChildItem -LiteralPath $logDir -Filter "plugin-install-safe-*.log" -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1)
}

function Restore-FailedPluginBackups {
    param([string]$Root, [string[]]$PluginNames)

    if (-not $PluginNames -or $PluginNames.Count -eq 0) { return }
    $targetNodes = Join-Path $Root "ComfyUI\custom_nodes"
    $backupParent = Join-Path $Root "plugin-backups"
    $latestBackup = $null
    if (Test-Path -LiteralPath $backupParent) {
        $latestBackup = Get-ChildItem -LiteralPath $backupParent -Directory -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending |
            Select-Object -First 1
    }

    foreach ($name in @($PluginNames | Select-Object -Unique)) {
        $destination = Join-Path $targetNodes $name
        if (Test-Path -LiteralPath $destination) {
            Remove-Item -LiteralPath $destination -Recurse -Force -ErrorAction SilentlyContinue
        }

        $restored = $false
        if ($latestBackup) {
            $backupSource = Join-Path $latestBackup.FullName $name
            if (Test-Path -LiteralPath $backupSource) {
                Move-Item -LiteralPath $backupSource -Destination $destination -Force
                Write-Host "Restored previous plugin after copy failure: $name"
                $restored = $true
            }
        }
        if (-not $restored) {
            Write-Host "No previous plugin backup was available for failed copy: $name"
        }
    }
}

try {
    $root = Resolve-Step2Root -RequestedRoot $TargetRoot
    $python = Join-Path $root "runtime\venv\Scripts\python.exe"

    $pythonVersion = (& $python -c "import platform; print(platform.python_version())" 2>$null | Select-Object -Last 1)
    if ([string]$pythonVersion -ne $requiredPython) {
        throw "Step 2 requires Python $requiredPython, but this installation uses Python $pythonVersion. Run step 1 Install / Repair first."
    }

    $runtimeJson = (& $python -c "import json,torch,torchvision,torchaudio; print(json.dumps({'torch':torch.__version__,'torchvision':torchvision.__version__,'torchaudio':torchaudio.__version__,'cuda':str(torch.version.cuda or '')}))" 2>$null | Select-Object -Last 1)
    if (-not $runtimeJson) { throw "Could not read the installed PyTorch runtime." }
    $runtime = $runtimeJson | ConvertFrom-Json

    if (
        [string]$runtime.torch -ne $requiredTorch -or
        [string]$runtime.torchvision -ne $requiredTorchvision -or
        [string]$runtime.torchaudio -ne $requiredTorchaudio -or
        [string]$runtime.cuda -notlike "$requiredCudaPrefix*"
    ) {
        throw "Step 2 acceleration pack requires the default PyTorch 2.12 / CUDA 13.0 runtime. Current runtime: torch=$($runtime.torch), torchvision=$($runtime.torchvision), torchaudio=$($runtime.torchaudio), CUDA=$($runtime.cuda). The CUDA 12.6 / PyTorch 2.8 compatibility channel remains usable in step 1, but the bundled SageAttention wheel targets CUDA 13 / Torch 2.10+."
    }

    if ($Phase -eq "Post") {
        $failures = New-Object System.Collections.Generic.List[string]
        $latestLog = Get-LatestPluginInstallLog -Root $root
        if ($latestLog) {
            $logText = Get-Content -LiteralPath $latestLog.FullName -Raw -ErrorAction SilentlyContinue
            $copyMatches = @([regex]::Matches([string]$logText, 'Failed to copy plugin ([^:]+):'))
            if ($copyMatches.Count -gt 0) {
                $failedPlugins = @($copyMatches | ForEach-Object { $_.Groups[1].Value.Trim() } | Select-Object -Unique)
                Restore-FailedPluginBackups -Root $root -PluginNames $failedPlugins
                [void]$failures.Add("Plugin copy failed and previous backups were restored where available: $($failedPlugins -join ', ')")
            }
            if ([string]$logText -match 'Dependency installation failed for ' -or [string]$logText -match 'Plugins were copied, but one or more dependency issues remain\.') {
                [void]$failures.Add("One or more plugin dependency installations failed. See $($latestLog.FullName)")
            }
        } else {
            [void]$failures.Add("No plugin installation log was produced for postflight verification.")
        }

        $triton = Get-PackageVersion -Python $python -PackageName "triton_windows"
        $sage = Get-PackageVersion -Python $python -PackageName "sageattention"
        if ($triton -ne $requiredTriton) { [void]$failures.Add("Triton verification failed. Required $requiredTriton, found '$triton'.") }
        if ($sage -ne $requiredSage) { [void]$failures.Add("SageAttention verification failed. Required $requiredSage, found '$sage'.") }

        $importCheck = & $python -c "import triton, sageattention; print('ok')" 2>$null
        if ($LASTEXITCODE -ne 0 -or -not $importCheck) { [void]$failures.Add("Acceleration import verification failed.") }

        $pipCheckOutput = @(& $python -m pip check 2>&1)
        $pipCheckExit = $LASTEXITCODE
        foreach ($line in $pipCheckOutput) { if ([string]$line) { Write-Host ([string]$line) } }
        if ($pipCheckExit -ne 0) { [void]$failures.Add("pip check failed after plugin installation.") }

        if ($failures.Count -gt 0) {
            throw ($failures -join " ")
        }
        Write-Host "Step 2 post-check passed: Python $pythonVersion; torch $($runtime.torch); CUDA $($runtime.cuda); Triton $triton; SageAttention $sage; pip check passed."
    } else {
        Write-Host "Step 2 pre-check passed: Python $pythonVersion; torch $($runtime.torch); CUDA $($runtime.cuda)."
    }
    exit 0
} catch {
    Write-Host ""
    Write-Host ("Step 2 runtime check failed: " + $_.Exception.Message)
    Write-Host ""
    exit 1
}
