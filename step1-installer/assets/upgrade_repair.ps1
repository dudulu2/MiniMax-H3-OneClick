$script:TargetPythonPatch = "3.13.9"
$script:TargetTritonVersion = "3.7.1.post27"
$script:TargetSageVersion = "2.2.0+cu130torch2.10.0andhigher.post6"

$script:InstallPythonRuntimeBeforeUpgradeRepair = (Get-Command Install-PythonRuntime -CommandType Function).ScriptBlock
$script:InvokeInstallBeforeUpgradeRepair = (Get-Command Invoke-Install -CommandType Function).ScriptBlock

function Get-UpgradePackageVersion {
    param([string]$Python, [string]$PackageName)
    $code = "import importlib.metadata as m,sys`ntry:`n print(m.version(sys.argv[1]))`nexcept Exception:`n print('')"
    $value = (& $Python -c $code $PackageName 2>$null | Select-Object -Last 1)
    if ($null -eq $value) { return "" }
    return [string]$value
}

function Install-PythonRuntime {
    param([string]$InstallRoot)

    $pythonRoot = Join-Path $InstallRoot "runtime\python"
    $python = Join-Path $pythonRoot "python.exe"
    if (Test-Path -LiteralPath $python) {
        $version = (& $python -c "import platform; print(platform.python_version())" 2>$null | Select-Object -Last 1)
        if ([string]$version -ne $script:TargetPythonPatch) {
            Add-Log "Existing private Python $version does not match required Python $($script:TargetPythonPatch); rebuilding the private runtime and virtual environment." "WARN"
            $venvRoot = Join-Path $InstallRoot "runtime\venv"
            if (Test-Path -LiteralPath $venvRoot) {
                Remove-Item -LiteralPath $venvRoot -Recurse -Force
                Add-Log "Removed the old Python virtual environment for the Python $($script:TargetPythonPatch) repair."
            }
            Remove-Item -LiteralPath $pythonRoot -Recurse -Force
            Add-Log "Removed the outdated private Python runtime."
        } else {
            Add-Log "Existing private Python $version runtime exactly matches the required patch version."
        }
    }

    return (& $script:InstallPythonRuntimeBeforeUpgradeRepair -InstallRoot $InstallRoot)
}

function Get-MiniMaxRunningProcessesForUpgrade {
    param([string]$InstallRoot)

    $matches = New-Object System.Collections.Generic.List[object]
    $seen = @{}
    $pidFile = Join-Path $InstallRoot "runtime\comfyui.pid"
    if (Test-Path -LiteralPath $pidFile) {
        $rawPid = (Get-Content -LiteralPath $pidFile -Raw -ErrorAction SilentlyContinue).Trim()
        $pidValue = 0
        if ([int]::TryParse($rawPid, [ref]$pidValue) -and $pidValue -gt 0) {
            $process = Get-Process -Id $pidValue -ErrorAction SilentlyContinue
            if ($process) {
                [void]$matches.Add($process)
                $seen[[int]$process.Id] = $true
            }
        }
    }

    foreach ($process in @(Get-Process python,pythonw -ErrorAction SilentlyContinue)) {
        if ($seen.ContainsKey([int]$process.Id)) { continue }
        try {
            if ($process.Path -and $process.Path.StartsWith($InstallRoot, [StringComparison]::OrdinalIgnoreCase)) {
                [void]$matches.Add($process)
                $seen[[int]$process.Id] = $true
            }
        } catch {
            # Ignore processes whose executable path cannot be inspected.
        }
    }
    return @($matches)
}

function Invoke-Install {
    $installRoot = [IO.Path]::GetFullPath($txtPath.Text.Trim())
    $running = @(Get-MiniMaxRunningProcessesForUpgrade -InstallRoot $installRoot)
    if ($running.Count -gt 0) {
        $pids = (@($running | ForEach-Object { [string]$_.Id }) -join ", ")
        [Windows.Forms.MessageBox]::Show(
            "MiniMax H3 / ComfyUI is still running from this installation (PID: $pids).`n`nUse 'Stop MiniMax H3.bat' first, then run Install / Repair again. The installer will not replace ComfyUI or Python files while they are in use.",
            "Stop MiniMax H3 before repair",
            "OK",
            "Warning"
        ) | Out-Null
        return
    }

    & $script:InvokeInstallBeforeUpgradeRepair
}

