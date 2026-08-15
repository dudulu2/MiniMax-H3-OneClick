$script:InvokePipWithFallbackBeforeLocalWheelhouse = (Get-Command Invoke-PipWithFallback -CommandType Function).ScriptBlock
$script:InvokeBasePyPiWithFallbackBeforeLocalWheelhouse = (Get-Command Invoke-BasePyPiWithFallback -CommandType Function).ScriptBlock

function Get-Step1DependencyWheelhouse {
    $path = Join-Path $script:AssetsRoot "wheels\dependencies"
    if (-not (Test-Path -LiteralPath $path -PathType Container)) { return $null }
    $wheels = @(Get-ChildItem -LiteralPath $path -Filter "*.whl" -File -ErrorAction SilentlyContinue)
    if ($wheels.Count -eq 0) { return $null }
    return $path
}

function Invoke-Step1LocalWheelAttempt {
    param(
        [string]$Python,
        [string]$PackageArguments,
        [string]$Label
    )

    $wheelhouse = Get-Step1DependencyWheelhouse
    if (-not $wheelhouse) { return $false }

    Add-Log "Trying local Step 1 dependency wheelhouse first for ${Label}: $wheelhouse"
    $arguments = "-m pip $PackageArguments --no-index --find-links `"$wheelhouse`" --disable-pip-version-check"
    $exitCode = Invoke-ProcessChecked $Python $arguments $script:InstallerRoot -AllowFailure
    if ($exitCode -eq 0) {
        Add-Log "Local Step 1 dependency wheelhouse satisfied $Label."
        return $true
    }

    Add-Log "Local Step 1 wheelhouse could not satisfy $Label completely; continuing with configured package sources." "WARN"
    return $false
}

function Invoke-PipWithFallback {
    param([string]$Python, [string]$PackageArguments, [switch]$NeedsTorchIndex)

    if (Invoke-Step1LocalWheelAttempt -Python $Python -PackageArguments $PackageArguments -Label "pip requirements") {
        return
    }

    & $script:InvokePipWithFallbackBeforeLocalWheelhouse -Python $Python -PackageArguments $PackageArguments -NeedsTorchIndex:$NeedsTorchIndex
}

function Invoke-BasePyPiWithFallback {
    param([string]$Python, [string]$PackageArguments)

    if (Invoke-Step1LocalWheelAttempt -Python $Python -PackageArguments $PackageArguments -Label "Python package requirements") {
        return
    }

    & $script:InvokeBasePyPiWithFallbackBeforeLocalWheelhouse -Python $Python -PackageArguments $PackageArguments
}

# This file is sourced immediately after hardware_profiles_install.ps1, so it is
# also the Step 1 local-assets extension point. Load the model wrapper here so
# local model discovery is installed after the profile-aware Install-H3Models
# function exists, without changing the base interactive installer script.
$localModelBundleScript = Join-Path $script:AssetsRoot "local_model_bundle.ps1"
if (-not (Test-Path -LiteralPath $localModelBundleScript -PathType Leaf)) {
    throw "Local model bundle support script is missing: $localModelBundleScript"
}
. $localModelBundleScript
