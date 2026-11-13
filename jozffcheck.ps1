



<#
.SYNOPSIS
    Audits local system details, exports an HTML report, opens it in Google Chrome,
    and optionally deletes local Chrome browsing history upon Y/N confirmation.
.NOTES
    Run as Administrator for complete results.
#>

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Warning "Please run this script as Administrator to access all registry keys and Wi-Fi profiles."
}

Write-Host "Gathering system audit data... Please wait." -ForegroundColor Cyan

# 1. USB & Mass Storage History
$usbHistory = @()
$usbStorPath = "HKLM:\SYSTEM\CurrentControlSet\Enum\USBSTOR"
if (Test-Path $usbStorPath) {
    $usbHistory = Get-ChildItem -Path $usbStorPath | ForEach-Object {
        $deviceClass = $_.PSChildName
        Get-ChildItem -Path $_.PSPath | ForEach-Object {
            $props = Get-ItemProperty -Path $_.PSPath
            [PSCustomObject]@{
                DeviceName   = $props.FriendlyName
                HardwareID   = $deviceClass
                SerialNumber = $_.PSChildName
            }
        }
    }
}

# Currently Connected USB Devices
$connectedUsb = Get-PnpDevice -PresentOnly | Where-Object { $_.InstanceId -match "^USB" } | 
    Select-Object Status, Class, FriendlyName, InstanceId

# 2. Wi-Fi Profiles & Passwords (Safe for PCs without Wi-Fi)
$wifiResults = try {
    $profiles = netsh wlan show profiles 2>$null | Select-String "\:(.+)$" | ForEach-Object { $_.Matches.Groups[1].Value.Trim() }
    foreach ($profile in $profiles) {
        $profileInfo = netsh wlan show profile name="$profile" key=clear 2>$null
        $passwordLine = $profileInfo | Select-String "Key Content\W+\:(.+)$"
        $password = if ($passwordLine) { $passwordLine.Matches.Groups[1].Value.Trim() } else { "None / Open / Enterprise" }
        [PSCustomObject]@{ SSID = $profile; Password = $password }
    }
} catch { @() }

# 3. Bluetooth Devices (Compatible fallback)
$bluetoothDevices = Get-PnpDevice -Class Bluetooth -ErrorAction SilentlyContinue | Select-Object Status, FriendlyName, InstanceId

# 4. Installed Software (64-bit, 32-bit, and Current User Registry)
$uninstallPaths = @(
    "HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*",
    "HKLM:\Software\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*",
    "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*"
)
$installedSoftware = Get-ItemProperty $uninstallPaths -ErrorAction SilentlyContinue |
    Where-Object { $_.DisplayName } |
    Select-Object DisplayName, DisplayVersion, Publisher |
    Sort-Object DisplayName -Unique

# 5. Google Chrome History (Safe file handling)
$chromeUserDataPath = "$env:LOCALAPPDATA\Google\Chrome\User Data\Default"
$chromeHistoryPath  = "$chromeUserDataPath\History"
$tempHistoryPath    = "$env:TEMP\ChromeHistoryCopy"
$chromeUrls         = @()

if (Test-Path $chromeHistoryPath) {
    try {
        Copy-Item -Path $chromeHistoryPath -Destination $tempHistoryPath -Force -ErrorAction Stop
        $content = Get-Content -Path $tempHistoryPath -Raw -Encoding UTF8 -ErrorAction Stop
        $chromeUrls = [regex]::Matches($content, 'https?://[^\s\x00-\x1F"<>]+') | 
            ForEach-Object { $_.Value } | Select-Object -Unique | Select-Object -First 100 |
            ForEach-Object { [PSCustomObject]@{ ExtractedURL = $_ } }
    } catch {
        Write-Warning "Could not read Chrome history file."
    } finally {
        Remove-Item -Path $tempHistoryPath -Force -ErrorAction SilentlyContinue
    }
}

