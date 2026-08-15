#requires -version 5.1

[CmdletBinding()]
param(
    [switch]$AutoInstall,
    [string]$InstallRoot = ""
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$source = Join-Path $root "Install-MiniMaxH3.ps1"
$torchOverride = Join-Path $root "assets\local_torch_wheels.ps1"
$localDependencyWheelhouse = Join-Path $root "assets\local_dependency_wheelhouse.ps1"
$upgradeRepair = Join-Path $root "assets\upgrade_repair.ps1"
$upgradePostCheck = Join-Path $root "assets\upgrade_postcheck.ps1"
$cancellationOverride = Join-Path $root "assets\install_cancellation.ps1"
$mainModelSelector = Join-Path $root "assets\main_model_selector.ps1"
$runtimeSelector = Join-Path $root "assets\runtime_channel_selector.ps1"
$workflowOverride = Join-Path $root "assets\workflow_profile_fix.ps1"
$releaseVersionOverride = Join-Path $root "assets\release_version_override.ps1"
$patched = Join-Path $root ".Install-MiniMaxH3.runtime.ps1"

if (-not (Test-Path -LiteralPath $source)) { throw "Installer script is missing: $source" }
if (-not (Test-Path -LiteralPath $torchOverride)) { throw "Local wheel support script is missing: $torchOverride" }
if (-not (Test-Path -LiteralPath $localDependencyWheelhouse)) { throw "Local dependency wheelhouse support script is missing: $localDependencyWheelhouse" }
if (-not (Test-Path -LiteralPath $upgradeRepair)) { throw "Upgrade repair support script is missing: $upgradeRepair" }
if (-not (Test-Path -LiteralPath $upgradePostCheck)) { throw "Upgrade post-check support script is missing: $upgradePostCheck" }
if (-not (Test-Path -LiteralPath $cancellationOverride)) { throw "Installation cancellation script is missing: $cancellationOverride" }
if (-not (Test-Path -LiteralPath $mainModelSelector)) { throw "Main model selector script is missing: $mainModelSelector" }
if (-not (Test-Path -LiteralPath $runtimeSelector)) { throw "Runtime channel selector script is missing: $runtimeSelector" }
if (-not (Test-Path -LiteralPath $workflowOverride)) { throw "Workflow profile fix script is missing: $workflowOverride" }

if ($AutoInstall) {
    if ([string]::IsNullOrWhiteSpace($InstallRoot)) {
        $InstallRoot = if (Test-Path "D:\") { "D:\MiniMaxH3" } else { Join-Path $env:LOCALAPPDATA "MiniMaxH3" }
    }
    $InstallRoot = [IO.Path]::GetFullPath($InstallRoot)
}

function Replace-RequiredText {
    param(
        [string]$Text,
        [string]$Needle,
        [string]$Replacement,
        [string]$Label
    )
    if (-not $Text.Contains($Needle)) { throw "Could not locate installer patch point: $Label" }
    return $Text.Replace($Needle, $Replacement)
}

$text = Get-Content -LiteralPath $source -Raw

# Embed the one-click state directly into the temporary runtime script. The
# regular Step 1 entry point remains interactive; the root installer opts into
# this mode explicitly with -AutoInstall.
$autoFlag = if ($AutoInstall) { '$true' } else { '$false' }
$escapedInstallRoot = ([string]$InstallRoot).Replace("'", "''")
$bootstrap = @"
param([switch]`$SelfTest)
`$script:OneClickAutoInstall = $autoFlag
`$script:OneClickInstallRoot = '$escapedInstallRoot'
`$script:OneClickExitCode = 0
"@
$text = Replace-RequiredText -Text $text -Needle 'param([switch]$SelfTest)' -Replacement $bootstrap -Label "runtime parameter block"

$needle = '. (Join-Path $script:AssetsRoot "hardware_profiles_install.ps1")'
$replacementLines = @(
    $needle,
    '. (Join-Path $script:AssetsRoot "local_torch_wheels.ps1")',
    '. (Join-Path $script:AssetsRoot "local_dependency_wheelhouse.ps1")',
    '. (Join-Path $script:AssetsRoot "upgrade_repair.ps1")',
    '. (Join-Path $script:AssetsRoot "upgrade_postcheck.ps1")',
    '. (Join-Path $script:AssetsRoot "install_cancellation.ps1")',
    '. (Join-Path $script:AssetsRoot "main_model_selector.ps1")',
    '. (Join-Path $script:AssetsRoot "runtime_channel_selector.ps1")',
    '. (Join-Path $script:AssetsRoot "workflow_profile_fix.ps1")'
)
if (Test-Path -LiteralPath $releaseVersionOverride) {
    $replacementLines += '. (Join-Path $script:AssetsRoot "release_version_override.ps1")'
}
$replacement = $replacementLines -join [Environment]::NewLine
if (-not $text.Contains($needle)) { throw "Could not locate the installer extension point." }
$text = $text.Replace($needle, $replacement)

# Add the stop button only after the stage label exists, then wrap the normal
# Install / Repair click so cancellation state is reset before every run and the
# title-bar close button is guaranteed to return after the run finishes/stops.
$uiNeedle = '$form.Controls.Add($lblStage)'
$uiReplacement = $uiNeedle + [Environment]::NewLine + 'Initialize-InstallCancellationUI'
if (-not $text.Contains($uiNeedle)) { throw "Could not locate the installer status UI extension point." }
$text = $text.Replace($uiNeedle, $uiReplacement)

$clickNeedle = '$btnInstall.Add_Click({ Invoke-Install })'
$clickReplacement = '$btnInstall.Add_Click({ Begin-InstallCancellationUI; try { Invoke-Install } finally { Complete-InstallCancellationUI } })'
if (-not $text.Contains($clickNeedle)) { throw "Could not locate the Install / Repair click handler." }
$text = $text.Replace($clickNeedle, $clickReplacement)

# Older installs used a profile-only browser key. The main-model layer now
# rewrites the generated key to include the exact diffusion model and text
# encoder, so this compatibility replacement is harmless and still refreshes
# older profile keys before the final model-specific key is written.
$text = $text.Replace('minimax-h3-workflow-$($Profile.id)-v1', 'minimax-h3-workflow-$($Profile.id)-v2')

# One-click mode uses the same UI/runtime code but chooses the normal default
# target and recommended hardware profile automatically. It never silently
# writes into a non-empty folder that is not already a MiniMax H3 installation.
$pathNeedle = '$txtPath.Text = $defaultDrive'
$pathReplacement = '$txtPath.Text = if ($script:OneClickAutoInstall -and $script:OneClickInstallRoot) { $script:OneClickInstallRoot } else { $defaultDrive }'
$text = Replace-RequiredText -Text $text -Needle $pathNeedle -Replacement $pathReplacement -Label "default install path"

$hardwareBlockNeedle = '[Windows.Forms.MessageBox]::Show("Resolve the failed checks before installing.", "Cannot install", "OK", "Error") | Out-Null'
$hardwareBlockReplacement = 'if ($script:OneClickAutoInstall) { $script:OneClickExitCode = 20 } else { [Windows.Forms.MessageBox]::Show("Resolve the failed checks before installing.", "Cannot install", "OK", "Error") | Out-Null }'
$text = Replace-RequiredText -Text $text -Needle $hardwareBlockNeedle -Replacement $hardwareBlockReplacement -Label "hardware-block message"

$unsafeFolderNeedle = '$choice = [Windows.Forms.MessageBox]::Show("The selected folder is not empty and is not marked as a MiniMax H3 installation. Continue without deleting existing files?", "Folder is not empty", "YesNo", "Warning")'
$unsafeFolderReplacement = @'
if ($script:OneClickAutoInstall) {
                $script:OneClickExitCode = 21
                Add-Log "One-click mode refused a non-empty folder that is not marked as a MiniMax H3 installation: $installRoot" "ERROR"
                return
            }
            $choice = [Windows.Forms.MessageBox]::Show("The selected folder is not empty and is not marked as a MiniMax H3 installation. Continue without deleting existing files?", "Folder is not empty", "YesNo", "Warning")
'@
$text = Replace-RequiredText -Text $text -Needle $unsafeFolderNeedle -Replacement $unsafeFolderReplacement.TrimEnd() -Label "unsafe-folder confirmation"

$successLogNeedle = 'Add-Log "Installation completed successfully."'
$successLogReplacement = 'Add-Log "Installation completed successfully."' + [Environment]::NewLine + '        if ($script:OneClickAutoInstall) { $script:OneClickExitCode = 0 }'
$text = Replace-RequiredText -Text $text -Needle $successLogNeedle -Replacement $successLogReplacement -Label "success result"

$successMessageNeedle = '[Windows.Forms.MessageBox]::Show("MiniMax H3 is ready. Click ''Launch MiniMax H3'' to open the preconfigured workflow.", "Installation complete", "OK", "Information") | Out-Null'
$successMessageReplacement = 'if (-not $script:OneClickAutoInstall) { [Windows.Forms.MessageBox]::Show("MiniMax H3 is ready. Click ''Launch MiniMax H3'' to open the preconfigured workflow.", "Installation complete", "OK", "Information") | Out-Null }'
$text = Replace-RequiredText -Text $text -Needle $successMessageNeedle -Replacement $successMessageReplacement -Label "interactive success message"

$failureStageNeedle = 'Set-Stage "Installation stopped" 0'
$failureStageReplacement = 'Set-Stage "Installation stopped" 0' + [Environment]::NewLine + '        if ($script:OneClickAutoInstall) { $script:OneClickExitCode = 1 }'
$text = Replace-RequiredText -Text $text -Needle $failureStageNeedle -Replacement $failureStageReplacement -Label "failure result"

$failureMessageNeedle = '[Windows.Forms.MessageBox]::Show("Installation stopped:`n`n$($_.Exception.Message)`n`nPartial model downloads were kept and will resume next time.", "Installation failed", "OK", "Error") | Out-Null'
$failureMessageReplacement = 'if (-not $script:OneClickAutoInstall) { [Windows.Forms.MessageBox]::Show("Installation stopped:`n`n$($_.Exception.Message)`n`nPartial model downloads were kept and will resume next time.", "Installation failed", "OK", "Error") | Out-Null }'
$text = Replace-RequiredText -Text $text -Needle $failureMessageNeedle -Replacement $failureMessageReplacement -Label "interactive failure message"

$finallyNeedle = '$form.ControlBox = $true'
$finallyReplacement = @'
$form.ControlBox = $true
        if ($script:OneClickAutoInstall) {
            try {
                $oneClickLogRoot = Join-Path $installRoot "logs"
                New-Item -ItemType Directory -Force -Path $oneClickLogRoot | Out-Null
                $txtLog.Text | Set-Content -LiteralPath (Join-Path $oneClickLogRoot "step1-oneclick-latest.log") -Encoding UTF8
            } catch { }
        }
'@
$text = Replace-RequiredText -Text $text -Needle $finallyNeedle -Replacement $finallyReplacement.TrimEnd() -Label "one-click Step 1 log"

$showDialogNeedle = '[void]$form.ShowDialog()'
$showDialogReplacement = @'
if ($script:OneClickAutoInstall) {
    # Auto mode intentionally keeps the normal installer window visible for
    # progress/cancellation, but it does not require any clicks.
    $script:ProfileConfirmed = $true
    $form.Add_Shown({
        Begin-InstallCancellationUI
        try {
            Invoke-Install
        } finally {
            Complete-InstallCancellationUI
            $form.Close()
        }
    })
}

[void]$form.ShowDialog()
if ($script:OneClickAutoInstall) { exit [int]$script:OneClickExitCode }
'@
$text = Replace-RequiredText -Text $text -Needle $showDialogNeedle -Replacement $showDialogReplacement.TrimEnd() -Label "one-click form runner"

$text | Set-Content -LiteralPath $patched -Encoding UTF8

try {
    & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -STA -File $patched
    exit $LASTEXITCODE
} finally {
    Remove-Item -LiteralPath $patched -Force -ErrorAction SilentlyContinue
}