function Install-SageAttentionRuntime {
    param([string]$Python, [string]$InstallRoot)

    $runtimeJson = (& $Python -c "import json,torch; print(json.dumps({'torch':torch.__version__,'cuda':str(torch.version.cuda or '')}))" 2>$null | Select-Object -Last 1)
    if (-not $runtimeJson) { throw "Could not inspect the selected PyTorch runtime before installing SageAttention." }
    $runtime = $runtimeJson | ConvertFrom-Json

    $isCuda130Runtime = ([string]$runtime.torch -eq "2.12.0+cu130") -and ([string]$runtime.cuda -like "13.0*")
    if (-not $isCuda130Runtime) {
        $sageState = Get-UpgradePackageVersion -Python $Python -PackageName "sageattention"
        $tritonState = Get-UpgradePackageVersion -Python $Python -PackageName "triton_windows"
        if ($sageState -or $tritonState) {
            Add-Log "Compatibility runtime detected (torch=$($runtime.torch), CUDA=$($runtime.cuda)). Removing CUDA 13 SageAttention/Triton packages because the bundled Sage wheel requires CUDA 13 / Torch 2.10+." "WARN"
            $null = Invoke-ProcessChecked $Python "-m pip uninstall -y sageattention triton_windows --disable-pip-version-check" $script:InstallerRoot -AllowFailure
        }
        Add-Log "SageAttention acceleration is disabled for the CUDA 12.6 / PyTorch 2.8 compatibility channel; standard PyTorch attention remains available." "WARN"
        return
    }

    $wheelsDir = Join-Path $script:AssetsRoot "wheels"
    $tritonWheelName = "triton_windows-$($script:TargetTritonVersion)-cp313-cp313-win_amd64.whl"
    $sageWheelName = "sageattention-$($script:TargetSageVersion)-cp310-abi3-win_amd64.whl"

    $tritonState = Get-UpgradePackageVersion -Python $Python -PackageName "triton_windows"
    if ($tritonState -ne $script:TargetTritonVersion) {
        if ($tritonState) { Add-Log "Triton $tritonState does not match required $($script:TargetTritonVersion); repairing." "WARN" }
        $tritonWheel = Join-Path $wheelsDir $tritonWheelName
        if (Test-Path -LiteralPath $tritonWheel) {
            Set-Stage "Installing required Triton $($script:TargetTritonVersion)" -1
            $exit = Invoke-ProcessChecked $Python ("-m pip install `"{0}`" --upgrade --force-reinstall --no-deps --disable-pip-version-check" -f $tritonWheel) $script:InstallerRoot -AllowFailure
            if ($exit -ne 0) {
                Add-Log "Bundled Triton wheel failed; retrying through configured Python package sources." "WARN"
                Invoke-BasePyPiWithFallback -Python $Python -PackageArguments "install triton_windows==$($script:TargetTritonVersion) --upgrade --force-reinstall --no-deps"
            }
        } else {
            Add-Log "Bundled Triton wheel is missing; retrying through configured Python package sources." "WARN"
            Invoke-BasePyPiWithFallback -Python $Python -PackageArguments "install triton_windows==$($script:TargetTritonVersion) --upgrade --force-reinstall --no-deps"
        }
    } else {
        Add-Log "Triton already matches required version $tritonState."
    }

    $sageState = Get-UpgradePackageVersion -Python $Python -PackageName "sageattention"
    if ($sageState -ne $script:TargetSageVersion) {
        if ($sageState) { Add-Log "SageAttention $sageState does not match required $($script:TargetSageVersion); repairing." "WARN" }
        $sageWheel = Join-Path $wheelsDir $sageWheelName
        if (-not (Test-Path -LiteralPath $sageWheel)) {
            throw "Bundled SageAttention wheel is missing: $sageWheel. Re-download the full installer package."
        }
        Set-Stage "Installing required SageAttention 2.2" -1
        $null = Invoke-ProcessChecked $Python ("-m pip install `"{0}`" --upgrade --force-reinstall --no-deps --disable-pip-version-check" -f $sageWheel) $script:InstallerRoot
    } else {
        Add-Log "SageAttention already matches required version $sageState."
    }

    Set-Stage "Verifying SageAttention runtime" -1
    $verify = "import importlib.metadata as m, triton, sageattention`nassert m.version('triton_windows') == '$($script:TargetTritonVersion)'`nassert m.version('sageattention') == '$($script:TargetSageVersion)'`nprint('triton', m.version('triton_windows'))`nprint('sageattention', m.version('sageattention'))"
    $null = Invoke-ProcessChecked $Python ("-c `"{0}`"" -f $verify) $script:InstallerRoot
}

function Sync-ComfyUISource {
    param([string]$SourceZip, [string]$InstallRoot)

    $comfyRoot = Join-Path $InstallRoot "ComfyUI"
    $existingInstall = Test-Path -LiteralPath (Join-Path $comfyRoot "main.py")
    if (-not $existingInstall) {
        Set-Stage "Deploying fixed ComfyUI source" -1
        Expand-Archive -LiteralPath $SourceZip -DestinationPath $InstallRoot -Force
        if (-not (Test-Path -LiteralPath (Join-Path $comfyRoot "main.py"))) { throw "ComfyUI source extraction failed." }
        return $comfyRoot
    }

    $stageRoot = Join-Path $InstallRoot ("runtime\comfy-source-stage-" + [Guid]::NewGuid().ToString("N"))
    $stagedComfy = Join-Path $stageRoot "ComfyUI"
    $backupRoot = Join-Path $InstallRoot ("comfyui-backups\" + (Get-Date -Format "yyyyMMdd-HHmmss"))
    $protectedDirectories = @("models", "user", "custom_nodes", "input", "output", "temp")
    $protectedFiles = @("extra_model_paths.yaml")

    New-Item -ItemType Directory -Force -Path $stageRoot | Out-Null
    try {
        Set-Stage "Staging fixed ComfyUI source" -1
        Expand-Archive -LiteralPath $SourceZip -DestinationPath $stageRoot -Force
        if (-not (Test-Path -LiteralPath (Join-Path $stagedComfy "main.py"))) { throw "Staged ComfyUI source is invalid." }

        New-Item -ItemType Directory -Force -Path $backupRoot | Out-Null
        Set-Stage "Backing up current ComfyUI application files" -1
        foreach ($entry in @(Get-ChildItem -LiteralPath $comfyRoot -Force)) {
            if ($entry.PSIsContainer -and $entry.Name -in $protectedDirectories) { continue }
            if (-not $entry.PSIsContainer -and $entry.Name -in $protectedFiles) { continue }
            Copy-Item -LiteralPath $entry.FullName -Destination $backupRoot -Recurse -Force
        }

        Set-Stage "Removing stale ComfyUI application files" -1
        foreach ($entry in @(Get-ChildItem -LiteralPath $comfyRoot -Force)) {
            if ($entry.PSIsContainer -and $entry.Name -in $protectedDirectories) { continue }
            if (-not $entry.PSIsContainer -and $entry.Name -in $protectedFiles) { continue }
            Remove-Item -LiteralPath $entry.FullName -Recurse -Force
        }

        Set-Stage "Deploying refreshed ComfyUI application files" -1
        foreach ($entry in @(Get-ChildItem -LiteralPath $stagedComfy -Force)) {
            if (-not $entry.PSIsContainer -and $entry.Name -in $protectedFiles -and (Test-Path -LiteralPath (Join-Path $comfyRoot $entry.Name))) {
                continue
            }
            Copy-Item -LiteralPath $entry.FullName -Destination $comfyRoot -Recurse -Force
        }
        if (-not (Test-Path -LiteralPath (Join-Path $comfyRoot "main.py"))) { throw "Refreshed ComfyUI source is missing main.py." }
        Add-Log "Existing ComfyUI core was refreshed from a clean staged copy. Preserved directories: $($protectedDirectories -join ', '); preserved root files: $($protectedFiles -join ', ')."
        Add-Log "Previous ComfyUI application files were backed up to: $backupRoot"
    } catch {
        $refreshError = $_.Exception.Message
        Add-Log "ComfyUI core refresh failed; restoring the previous application files from backup." "WARN"
        if (Test-Path -LiteralPath $backupRoot) {
            foreach ($entry in @(Get-ChildItem -LiteralPath $comfyRoot -Force -ErrorAction SilentlyContinue)) {
                if ($entry.PSIsContainer -and $entry.Name -in $protectedDirectories) { continue }
                if (-not $entry.PSIsContainer -and $entry.Name -in $protectedFiles) { continue }
                Remove-Item -LiteralPath $entry.FullName -Recurse -Force -ErrorAction SilentlyContinue
            }
            foreach ($entry in @(Get-ChildItem -LiteralPath $backupRoot -Force -ErrorAction SilentlyContinue)) {
                Copy-Item -LiteralPath $entry.FullName -Destination $comfyRoot -Recurse -Force
            }
        }
        throw "ComfyUI core refresh failed and rollback was attempted: $refreshError"
    } finally {
        Remove-Item -LiteralPath $stageRoot -Recurse -Force -ErrorAction SilentlyContinue
    }

    return $comfyRoot
}

function Install-ComfyEnvironment {
    param([string]$InstallRoot, [string]$BasePython, $Runtime)

    $sourceZip = Join-Path $script:AssetsRoot "ComfyUI-source.zip"
    $sourceHash = "B15D0CA0C1F36471E6D50305F4DB3D5B4007B98F1BBCBEFE23334F6AA4485AB5"
    if (-not (Test-Path -LiteralPath $sourceZip)) { throw "Installer asset is missing: $sourceZip" }
    if ((Get-FileHash -LiteralPath $sourceZip -Algorithm SHA256).Hash -ne $sourceHash) { throw "Bundled ComfyUI source failed verification." }

    $comfyRoot = Sync-ComfyUISource -SourceZip $sourceZip -InstallRoot $InstallRoot

    $venvRoot = Join-Path $InstallRoot "runtime\venv"
    $venvPython = Join-Path $venvRoot "Scripts\python.exe"
    if (-not (Test-Path -LiteralPath $venvPython)) {
        Set-Stage "Creating isolated Python environment" -1
        $null = Invoke-ProcessChecked $BasePython ("-m venv `"{0}`"" -f $venvRoot) $InstallRoot
    }

    Set-Stage "Checking Python toolchain" -1
    Ensure-PythonToolchain -Python $venvPython

    Set-Stage ("Checking {0}" -f $Runtime.label) -1
    Install-SelectedTorchRuntime -Python $venvPython -Runtime $Runtime -InstallRoot $InstallRoot

    Set-Stage "Checking SageAttention runtime" -1
    Install-SageAttentionRuntime -Python $venvPython -InstallRoot $InstallRoot

    $constraints = Join-Path $InstallRoot "runtime\constraints-selected.txt"
    @"
torch==$($Runtime.torch)
torchvision==$($Runtime.torchvision)
torchaudio==$($Runtime.torchaudio)
comfyui-frontend-package==1.48.7
comfyui-workflow-templates==0.11.39
"@ | Set-Content -LiteralPath $constraints -Encoding ASCII

    $requirements = Join-Path $comfyRoot "requirements.txt"
    Set-Stage "Checking ComfyUI dependencies" -1
    if (Test-ComfyRequirementsSatisfied -Python $venvPython -Requirements $requirements) {
        Add-Log "Installed ComfyUI requirements already satisfy the bundled requirements and pinned frontend/template versions. Skipping dependency download."
    } else {
        Set-Stage "Updating ComfyUI dependencies" -1
        $dependencyArgs = "install -r `"{0}`" -c `"{1}`" --upgrade --upgrade-strategy only-if-needed" -f $requirements, $constraints
        $null = Invoke-PipWithFallback $venvPython $dependencyArgs $Runtime
    }

    Set-Stage "Checking Python dependency consistency" -1
    $null = Invoke-ProcessChecked $venvPython "-m pip check" $comfyRoot

    Set-Stage "Verifying CUDA environment" -1
    $verifyCode = "import torch,torchvision,torchaudio; assert torch.__version__=='$($Runtime.torch)'; assert torchvision.__version__=='$($Runtime.torchvision)'; assert torchaudio.__version__=='$($Runtime.torchaudio)'; assert torch.cuda.is_available(); assert str(torch.version.cuda).startswith('$($Runtime.cuda_version)'); print(torch.cuda.get_device_name(0)); print('CUDA '+str(torch.version.cuda)+' ready')"
    $null = Invoke-ProcessChecked $venvPython ("-c `"{0}`"" -f $verifyCode) $comfyRoot
    return [PSCustomObject]@{ ComfyRoot=$comfyRoot; Python=$venvPython }
}
