# ==========================
# Monitor-App-Registry.ps1
# ==========================
# Automatically elevates to Administrator if not already.
# Reads executable paths from registry (HYP-global or HYP-cn).
# Monitors the process, runs a command when it starts,
# and another when it stops. Updates registry on app close.
# ==========================

# --- Check for Administrator privileges ---
if (-not ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")) {
    Write-Host "⚠️  Restarting script as Administrator..."
    Start-Process powershell -Verb runAs -ArgumentList "-File `"$PSCommandPath`""
    exit
}

# --- REGISTRY PATHS ---
$RegPaths = @(
    "HKCU:\Software\Classes\HYP-global\shell\open\command",
    "HKCU:\Software\Classes\HYP-cn\shell\open\command"
)

# --- CONFIGURATION ---
$AppName = "HYP.exe"
$wasRunning = $false
$runningAppPath = $null
$sourceRegPath = $null

# --- ACTIVE REGISTRY PATHS ---
# Determine which registry entries actually exist. If none exist, exit 0.
$AvailableRegPaths = @()
foreach ($p in $RegPaths) {
    if (Test-Path $p) {
        $AvailableRegPaths += $p
    }
}

if ($AvailableRegPaths.Count -eq 0) {
    Clear-Host
    Write-Host "⚠️  No HYP registry entries found (checked: $($RegPaths -join ', ')). Exiting." -ForegroundColor Yellow
    exit 0
}

# Replace RegPaths with available ones so the rest of the script monitors only existing keys
$RegPaths = $AvailableRegPaths
Write-Host "🔍 Monitoring registry paths: $($RegPaths -join ', ')" -ForegroundColor Cyan

# --- HELPER FUNCTIONS ---
function Get-ExecutableFromRegistry {
    <#
    .SYNOPSIS
    Attempts to extract executable path from registry command value.
    Expected format: "C:\Path\to\app.exe" "--url=%1" [other args]
    #>
    param([string]$CommandValue)
    
    # Extract the quoted executable path
    if ($CommandValue -match '^"([^"]+)"') {
        return $matches[1]
    }
    return $null
}

function Get-ApplicationDirectory {
    <#
    .SYNOPSIS
    Extracts the application base directory from an executable path.
    Handles version-based subdirectories (e.g., C:\Program Files\Games\HoYoPlay\1.11.2.301\HYP.exe)
    Returns the version directory (e.g., C:\Program Files\Games\HoYoPlay\1.11.2.301)
    #>
    param([string]$ExecutablePath)
    
    if ([string]::IsNullOrEmpty($ExecutablePath)) {
        return $null
    }
    
    # Get the directory containing the executable
    $directory = Split-Path -Path $ExecutablePath -Parent
    return $directory
}

function Get-RunningAppExecutable {
    <#
    .SYNOPSIS
    Gets the full path of the running HYP.exe process.
    #>
    $process = Get-Process -Name ($AppName -replace ".exe", "") -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($process) {
        return $process.Path
    }
    return $null
}

function Read-RegistryExecutables {
    <#
    .SYNOPSIS
    Reads executable paths from both registry locations and converts them to directories.
    Returns hashtable with registry paths and their application directories.
    #>
    $results = @{}

    foreach ($regPath in $RegPaths) {
        try {
            $exePath = $null
            $appDir = $null

            $item = Get-ItemProperty -Path $regPath -Name "(Default)" -ErrorAction SilentlyContinue
            if ($item -and $item."(Default)") {
                $exePath = Get-ExecutableFromRegistry -CommandValue $item."(Default)"
                $appDir = Get-ApplicationDirectory -ExecutablePath $exePath
                Write-Host "📋 Registry ($regPath):" -ForegroundColor Gray
                Write-Host "   Exe: $exePath" -ForegroundColor Gray
                Write-Host "   Dir: $appDir" -ForegroundColor Gray
            }
            else {
                Write-Host "📋 Registry ($regPath): value missing or empty" -ForegroundColor Gray
            }

            # Always populate the results table to avoid null lookup errors later
            $results[$regPath] = @{
                ExecutablePath = $exePath
                Directory      = $appDir
            }
        }
        catch {
            Write-Host "⚠️  Error reading $regPath : $_" -ForegroundColor Yellow
            $results[$regPath] = $null
        }
    }
    
    return $results
}

function Start-HoYoPassSetup {
    <#
    .SYNOPSIS
    Main logic to enable HoYoPass via WebSocket.
    Retries once if no DevTools pages are found.
    #>
    Clear-Host
    Write-Host "✅ $AppName started at: $runningAppPath" -ForegroundColor Green
    Write-Host "🔌 Enabling HoYoPass..."
    Start-Sleep -Seconds 1
    
    # Requires PowerShell 7+
    # Make sure WebSocket Client APIs are available (they are by default in .NET Core)

    # 1️⃣ Fetch JSON list (with retry)
    $retryCount = 0
    $maxRetries = 1
    $pages = $null
    
    while ($retryCount -le $maxRetries -and -not $pages) {
        try {
            if ($retryCount -gt 0) {
                Write-Host "🔄 Retry attempt $retryCount..." -ForegroundColor Yellow
                Start-Sleep -Seconds 2
            }
            $pages = Invoke-RestMethod -Uri "http://localhost:9222/json/list"
        }
        catch {
            Write-Host "❌ Failed to fetch DevTools pages (attempt $($retryCount + 1)): $_" -ForegroundColor Red
            $retryCount++
        }
    }

    if (-not $pages) {
        Write-Host "❌ No DevTools pages found after $($maxRetries + 1) attempts." -ForegroundColor Red
        Write-Host "⏳ Continuing to monitor - will retry when app restarts." -ForegroundColor Yellow
        return
    }

    $page = $pages[0]
    $wsUrl = $page.webSocketDebuggerUrl
    $originalUrl = $page.url
    # Write-Host "🌐 Original URL: $originalUrl"

    # 2️⃣ Parse and modify the query params
    $uri = [System.Uri]$originalUrl
    $queryParams = [System.Web.HttpUtility]::ParseQueryString($uri.Query)

    # Modify payload
    $queryParams["useLogin"] = "true"
    $queryParams["useMultiAccount"] = "true"

    # Rebuild the new URL
    $builder = [System.UriBuilder]$uri
    $builder.Query = $queryParams.ToString()
    $newUrl = $builder.Uri.AbsoluteUri
    # Write-Host "➡️ Redirecting to: $newUrl"

    # 3️⃣ Connect to the WebSocket
    try {
        $client = [System.Net.WebSockets.ClientWebSocket]::new()
        $uri = [System.Uri]$wsUrl
        $client.ConnectAsync($uri, [Threading.CancellationToken]::None).Wait()
    }
    catch {
        Write-Host "❌ Failed to connect to WebSocket: $_" -ForegroundColor Red
        return
    }

    # Send JSON messages
    function Send-WSMessage($client, $obj) {
        $json = ($obj | ConvertTo-Json -Compress)
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
        $segment = [ArraySegment[byte]]::new($bytes)
        $client.SendAsync($segment, [System.Net.WebSockets.WebSocketMessageType]::Text, $true, [Threading.CancellationToken]::None).Wait()
    }

    # Enable Page domain
    Send-WSMessage $client @{ id = 1; method = "Page.enable" }

    # Navigate to new URL
    Send-WSMessage $client @{
        id     = 2
        method = "Page.navigate"
        params = @{ url = $newUrl }
    }

    # 4️⃣ Wait for confirmation (optional)
    $buffer = New-Object Byte[] 4096
    $result = $client.ReceiveAsync([ArraySegment[byte]]::new($buffer), [Threading.CancellationToken]::None).Result
    $response = [System.Text.Encoding]::UTF8.GetString($buffer, 0, $result.Count)
    
    try {
        $respObj = $response | ConvertFrom-Json -ErrorAction Stop
        if ($respObj.result) {
            Write-Host "✅ Navigation OK — frameId=$($respObj.result.frameId) loaderId=$($respObj.result.loaderId)" -ForegroundColor Green
        }
        elseif ($respObj.error) {
            Write-Host "❌ DevTools error: $($respObj.error.message)" -ForegroundColor Red
        }
        else {
            Write-Host "ℹ️ DevTools response: $response" -ForegroundColor Gray
        }
    }
    catch {
        # Not valid JSON — print raw response
        Write-Host "ℹ️ Raw response: $response" -ForegroundColor Gray
    }

    # 5️⃣ Disconnect
    $client.Dispose()
    Write-Host "🔌 Disconnected." -ForegroundColor Cyan
}

function Restore-RegistryOnAppClose {
    <#
    .SYNOPSIS
    Restores both registry entries (HYP-global and HYP-cn).
    Adds --remote-debugging-port=9222 back to any entries that are missing it.
    #>
    Clear-Host
    Write-Host "🛑 $AppName closed" -ForegroundColor Red
    
    # Check and update both registry paths
    foreach ($regPath in $RegPaths) {
        try {
            Write-Host ""
            Write-Host "📋 Checking registry: $regPath" -ForegroundColor Cyan
            
            # Read current registry value
            $item = Get-ItemProperty -Path $regPath -Name "(Default)" -ErrorAction SilentlyContinue
            if (-not $item) {
                Write-Host "   ⚠️  Registry key not found" -ForegroundColor Yellow
                continue
            }
            
            $currentValue = $item."(Default)"
            
            if (-not $currentValue) {
                Write-Host "   ⚠️  No value in registry" -ForegroundColor Yellow
                continue
            }
            
            # Check if remote-debugging-port is already present
            if ($currentValue -match '--remote-debugging-port') {
                Write-Host "   ✅ Already has remote debugging port" -ForegroundColor Green
                continue
            }
            
            # Extract executable and arguments
                    if ($currentValue -match '^"([^"]+)"') {
                        $exePath = $matches[1]
                        $newValue = ('"{0}" "{1}" "{2}"' -f $exePath, '--url=%1', '--remote-debugging-port=9222')
                    } else {
                        # Fallback: add with quotes, preserving existing args
                        $newValue = ('"{0}" "{1}" "{2}"' -f $currentValue, '--url=%1', '--remote-debugging-port=9222')
            }
            
            Write-Host "   📝 Updating..." -ForegroundColor Cyan
            Write-Host "      Old: $currentValue"
            Write-Host "      New: $newValue"
            
            Set-ItemProperty -Path $regPath -Name "(Default)" -Value $newValue
            Write-Host "   ✅ Registry updated successfully" -ForegroundColor Green
        }
        catch {
            Write-Host "   ❌ Error updating $regPath : $_" -ForegroundColor Red
        }
    }
    
    Write-Host ""
    Write-Host "✅ Registry restoration complete." -ForegroundColor Green
}

# --- INITIAL STATUS ---
Clear-Host
Write-Host "🔍 Starting Monitor with Registry-based Configuration..." -ForegroundColor Cyan
Write-Host "📌 Supported Registry Paths:" -ForegroundColor Cyan
foreach ($path in $RegPaths) {
    Write-Host "   - $path" -ForegroundColor Gray
}
Write-Host "Press Ctrl + C to stop." -ForegroundColor Yellow
Write-Host ""

# Initial read of registry executables
$registryExecutables = Read-RegistryExecutables
Write-Host ""

while ($true) {
    try {
        $isRunning = Get-Process -Name ($AppName -replace ".exe", "") -ErrorAction SilentlyContinue | Select-Object -First 1

        if ($isRunning -and -not $wasRunning) {
            # App just started - verify the running application is HYP.exe from HoYoPlay directory
            $wasRunning = $true
            $runningAppPath = $isRunning.Path
            $runningAppDir = Get-ApplicationDirectory -ExecutablePath $runningAppPath
            
            Write-Host ""
            Write-Host "🚀 Process detected: $runningAppPath" -ForegroundColor Yellow
            Write-Host "   Directory: $runningAppDir" -ForegroundColor Yellow
            
            # Verify it's from HoYoPlay installation (contains 'HoYoPlay' in path)
            # Verify it's from HoYoPlay or miHoYo Launcher installation
            if ($runningAppDir -like "*HoYoPlay*" -or $runningAppDir -like "*miHoYo Launcher*") {
                Write-Host "✅ Valid HoYoPlay/miHoYo Launcher installation detected" -ForegroundColor Green
                
                # Identify which registry entry this corresponds to
                foreach ($regPath in $RegPaths) {
                    $regEntry = $registryExecutables[$regPath]
                    if ($null -eq $regEntry) { continue }
                    $regDir = $regEntry.Directory

                    if ($regDir -and ($runningAppDir -eq $regDir)) {
                        $sourceRegPath = $regPath
                        Write-Host "   Registry source: $regPath" -ForegroundColor Cyan
                        break
                    }
                }
                
                # If no exact match found, use the first available registry path
                if (-not $sourceRegPath) {
                    $sourceRegPath = $RegPaths[0]
                    Write-Host "   Registry source: $sourceRegPath (default)" -ForegroundColor Cyan
                }
                
                Start-HoYoPassSetup
            } else {
                Write-Host "❌ Running app is not from HoYoPlay or miHoYo Launcher installation." -ForegroundColor Red
                $wasRunning = $false
            }
        }
        elseif (-not $isRunning -and $wasRunning) {
            # App just stopped
            $wasRunning = $false
            Restore-RegistryOnAppClose
            
            # Refresh registry entries
            $registryExecutables = Read-RegistryExecutables
            $runningAppPath = $null
            $sourceRegPath = $null
            Write-Host ""
        }
    }
    catch {
        Write-Host "⚠️  Error in monitoring loop: $_" -ForegroundColor Yellow
    }

    Start-Sleep -Seconds 5
}
