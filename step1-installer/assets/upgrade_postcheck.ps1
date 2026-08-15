$script:InstallComfyEnvironmentBeforeUpgradePostCheck = (Get-Command Install-ComfyEnvironment -CommandType Function).ScriptBlock
$script:GetInstalledTorchRuntimeBeforeUpgradePostCheck = (Get-Command Get-InstalledTorchRuntime -CommandType Function).ScriptBlock
$script:InstallSageAttentionRuntimeBeforeUpgradePostCheck = (Get-Command Install-SageAttentionRuntime -CommandType Function).ScriptBlock

# Windows PowerShell 5.1 converts native stderr text into ErrorRecord objects.
# With the installer-wide ErrorActionPreference=Stop, a harmless Python warning
# (notably torch's pynvml FutureWarning) can otherwise terminate Step 1 even
# when Python exits successfully. Keep these two torch-import probes under
# Continue and let their existing output/exit-code checks decide real failure.
function Get-InstalledTorchRuntime {
    param([string]$Python)

    $previousPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        return (& $script:GetInstalledTorchRuntimeBeforeUpgradePostCheck -Python $Python)
    } finally {
        $ErrorActionPreference = $previousPreference
    }
}

function Install-SageAttentionRuntime {
    param([string]$Python, [string]$InstallRoot)

    $previousPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        & $script:InstallSageAttentionRuntimeBeforeUpgradePostCheck -Python $Python -InstallRoot $InstallRoot
    } finally {
        $ErrorActionPreference = $previousPreference
    }
}

function Get-MiniMaxRunningProcessesForUpgrade {
    param([string]$InstallRoot)

    # Keep this as a native PowerShell array. Windows PowerShell 5.1 can throw
    # PSToObjectArrayBinder "parameter type mismatch" when @() is used to
    # convert a generic List[object] at the WinForms click-handler boundary.
    $matches = @()
    $seen = @{}
    $pidFile = Join-Path $InstallRoot "runtime\comfyui.pid"
    if (Test-Path -LiteralPath $pidFile) {
        $rawPid = (Get-Content -LiteralPath $pidFile -Raw -ErrorAction SilentlyContinue).Trim()
        $pidValue = 0
        if ([int]::TryParse($rawPid, [ref]$pidValue) -and $pidValue -gt 0) {
            $process = Get-Process -Id $pidValue -ErrorAction SilentlyContinue
            if ($process) {
                $belongsToInstall = $false
                try {
                    $belongsToInstall = $process.Path -and $process.Path.StartsWith($InstallRoot, [StringComparison]::OrdinalIgnoreCase)
                } catch {
                    # An inaccessible path is not sufficient evidence that a stale PID belongs to this install.
                    $belongsToInstall = $false
                }
                if ($belongsToInstall) {
                    $matches += $process
                    $seen[[int]$process.Id] = $true
                } else {
                    Add-Log "Ignoring stale ComfyUI PID file entry $pidValue because that process does not belong to this installation." "WARN"
                }
            }
        }
    }

    foreach ($process in @(Get-Process python,pythonw -ErrorAction SilentlyContinue)) {
        if ($seen.ContainsKey([int]$process.Id)) { continue }
        try {
            if ($process.Path -and $process.Path.StartsWith($InstallRoot, [StringComparison]::OrdinalIgnoreCase)) {
                $matches += $process
                $seen[[int]$process.Id] = $true
            }
        } catch {
            # Ignore processes whose executable path cannot be inspected.
        }
    }
    return $matches
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
            # User/model/plugin data is outside the core refresh contract. Do not
            # merge, overwrite, or add anything inside these protected locations.
            if ($entry.PSIsContainer -and $entry.Name -in $protectedDirectories) { continue }
            if (-not $entry.PSIsContainer -and $entry.Name -in $protectedFiles -and (Test-Path -LiteralPath (Join-Path $comfyRoot $entry.Name))) { continue }
            Copy-Item -LiteralPath $entry.FullName -Destination $comfyRoot -Recurse -Force
        }
        if (-not (Test-Path -LiteralPath (Join-Path $comfyRoot "main.py"))) { throw "Refreshed ComfyUI source is missing main.py." }
        Add-Log "Existing ComfyUI core was refreshed from a clean staged copy. Protected directories were left untouched: $($protectedDirectories -join ', '). Preserved root files: $($protectedFiles -join ', ')."
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

    $output = @(& $script:InstallComfyEnvironmentBeforeUpgradePostCheck @PSBoundParameters)
    $environment = Resolve-ComfyEnvironmentResult -Output $output

    # ComfyUI requirements are installed after the first acceleration repair.
    # Re-run the exact acceleration check here so a transitive requirement cannot
    # silently replace Triton/SageAttention, and so the compatibility channel
    # removes any CUDA-13-only acceleration packages introduced by dependencies.
    Set-Stage "Final acceleration runtime check" -1
    Install-SageAttentionRuntime -Python $environment.Python -InstallRoot $InstallRoot

    Set-Stage "Final Python dependency consistency check" -1
    $null = Invoke-ProcessChecked $environment.Python "-m pip check" $environment.ComfyRoot
    return $environment
}
