#requires -version 5.1

[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Windows.Forms

$repoRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$step1Script = Join-Path $repoRoot "step1-installer\Start-Installer.ps1"
$step2Root = Join-Path $repoRoot "step2-plugin-pack"
$step2Bat = Join-Path $step2Root "Install-Plugins-Safe.bat"
$rootLog = Join-Path $repoRoot "one-click-install.log"

function Decode-Utf8Base64 {
    param([string]$Value)
    return [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($Value))
}

function Write-OneClickLog {
    param([string]$Message, [string]$Level = "INFO")
    $line = "[{0}] [{1}] {2}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Level, $Message
    Write-Host $line
    try { Add-Content -LiteralPath $rootLog -Value $line -Encoding UTF8 } catch { }
}

function Show-FailureDialog {
    param([string]$Message)
    $title = Decode-Utf8Base64 "5a6J6KOF6YGH5Yiw6Zeu6aKY"
    [Windows.Forms.MessageBox]::Show($Message, $title, "OK", "Error") | Out-Null
}

function Resolve-OneClickInstallRoot {
    if (-not [string]::IsNullOrWhiteSpace($env:MINIMAX_H3_ROOT)) {
        return [IO.Path]::GetFullPath($env:MINIMAX_H3_ROOT)
    }
    if (Test-Path "D:\") { return "D:\MiniMaxH3" }
    return (Join-Path $env:LOCALAPPDATA "MiniMaxH3")
}

function Get-Step1FailureReason {
    param([int]$Code)
    switch ($Code) {
        20 { return (Decode-Utf8Base64 "56Gs5Lu2L+WuieijhemFjee9ruajgOafpeacqumAmui/hw==") }
        21 { return (Decode-Utf8Base64 "6buY6K6k5a6J6KOF55uu5b2V6Z2e56m677yM5L2G5LiN5piv5bey6K+G5Yir55qEIE1pbmlNYXggSDMg5a6J6KOF77yb5Li65LqG5a6J5YWo5rKh5pyJ6KaG55uW") }
        1  { return (Decode-Utf8Base64 "U3RlcCAxIOWuieijhei/h+eoi+Wksei0pQ==") }
        default { return (Decode-Utf8Base64 "U3RlcCAxIOWQr+WKqOaIluWuieijheW8guW4uA==") }
    }
}

function Get-LatestStep2Log {
    param([string]$InstallRoot)
    $logRoot = Join-Path $InstallRoot "logs"
    if (-not (Test-Path -LiteralPath $logRoot -PathType Container)) { return $null }
    return Get-ChildItem -LiteralPath $logRoot -Filter "plugin-install-safe-*.log" -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1
}

try {
    Remove-Item -LiteralPath $rootLog -Force -ErrorAction SilentlyContinue

    $missing = @()
    foreach ($required in @($step1Script, $step2Bat)) {
        if (-not (Test-Path -LiteralPath $required -PathType Leaf)) { $missing += $required }
    }
    if ($missing.Count -gt 0) {
        $template = Decode-Utf8Base64 "5a6J6KOF5YyF5paH5Lu25LiN5a6M5pW077yaDQp7MH0NCg0K6K+36YeN5paw6Kej5Y6L5a6M5pW05a6J6KOF5YyF44CC"
        Show-FailureDialog ($template -f ($missing -join [Environment]::NewLine))
        exit 10
    }

    $installRoot = Resolve-OneClickInstallRoot
    $env:MINIMAX_H3_ROOT = $installRoot
    Write-OneClickLog "Repository root: $repoRoot"
    Write-OneClickLog "Installation root: $installRoot"

    $step1RuntimeWheels = @(Get-ChildItem -LiteralPath (Join-Path $repoRoot "step1-installer\assets\wheels") -Filter "*.whl" -File -ErrorAction SilentlyContinue)
    $step1DependencyWheels = @(Get-ChildItem -LiteralPath (Join-Path $repoRoot "step1-installer\assets\wheels\dependencies") -Filter "*.whl" -File -ErrorAction SilentlyContinue)
    $step2DependencyWheels = @(Get-ChildItem -LiteralPath (Join-Path $repoRoot "step2-plugin-pack\wheels\dependencies") -Filter "*.whl" -File -ErrorAction SilentlyContinue)
    Write-OneClickLog "Local wheel inventory: Step1 runtime=$($step1RuntimeWheels.Count), Step1 dependencies=$($step1DependencyWheels.Count), Step2 dependencies=$($step2DependencyWheels.Count)."

    Write-OneClickLog "Starting Step 1 in unattended mode. The normal progress window remains visible and can still be cancelled."
    $previousPreference = $ErrorActionPreference
    try {
        # Native stderr can contain harmless warnings under Windows PowerShell 5.1.
        # The child process exit code is the authoritative result.
        $ErrorActionPreference = "Continue"
        & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -STA -File $step1Script -AutoInstall -InstallRoot $installRoot
        $step1Code = [int]$LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previousPreference
    }

    Write-OneClickLog "Step 1 exit code: $step1Code"
    if ($step1Code -ne 0) {
        $reason = Get-Step1FailureReason -Code $step1Code
        $step1Log = Join-Path $installRoot "logs\step1-oneclick-latest.log"
        if (-not (Test-Path -LiteralPath $step1Log -PathType Leaf)) {
            $step1Log = Decode-Utf8Base64 "5pyq55Sf5oiQ5pel5b+X44CC5Y+v5Y2V54us6L+Q6KGMIHN0ZXAxLWluc3RhbGxlclxTdGFydC1JbnN0YWxsZXIuYmF0IOafpeeci+ehrOS7tuajgOafpeWSjOivpue7huS/oeaBr+OAgg=="
        }
        $template = Decode-Utf8Base64 "U3RlcCAxIOaguOW/g+eOr+Wig+acquWujOaIkO+8jFN0ZXAgMiDmsqHmnInov5DooYzjgIINCg0K5Y6f5Zug77yaezB9DQrplJnor6/ku6PnoIHvvJp7MX0NCuWuieijheebruW9le+8mnsyfQ0KDQrml6Xlv5fvvJp7M30="
        Show-FailureDialog ($template -f $reason, $step1Code, $installRoot, $step1Log)
        exit $step1Code
    }

    Write-OneClickLog "Step 1 completed. Starting Step 2 plugin installation."
    Push-Location $step2Root
    try {
        $previousPreference = $ErrorActionPreference
        try {
            $ErrorActionPreference = "Continue"
            & $env:ComSpec /d /c "Install-Plugins-Safe.bat --no-pause"
            $step2Code = [int]$LASTEXITCODE
        } finally {
            $ErrorActionPreference = $previousPreference
        }
    } finally {
        Pop-Location
    }

    Write-OneClickLog "Step 2 exit code: $step2Code"
    if ($step2Code -ne 0) {
        $latestLog = Get-LatestStep2Log -InstallRoot $installRoot
        $logText = if ($latestLog) { $latestLog.FullName } else { Join-Path $installRoot "logs" }
        $template = Decode-Utf8Base64 "U3RlcCAxIOW3suWujOaIkO+8jOS9hiBTdGVwIDIg5o+S5Lu25a6J6KOF5oiW6aqM6K+B5aSx6LSl44CCDQoNCumUmeivr+S7o+egge+8mnswfQ0K5a6J6KOF55uu5b2V77yaezF9DQoNCuWPr+S7peS/ruWkjemXrumimOWQjuWGjeasoeWPjOWHu+KAnOS4gOmUruWuieijhS5iYXTigJ3vvIxTdGVwIDEg5Lya6Ieq5Yqo6K+G5Yir546w5pyJ5a6J6KOF5bm25L+u5aSNL+i3s+i/h+W3suWujOaIkOmDqOWIhuOAgg0KDQrml6Xlv5fvvJp7Mn0="
        Show-FailureDialog ($template -f $step2Code, $installRoot, $logText)
        exit (100 + $step2Code)
    }

    $launcher = Join-Path $installRoot "Start MiniMax H3.bat"
    Write-OneClickLog "Both steps completed successfully. Launcher: $launcher"

    $successTitle = Decode-Utf8Base64 "5bey5a6M5oiQ5a6J6KOF"
    $successTemplate = Decode-Utf8Base64 "TWluaU1heCBIMyDlt7LlrozmiJDlronoo4XvvIENCg0KU3RlcCAxIOaguOW/g+eOr+Wig++8muaIkOWKnw0KU3RlcCAyIOaPkuS7tu+8muaIkOWKnw0KDQrlronoo4Xnm67lvZXvvJp7MH0NCg0K5piv5ZCm546w5Zyo5ZCv5YqoIE1pbmlNYXggSDPvvJ8="
    $choice = [Windows.Forms.MessageBox]::Show(($successTemplate -f $installRoot), $successTitle, "YesNo", "Information")
    if ($choice -eq [Windows.Forms.DialogResult]::Yes -and (Test-Path -LiteralPath $launcher -PathType Leaf)) {
        Start-Process -FilePath $launcher -WorkingDirectory $installRoot
    }
    exit 0
} catch {
    Write-OneClickLog $_.Exception.Message "ERROR"
    Show-FailureDialog ("Unexpected one-click installer error:`r`n`r`n" + $_.Exception.Message + "`r`n`r`nLog: " + $rootLog)
    exit 199
}
