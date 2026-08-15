$script:InstallH3ModelsBeforeLocalModelBundle = (Get-Command Install-H3Models -CommandType Function).ScriptBlock

function Install-H3Models {
    param(
        [string]$ComfyRoot,
        [string]$Python,
        [string]$InstallRoot,
        $Profile
    )

    $helper = Join-Path $script:AssetsRoot "local_model_bundle.py"
    if (-not (Test-Path -LiteralPath $helper -PathType Leaf)) {
        throw "Local model bundle helper is missing: $helper"
    }

    # InstallerRoot is step1-installer. Its parent is the extracted package
    # folder (for example, '懒人安装或更新'). Search only that tree; never scan
    # whole drives for large model files.
    $bundleRoot = Split-Path -Parent $script:InstallerRoot
    if ([string]::IsNullOrWhiteSpace($bundleRoot) -or -not (Test-Path -LiteralPath $bundleRoot -PathType Container)) {
        throw "Could not determine the one-click package root for local model discovery."
    }

    Set-Stage "Checking the installer package for local MiniMax H3 models" -1
    Add-Log "Local model priority: checking installer package before Hugging Face downloads: $bundleRoot"

    $arguments = @(
        "`"$helper`"",
        "--bundle-root `"$bundleRoot`"",
        "--comfy-root `"$ComfyRoot`"",
        "--catalog `"$script:CatalogPath`"",
        "--profiles `"$script:ProfilesPath`"",
        "--profile `"$($Profile.id)`""
    ) -join " "
    $null = Invoke-ProcessChecked $Python $arguments $script:InstallerRoot

    # Always run the normal downloader afterwards. It performs the authoritative
    # SHA-256 check on the installed destination, skips valid local files, keeps
    # resumable partial files, and uses the network only for models still absent.
    & $script:InstallH3ModelsBeforeLocalModelBundle @PSBoundParameters
}
