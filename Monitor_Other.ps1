# ==========================
# Monitor-App.ps1
# ==========================
# Automatically elevates to Administrator if not already.
# Monitors a process, runs a command when it starts,
# and another when it stops.
# ==========================

# --- Check for Administrator privileges ---
if (-not ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")) {
    Write-Host "⚠️  Restarting script as Administrator..."
    Start-Process powershell -Verb runAs -ArgumentList "-File `"$PSCommandPath`""
    exit
}

# --- CONFIGURATION ---
$AppName = "HYP.exe"   # Process name (case-insensitive)
$OnStartCommand = { 
    Clear-Host
    Write-Host "✅ $AppName started — Enabling HoYoPass..."
    # Requires PowerShell 7+
    # Make sure WebSocket Client APIs are available (they are by default in .NET Core)

    # 1️⃣ Fetch JSON list
    $pages = Invoke-RestMethod -Uri "http://localhost:9222/json/list"

    if (-not $pages) {
        Write-Host "❌ No DevTools pages found."
        exit
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
    $client = [System.Net.WebSockets.ClientWebSocket]::new()
    $uri = [System.Uri]$wsUrl
    $client.ConnectAsync($uri, [Threading.CancellationToken]::None).Wait()

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
    Write-Host "✅ Response: $response"

    # 5️⃣ Disconnect
    $client.Dispose()
    Write-Host "🔌 Disconnected."
}
$OnStopCommand = { 
    Clear-Host
}

# --- INITIAL STATUS ---
$wasRunning = $false

Clear-Host
Write-Host "🔍 Monitoring $AppName (running as Administrator)..."
Write-Host "Press Ctrl + C to stop."

while ($true) {
    try {
        $isRunning = Get-Process -Name ($AppName -replace ".exe", "") -ErrorAction SilentlyContinue

        if ($isRunning -and -not $wasRunning) {
            $wasRunning = $true
            & $OnStartCommand
        }
        elseif (-not $isRunning -and $wasRunning) {
            $wasRunning = $false
            & $OnStopCommand
        }
    }
    catch {
        Write-Host "⚠️ Error: $_"
    }

    Start-Sleep -Seconds 5
}
