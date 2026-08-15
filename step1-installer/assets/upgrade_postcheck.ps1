$script:InstallComfyEnvironmentBeforeUpgradePostCheck = (Get-Command Install-ComfyEnvironment -CommandType Function).ScriptBlock

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
                $belongsToInstall = $false
                try {
                    $belongsToInstall = $process.Path -and $process.Path.StartsWith($InstallRoot, [StringComparison]::OrdinalIgnoreCase)
                } catch {
                    # An inaccessible path is not sufficient evidence that a stale PID belongs to this install.
                    $belongsToInstall = $false
                }
                if ($belongsToInstall) {
                    [void]$matches.Add($process)
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
                [void]$matches.Add($process)
                $seen[[int]$process.Id] = $true
            }
        } catch {
            # Ignore processes whose executable path cannot be inspected.
        }
    }
    return @($matches)
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