# ==========================================
# GENERATE HTML REPORT & OPEN IN CHROME
# ==========================================
function Export-AuditReport {
    param (
        [string]$OutputPath = "$env:USERPROFILE\Desktop\System_Audit_Report.html"
    )

    $css = @"
    <style>
        body { font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif; background-color: #f4f6f9; color: #333; margin: 20px; }
        h1 { color: #1a73e8; border-bottom: 2px solid #1a73e8; padding-bottom: 10px; }
        h2 { color: #202124; margin-top: 30px; background: #e8f0fe; padding: 8px 12px; border-left: 4px solid #1a73e8; }
        table { width: 100%; border-collapse: collapse; margin-top: 10px; background: #fff; box-shadow: 0 1px 3px rgba(0,0,0,0.1); }
        th, td { padding: 10px 12px; text-align: left; border-bottom: 1px solid #ddd; font-size: 14px; word-break: break-all; }
        th { background-color: #1a73e8; color: white; }
        tr:hover { background-color: #f1f3f4; }
        .meta { color: #5f6368; font-size: 13px; margin-bottom: 20px; }
    </style>
"@

    $htmlUsbPast     = if ($usbHistory) { $usbHistory | ConvertTo-Html -Fragment } else { "<p>No past USB storage history found.</p>" }
    $htmlUsbActive   = if ($connectedUsb) { $connectedUsb | ConvertTo-Html -Fragment } else { "<p>No active USB devices found.</p>" }
    $htmlWifi        = if ($wifiResults) { $wifiResults | ConvertTo-Html -Fragment } else { "<p>No saved Wi-Fi profiles found.</p>" }
    $htmlBluetooth   = if ($bluetoothDevices) { $bluetoothDevices | ConvertTo-Html -Fragment } else { "<p>No Bluetooth devices found.</p>" }
    $htmlSoftware    = if ($installedSoftware) { $installedSoftware | ConvertTo-Html -Fragment } else { "<p>No installed software found.</p>" }
    $htmlChrome      = if ($chromeUrls) { $chromeUrls | ConvertTo-Html -Fragment } else { "<p>No Chrome history found.</p>" }

    $reportContent = @"
    <!DOCTYPE html>
    <html>
    <head>
        <meta charset="UTF-8">
        <title>System Audit Report - $env:COMPUTERNAME</title>
        $css
    </head>
    <body>
        <h1>System & Device Audit Report</h1>
        <div class="meta">
            <strong>Computer Name:</strong> $env:COMPUTERNAME | 
            <strong>User:</strong> $env:USERNAME | 
            <strong>Generated On:</strong> $(Get-Date -Format "yyyy-MM-dd HH:mm:ss")
        </div>

        <h2>1. Past USB & Mass Storage Devices</h2>
        $htmlUsbPast

        <h2>2. Currently Connected USB & PnP Devices</h2>
        $htmlUsbActive

        <h2>3. Saved Wi-Fi Profiles & Passwords</h2>
        $htmlWifi

        <h2>4. Bluetooth Devices (Paired & Cached)</h2>
        $htmlBluetooth

        <h2>5. Installed Software</h2>
        $htmlSoftware

        <h2>6. Google Chrome History (Top 100 URLs)</h2>
        $htmlChrome
    </body>
    </html>
"@

    $reportContent | Out-File -FilePath $OutputPath -Encoding UTF8
    Write-Host "Report saved to: $OutputPath" -ForegroundColor Green

    # Open directly in Google Chrome if installed, otherwise fall back to default browser
    $chromePaths = @(
        "$env:ProgramFiles\Google\Chrome\Application\chrome.exe",
        "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe",
        "$env:LOCALAPPDATA\Google\Chrome\Application\chrome.exe"
    )
    $chromeExe = $chromePaths | Where-Object { Test-Path $_ } | Select-Object -First 1

    if ($chromeExe) {
        Start-Process -FilePath $chromeExe -ArgumentList "`"$OutputPath`""
    } else {
        Write-Warning "Google Chrome executable not found in standard paths. Opening in default browser..."
        Start-Process $OutputPath
    }
}

# ==========================================
# PROMPT TO DELETE BROWSER HISTORY
# ==========================================
function Invoke-ClearChromeHistory {
    param (
        [string]$ProfilePath
    )

    Write-Host ""
    do {
        $choice = Read-Host "Do you want to delete Google Chrome browsing history? (Y/N)"
    } until ($choice -match '^[YyNn]$')

    if ($choice -match '^[Yy]$') {
        $historyFiles = @(
            "$ProfilePath\History",
            "$ProfilePath\History-journal",
            "$ProfilePath\Visited Links"
        )

        # Check if Chrome is currently running (which locks the History SQLite database)
        $chromeProcs = Get-Process -Name "chrome" -ErrorAction SilentlyContinue
        if ($chromeProcs) {
            Write-Warning "Google Chrome is currently running and locking the history database."
            $closeChoice = Read-Host "Close all Chrome windows now to delete history? (Y/N)"
            if ($closeChoice -match '^[Yy]$') {
                Stop-Process -Name "chrome" -Force -ErrorAction SilentlyContinue
                Start-Sleep -Seconds 2
            } else {
                Write-Host "Aborted: Cannot delete history while Chrome is open." -ForegroundColor Yellow
                return
            }
        }

        $deletedAny = $false
        foreach ($file in $historyFiles) {
            if (Test-Path $file) {
                try {
                    Remove-Item -Path $file -Force -ErrorAction Stop
                    $deletedAny = $true
                } catch {
                    Write-Warning "Failed to delete $file : $_"
                }
            }
        }

        if ($deletedAny) {
            Write-Host "Google Chrome browsing history has been deleted." -ForegroundColor Green
        } else {
            Write-Host "No Chrome history files were found to delete." -ForegroundColor Yellow
        }
    } else {
        Write-Host "Browser history was kept intact." -ForegroundColor Cyan
    }
}

# Run the export and launch function
Export-AuditReport

# Ask Y/N to delete browser history
Invoke-ClearChromeHistory -ProfilePath $chromeUserDataPath
