#requires -version 5.1

[CmdletBinding()]
param(
    [string]$TargetRoot = "",
    [switch]$AutoConfirm
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

$sourceRoot = Split-Path -Parent $MyInvocation.MyCommand.Path

if ([string]::IsNullOrWhiteSpace($env:PIP_INDEX_URL)) { $env:PIP_INDEX_URL = "https://pypi.tuna.tsinghua.edu.cn/simple" }
if ([string]::IsNullOrWhiteSpace($env:PIP_DEFAULT_TIMEOUT)) { $env:PIP_DEFAULT_TIMEOUT = "120" }
if ([string]::IsNullOrWhiteSpace($env:PIP_RETRIES)) { $env:PIP_RETRIES = "3" }
if ([string]::IsNullOrWhiteSpace($env:PIP_DISABLE_PIP_VERSION_CHECK)) { $env:PIP_DISABLE_PIP_VERSION_CHECK = "1" }

$pluginIndexUrl = $env:PIP_INDEX_URL
$pluginTimeout = if ($env:PIP_DEFAULT_TIMEOUT -match '^\d+$') { $env:PIP_DEFAULT_TIMEOUT } else { "120" }
$pluginRetries = if ($env:PIP_RETRIES -match '^\d+$') { $env:PIP_RETRIES } else { "3" }
$targetPythonVersion = "3.13"
$targetPythonTag = "cp313"
$targetTritonVersion = "3.7.1.post27"
$targetSageVersion = "2.2.0+cu130torch2.10.0andhigher.post6"

function Test-MiniMaxTargetRoot {
    param([string]$Path)
    $nodes = Join-Path $Path "ComfyUI\custom_nodes"
    $python = Join-Path $Path "runtime\venv\Scripts\python.exe"
    return (Test-Path -LiteralPath $nodes) -and (Test-Path -LiteralPath $python)
}

function Resolve-MiniMaxTargetRoot {
    param([string]$RequestedRoot)

    if (-not [string]::IsNullOrWhiteSpace($RequestedRoot)) {
        return [IO.Path]::GetFullPath($RequestedRoot)
    }

    $candidates = @()
    if (-not [string]::IsNullOrWhiteSpace($env:MINIMAX_H3_ROOT)) {
        $candidates += $env:MINIMAX_H3_ROOT
    }
    $candidates += "D:\MiniMaxH3"
    foreach ($drive in Get-PSDrive -PSProvider FileSystem) {
        $candidates += (Join-Path $drive.Root "MiniMaxH3")
    }

    $valid = @(
        $candidates |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        ForEach-Object { [IO.Path]::GetFullPath($_) } |
        Select-Object -Unique |
        Where-Object { Test-MiniMaxTargetRoot $_ }
    )
    if ($valid.Count -eq 1) { return $valid[0] }
    if ($valid.Count -gt 1) {
        Write-Host "Multiple MiniMax H3 installations found; using: $($valid[0])"
        return $valid[0]
    }
    throw "Could not find a MiniMax H3 installation. Set MINIMAX_H3_ROOT or pass -TargetRoot."
}

$TargetRoot = Resolve-MiniMaxTargetRoot -RequestedRoot $TargetRoot
$targetNodes = Join-Path $TargetRoot "ComfyUI\custom_nodes"
$venvPython = Join-Path $TargetRoot "runtime\venv\Scripts\python.exe"
$runtimeConstraints = Join-Path $TargetRoot "runtime\constraints-selected.txt"
$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$backupRoot = Join-Path $TargetRoot ("plugin-backups\" + $timestamp)
$logRoot = Join-Path $TargetRoot "logs"
$logPath = Join-Path $logRoot ("plugin-install-safe-" + $timestamp + ".log")
$tempConstraints = Join-Path $env:TEMP ("minimax-plugin-constraints-" + $timestamp + ".txt")

New-Item -ItemType Directory -Force -Path $logRoot | Out-Null

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $line = "[{0}] [{1}] {2}" -f (Get-Date -Format "HH:mm:ss"), $Level, $Message
    Write-Host $line
    Add-Content -LiteralPath $logPath -Value $line -Encoding UTF8
}

function Stop-WithMessage {
    param([string]$Message)
    Write-Log $Message "ERROR"
    Write-Host ""
    Write-Host "Installation stopped. Review the log above before retrying."
    exit 1
}

Write-Log "Pip source: $pluginIndexUrl; timeout: $pluginTimeout seconds; retries: $pluginRetries"

function Get-RunningComfyUIProcess {
    $pidFile = Join-Path $TargetRoot "runtime\comfyui.pid"
    if (-not (Test-Path -LiteralPath $pidFile)) { return $null }

    $targetPid = 0
    $rawPid = (Get-Content -LiteralPath $pidFile -Raw -ErrorAction SilentlyContinue).Trim()
    if (-not [int]::TryParse($rawPid, [ref]$targetPid) -or $targetPid -le 0) { return $null }

    $process = Get-Process -Id $targetPid -ErrorAction SilentlyContinue
    if (-not $process) { return $null }
    try {
        if ($process.Path -and -not $process.Path.StartsWith($TargetRoot, [StringComparison]::OrdinalIgnoreCase)) {
            return $null
        }
    } catch {
        # If Windows denies access to Process.Path, keep the safe behavior and block.
    }
    return $process
}

function Invoke-NativeLogged {
    param(
        [string]$FilePath,
        [string[]]$Arguments,
        [string]$WorkingDirectory
    )

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $FilePath
    $psi.WorkingDirectory = $WorkingDirectory
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true

    foreach ($argument in $Arguments) {
        if ($argument -match '[\s"]') {
            $escaped = $argument.Replace('"', '\"')
            $psi.Arguments += ' "' + $escaped + '"'
        }
        else {
            $psi.Arguments += ' ' + $argument
        }
    }

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $psi
    if (-not $process.Start()) {
        throw "Could not start process: $FilePath"
    }

    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    $process.WaitForExit()

    $combined = @()
    if ($stdoutTask.Result) { $combined += ($stdoutTask.Result -split "`r?`n") }
    if ($stderrTask.Result) { $combined += ($stderrTask.Result -split "`r?`n") }

    foreach ($line in $combined) {
        if ($line.Trim()) {
            Write-Host $line
            Add-Content -LiteralPath $logPath -Value $line -Encoding UTF8
        }
    }

    return [int]$process.ExitCode
}

Write-Log "Plugin source folder: $sourceRoot"
Write-Log "Target custom_nodes folder: $targetNodes"
Write-Log "Python environment: $venvPython"

if (-not (Test-Path -LiteralPath $targetNodes)) {
    Stop-WithMessage "Target custom_nodes folder was not found: $targetNodes"
}
if (-not (Test-Path -LiteralPath $venvPython)) {
    Stop-WithMessage "MiniMax H3 Python environment was not found: $venvPython"
}

$venvVersion = (& $venvPython -c "import sys; print('%d.%d' % sys.version_info[:2])" 2>$null | Select-Object -Last 1)
if ([string]::IsNullOrWhiteSpace($venvVersion)) {
    Stop-WithMessage "Could not detect the Python version of the MiniMax H3 environment."
}
if ([string]$venvVersion -ne $targetPythonVersion) {
    Stop-WithMessage "Step 2 requires Python $targetPythonVersion, but this installation uses Python $venvVersion. Re-run step1-installer\Start-Installer.bat with Install / Repair first, then run the plugin installer again."
}
Write-Log "Python runtime verified: $venvVersion ($targetPythonTag)."

$runningComfyUI = Get-RunningComfyUIProcess
if ($runningComfyUI) {
    Stop-WithMessage "ComfyUI is still running (PID $($runningComfyUI.Id)). Double-click '$TargetRoot\Stop MiniMax H3.bat' and then run Install-Plugins-Safe.bat again."
}

# Read and lock the currently verified CUDA/PyTorch runtime.
$versionsJson = & $venvPython -c "import json,torch,torchvision,torchaudio; print(json.dumps({'torch':torch.__version__,'torchvision':torchvision.__version__,'torchaudio':torchaudio.__version__,'cuda':str(torch.version.cuda or '')}))"
if ($LASTEXITCODE -ne 0 -or -not $versionsJson) {
    Stop-WithMessage "Could not read the installed PyTorch runtime."
}

$versions = $versionsJson | ConvertFrom-Json
@"
torch==$($versions.torch)
torchvision==$($versions.torchvision)
torchaudio==$($versions.torchaudio)
"@ | Set-Content -LiteralPath $tempConstraints -Encoding ASCII

if (Test-Path -LiteralPath $runtimeConstraints) {
    Get-Content -LiteralPath $runtimeConstraints |
        Where-Object { $_ -notmatch '^(torch|torchvision|torchaudio)==' } |
        Add-Content -LiteralPath $tempConstraints -Encoding ASCII
}

Write-Log "Protected runtime: torch=$($versions.torch), torchvision=$($versions.torchvision), torchaudio=$($versions.torchaudio), CUDA=$($versions.cuda)"
Write-Log "Constraint file: $tempConstraints"

function Get-VenvPythonTag {
    $code = "import sys; print('cp%d%d' % sys.version_info[:2])"
    $tag = (& $venvPython -c $code 2>$null | Select-Object -Last 1)
    if (-not $tag -or $tag -notmatch '^cp\d+$') {
        Stop-WithMessage "Could not detect the Python tag of the MiniMax H3 environment."
    }
    if ([string]$tag -ne $targetPythonTag) {
        Stop-WithMessage "Step 2 requires the $targetPythonTag wheel ABI, but the current environment reports $tag. Re-run step 1 first."
    }
    return $tag
}

function Get-PackageVersion {
    param([string]$PackageName)
    $code = "import importlib.metadata as m,sys`ntry:`n print(m.version(sys.argv[1]))`nexcept Exception:`n print('')"
    $version = (& $venvPython -c $code $PackageName 2>$null | Select-Object -Last 1)
    if ($null -eq $version) { return "" }
    return [string]$version
}

function Install-PackageFromIndexes {
    param([string]$PackageSpec, [string]$Label)

    $args = @(
        "-m", "pip", "install", $PackageSpec,
        "--upgrade", "--force-reinstall", "--no-deps",
        "--index-url", $pluginIndexUrl,
        "--timeout", $pluginTimeout,
        "--retries", $pluginRetries,
        "--disable-pip-version-check"
    )
    $exitCode = Invoke-NativeLogged -FilePath $venvPython -Arguments $args -WorkingDirectory $TargetRoot
    if ($exitCode -eq 0) { return 0 }

    Write-Log "$Label installation from the configured mirror failed; retrying with official PyPI." "WARN"
    $fallbackArgs = @(
        "-m", "pip", "install", $PackageSpec,
        "--upgrade", "--force-reinstall", "--no-deps",
        "--index-url", "https://pypi.org/simple",
        "--timeout", $pluginTimeout,
        "--retries", $pluginRetries,
        "--disable-pip-version-check"
    )
    return (Invoke-NativeLogged -FilePath $venvPython -Arguments $fallbackArgs -WorkingDirectory $TargetRoot)
}

function Install-OfflineAccelerationWheels {
    $wheelsDir = Join-Path $sourceRoot "wheels"
    $pyTag = Get-VenvPythonTag
    Write-Log "Python tag: $pyTag"

    $tritonState = Get-PackageVersion -PackageName "triton_windows"
    if ($tritonState -eq $targetTritonVersion) {
        Write-Log "Triton is already at the required version: $tritonState"
    } else {
        if ($tritonState) {
            Write-Log "Triton version mismatch: installed $tritonState, required $targetTritonVersion. Upgrading." "WARN"
        } else {
            Write-Log "Triton is not installed. Installing $targetTritonVersion."
        }

        $localTriton = $null
        if (Test-Path -LiteralPath $wheelsDir) {
            $expectedTritonWheel = "triton_windows-$targetTritonVersion-$pyTag-$pyTag-win_amd64.whl"
            $candidate = Join-Path $wheelsDir $expectedTritonWheel
            if (Test-Path -LiteralPath $candidate -PathType Leaf) { $localTriton = Get-Item -LiteralPath $candidate }
        }

        $tritonExit = 1
        if ($localTriton) {
            Write-Log "Installing required Triton from bundled wheel: $($localTriton.Name)"
            $tritonArgs = @("-m", "pip", "install", $localTriton.FullName, "--upgrade", "--force-reinstall", "--no-deps", "--disable-pip-version-check")
            $tritonExit = Invoke-NativeLogged -FilePath $venvPython -Arguments $tritonArgs -WorkingDirectory $TargetRoot
            if ($tritonExit -ne 0) {
                Write-Log "Bundled Triton wheel installation failed; trying package indexes." "WARN"
            }
        } else {
            Write-Log "Bundled Triton $targetTritonVersion wheel was not found; trying package indexes." "WARN"
        }
        if ($tritonExit -ne 0) {
            $tritonExit = Install-PackageFromIndexes -PackageSpec "triton_windows==$targetTritonVersion" -Label "Triton"
        }
        if ($tritonExit -ne 0) { Stop-WithMessage "Triton $targetTritonVersion installation failed with exit code $tritonExit." }
    }

    $sageState = Get-PackageVersion -PackageName "sageattention"
    if ($sageState -eq $targetSageVersion) {
        Write-Log "SageAttention is already at the required version: $sageState"
    } else {
        if ($sageState) {
            Write-Log "SageAttention version mismatch: installed $sageState, required $targetSageVersion. Upgrading." "WARN"
        } else {
            Write-Log "SageAttention is not installed. Installing $targetSageVersion."
        }

        $localSage = $null
        if (Test-Path -LiteralPath $wheelsDir) {
            $localSage = Get-ChildItem -LiteralPath $wheelsDir -Filter "sageattention-*.whl" -File |
                Where-Object { $_.Name -like "sageattention-$targetSageVersion-*-abi3-win_amd64.whl" } |
                Select-Object -First 1
        }

        $sageExit = 1
        if ($localSage) {
            Write-Log "Installing required SageAttention from bundled wheel: $($localSage.Name)"
            $sageArgs = @("-m", "pip", "install", $localSage.FullName, "--upgrade", "--force-reinstall", "--no-deps", "--disable-pip-version-check")
            $sageExit = Invoke-NativeLogged -FilePath $venvPython -Arguments $sageArgs -WorkingDirectory $TargetRoot
            if ($sageExit -ne 0) {
                Write-Log "Bundled SageAttention wheel installation failed; trying package indexes." "WARN"
            }
        } else {
            Write-Log "Bundled SageAttention $targetSageVersion wheel was not found; trying package indexes." "WARN"
        }
        if ($sageExit -ne 0) {
            $sageExit = Install-PackageFromIndexes -PackageSpec "sageattention==$targetSageVersion" -Label "SageAttention"
        }
        if ($sageExit -ne 0) { Stop-WithMessage "SageAttention $targetSageVersion installation failed with exit code $sageExit." }
    }

    $tritonAfter = Get-PackageVersion -PackageName "triton_windows"
    $sageAfter = Get-PackageVersion -PackageName "sageattention"
    if ($tritonAfter -ne $targetTritonVersion) {
        Stop-WithMessage "Triton verification failed. Required $targetTritonVersion, found '$tritonAfter'."
    }
    if ($sageAfter -ne $targetSageVersion) {
        Stop-WithMessage "SageAttention verification failed. Required $targetSageVersion, found '$sageAfter'."
    }
    Write-Log "Acceleration runtime verified: Triton $tritonAfter; SageAttention $sageAfter."
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
$pluginDirs = @(
    Get-ChildItem -LiteralPath $sourceRoot -Directory -Force |
    Where-Object {
        $_.Name -in $pluginNames
    }
)

if ($pluginDirs.Count -eq 0) {
    Stop-WithMessage "No plugin folders were found next to this script."
}

Write-Host ""
Write-Host "The following plugin folders will be installed:"
foreach ($plugin in $pluginDirs) { Write-Host ("  - " + $plugin.Name) }
Write-Host ""

if ($AutoConfirm) {
    Write-Log "Automatic confirmation enabled. Continuing without prompt."
} else {
    $answer = Read-Host "Type Y and press Enter to continue"
    if ($answer -notmatch "^[Yy]$") {
        Write-Log "Installation cancelled by user." "WARN"
        exit 0
    }
}

$copiedPlugins = New-Object System.Collections.Generic.List[string]

foreach ($plugin in $pluginDirs) {
    $destination = Join-Path $targetNodes $plugin.Name
    $preserveAutoload = ($plugin.Name -eq "minimax_h3_workflow_autoload")
    $existingAutoload = $null
    if ($preserveAutoload) {
        $candidate = Join-Path $destination "web\autoload.js"
        if (Test-Path -LiteralPath $candidate) {
            $existingAutoload = Get-Content -LiteralPath $candidate -Raw -Encoding UTF8
            Write-Log "minimax_h3_workflow_autoload: keeping the existing generated autoload.js that matches the installed profile."
        }
    }
    try {
        if (Test-Path -LiteralPath $destination) {
            New-Item -ItemType Directory -Force -Path $backupRoot | Out-Null
            $backupDestination = Join-Path $backupRoot $plugin.Name
            Write-Log "Existing plugin found. Moving it to backup: $backupDestination" "WARN"
            Move-Item -LiteralPath $destination -Destination $backupDestination -Force
        }

        Write-Log "Copying plugin: $($plugin.Name)"
        Copy-Item -LiteralPath $plugin.FullName -Destination $destination -Recurse -Force
        $copiedPlugins.Add($destination)
        Write-Log "Plugin copied: $($plugin.Name)"
    }
    catch {
        Write-Log "Failed to copy plugin $($plugin.Name): $($_.Exception.Message)" "ERROR"
    }
    finally {
        if ($preserveAutoload -and $existingAutoload -and (Test-Path -LiteralPath (Join-Path $destination "web\autoload.js"))) {
            $existingAutoload | Set-Content -LiteralPath (Join-Path $destination "web\autoload.js") -Encoding UTF8
        }
    }
}

if ($copiedPlugins.Count -eq 0) {
    Stop-WithMessage "No plugins were copied successfully."
}

Write-Host ""
Write-Host "Installing/updating SageAttention and Triton acceleration wheels..."
Install-OfflineAccelerationWheels

$dependencyFailures = New-Object System.Collections.Generic.List[string]

foreach ($pluginPath in $copiedPlugins) {
    $pluginName = Split-Path -Leaf $pluginPath
    $requirements = Join-Path $pluginPath "requirements.txt"

    if (-not (Test-Path -LiteralPath $requirements)) {
        Write-Log "$pluginName has no requirements.txt. Skipping dependency installation."
        continue
    }

    Write-Log "Installing dependencies for: $pluginName"
    $args = @(
        "-m", "pip", "install",
        "-r", $requirements,
        "-c", $tempConstraints,
        "--index-url", $pluginIndexUrl,
        "--timeout", $pluginTimeout,
        "--retries", $pluginRetries,
        "--upgrade-strategy", "only-if-needed",
        "--disable-pip-version-check"
    )

    $exitCode = Invoke-NativeLogged -FilePath $venvPython -Arguments $args -WorkingDirectory $TargetRoot
    if ($exitCode -ne 0) {
        Write-Log "Mirror dependency installation failed for $pluginName; retrying with official PyPI." "WARN"
        $fallbackArgs = @(
            "-m", "pip", "install",
            "-r", $requirements,
            "-c", $tempConstraints,
            "--index-url", "https://pypi.org/simple",
            "--timeout", $pluginTimeout,
            "--retries", $pluginRetries,
            "--upgrade-strategy", "only-if-needed",
            "--disable-pip-version-check"
        )
        $fallbackExitCode = Invoke-NativeLogged -FilePath $venvPython -Arguments $fallbackArgs -WorkingDirectory $TargetRoot
        if ($fallbackExitCode -ne 0) {
            $dependencyFailures.Add($pluginName)
            Write-Log "Dependency installation failed for $pluginName. Mirror exit code: $exitCode; official PyPI exit code: $fallbackExitCode" "ERROR"
        }
        else {
            Write-Log "Dependencies installed for $pluginName from official PyPI."
        }
    }
    else {
        Write-Log "Dependencies installed for: $pluginName"
    }
}

# Verify that no plugin changed the CUDA runtime.
$afterJson = & $venvPython -c "import json,torch,torchvision,torchaudio; print(json.dumps({'torch':torch.__version__,'torchvision':torchvision.__version__,'torchaudio':torchaudio.__version__,'cuda':str(torch.version.cuda or '')}))"
$after = $afterJson | ConvertFrom-Json
if (
    $after.torch -ne $versions.torch -or
    $after.torchvision -ne $versions.torchvision -or
    $after.torchaudio -ne $versions.torchaudio -or
    $after.cuda -ne $versions.cuda
) {
    Stop-WithMessage "Protected PyTorch runtime changed unexpectedly. Review log: $logPath"
}

Write-Log "Running pip check."
$pipCheckExit = Invoke-NativeLogged -FilePath $venvPython -Arguments @("-m", "pip", "check") -WorkingDirectory $TargetRoot

Write-Host ""
if (($dependencyFailures.Count -eq 0) -and ($pipCheckExit -eq 0)) {
    Write-Log "All plugins were copied and dependency checks passed."
    Write-Host "Installation completed successfully."
}
else {
    Write-Log "Plugins were copied, but one or more dependency issues remain." "WARN"
    if ($dependencyFailures.Count -gt 0) {
        Write-Host "Plugins with dependency installation failures:"
        foreach ($name in $dependencyFailures) { Write-Host ("  - " + $name) }
    }
    Write-Host ("See log: " + $logPath)
}

Write-Host ""
Write-Host ("Protected runtime remains: torch " + $after.torch + ", CUDA " + $after.cuda)
if (Test-Path -LiteralPath $backupRoot) {
    Write-Host ("Old plugin backup: " + $backupRoot)
}
Write-Host ("Full log: " + $logPath)

Remove-Item -LiteralPath $tempConstraints -Force -ErrorAction SilentlyContinue
exit 0
