$URL_Protocol_Global = 'HKEY_CURRENT_USER\Software\Classes\HYP-global\shell\open\command'
$URL_Protocol_CN     = 'HKEY_CURRENT_USER\Software\Classes\HYP-cn\shell\open\command'

$Startup_String_Global = 'HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Run\HYP_1_0'
$Startup_String_CN     = 'HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Run\HYP_1_1'

# Default remote debugging port
$DefaultRemotePort = 9222

# COM object for shortcut handling
$WshShell = New-Object -ComObject WScript.Shell

function Get-RegistryDefaultValue {
    param($fullPath)
    $subPath = $fullPath -replace '^HKEY_CURRENT_USER\\',''
    $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($subPath)
    if ($null -eq $key) { return $null }
    try { return $key.GetValue('') } finally { $key.Close() }
}

function Set-RegistryDefaultValue {
    param($fullPath, $value)
    $subPath = $fullPath -replace '^HKEY_CURRENT_USER\\',''
    $key = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey($subPath)
    try { $key.SetValue('', $value) } finally { $key.Close() }
}

function Split-RegistryValuePathAndName {
    param($fullPath)
    # Given HKEY_CURRENT_USER\...\Run\MyValue return @{ KeyPath='Software...\Run'; ValueName='MyValue' }
    $trim = $fullPath -replace '^HKEY_CURRENT_USER\\',''
    $idx = $trim.LastIndexOf('\')
    if ($idx -lt 0) { return @{ KeyPath=$trim; ValueName='' } }
    return @{ KeyPath=$trim.Substring(0,$idx); ValueName=$trim.Substring($idx+1) }
}

function Parse-CommandString {
    param($cmd)
    # Returns @{ ExePath=..., Tokens = [string[]] }
    if (-not $cmd) { return $null }

    $cmd = $cmd.Trim()
    $exe = $null
    $rest = ''

    # Try quoted exe first
    $m = [regex]::Match($cmd, '^[\s]*"(?<exe>[^"]+\.exe)"(?<rest>.*)$', 'IgnoreCase')
    if ($m.Success) {
        $exe = $m.Groups['exe'].Value
        $rest = $m.Groups['rest'].Value.Trim()
    } else {
        # Try unquoted exe
        $m2 = [regex]::Match($cmd, '^[\s]*(?<exe>[^\s]+\.exe)(?<rest>.*)$', 'IgnoreCase')
        if ($m2.Success) {
            $exe = $m2.Groups['exe'].Value
            $rest = $m2.Groups['rest'].Value.Trim()
        }
    }

    # Tokenize rest (preserve quoted tokens)
    $tokens = @()
    if ($rest) {
        $matches = [regex]::Matches($rest, '("[^"]*"|\S+)')
        foreach ($match in $matches) { $tokens += $match.Value.Trim() }
    }

    return @{ ExePath=$exe; Tokens=$tokens }
}

function Tokens-ContainsRemoteFlag {
    param($tokens)
    foreach ($t in $tokens) {
        if ($t -match '--remote-debugging-port(=|\b)') { return $true }
    }
    return $false
}

function Ensure-RemotePort-TokenInTokens {
    param($tokens, $port)
    if (-not (Tokens-ContainsRemoteFlag -tokens $tokens)) {
        $tokens += "--remote-debugging-port=$port"
    }
    return $tokens
}

function Ensure-UrlTokenInTokens {
    param($tokens)
    # If any token contains %1 or url= then assume present
    foreach ($t in $tokens) { if ($t -match '%1' -or $t -match '--url') { return $tokens } }
    $tokens = @('--url=%1') + $tokens
    return $tokens
}

function Format-Tokens-ForUri {
    param($tokens)
    # For registry URI protocol, wrap every token in double quotes
    return ($tokens | ForEach-Object { '"' + ($_ -replace '^"|"$','') + '"' }) -join ' '
}

function Normalize-PathCase($path) { if (-not $path) { return $null }; return (Resolve-Path -LiteralPath $path -ErrorAction SilentlyContinue).ProviderPath }

# --- Start interactive step ---
Write-Host "Choose region to set:"
Write-Host "  1) Global"
Write-Host "  2) CN"
do {
    $choice = Read-Host 'Choose (1 or 2)'
    $choice = $choice.Trim()
} while ($choice -notin @('1','2'))

if ($choice -eq '1') {
    $region = 'Global'
    $protocolKey = $URL_Protocol_Global
    $startupFull = $Startup_String_Global
} else {
    $region = 'CN'
    $protocolKey = $URL_Protocol_CN
    $startupFull = $Startup_String_CN
}

Write-Host "Using region: $region"

# 1) Read URI protocol command value
$cmdValue = Get-RegistryDefaultValue -fullPath $protocolKey
if (-not $cmdValue) {
    Write-Host "Protocol key not found or has no command value: $protocolKey" -ForegroundColor Yellow
} else {
    $parsed = Parse-CommandString -cmd $cmdValue
    if ($null -eq $parsed -or -not $parsed.ExePath) {
        Write-Host "Unable to parse exe path from protocol command: $cmdValue" -ForegroundColor Yellow
    } else {
        $exePathRaw = $parsed.ExePath
        $exePath = $exePathRaw.Trim('"')
        $exeFull = Normalize-PathCase $exePath
        if (-not $exeFull) { $exeFull = $exePath }

        Write-Host "Detected exe path: $exeFull"

        # Ensure remote flag exists in protocol command (and ensure URI args are individually quoted)
        $tokens = $parsed.Tokens
        $tokens = Ensure-UrlTokenInTokens -tokens $tokens
        $tokens = Ensure-RemotePort-TokenInTokens -tokens $tokens -port $DefaultRemotePort

        $tokenStringForUri = Format-Tokens-ForUri -tokens $tokens
        $newCmd = '"' + $exeFull + '" ' + $tokenStringForUri
        if ($newCmd -ne $cmdValue) {
            Set-RegistryDefaultValue -fullPath $protocolKey -value $newCmd
            Write-Host "Updated protocol command to include remote-debugging-port in: $protocolKey" -ForegroundColor Green
        } else {
            Write-Host "Protocol command already has remote-debugging-port." -ForegroundColor Green
        }

        # 2) Check Startup Run value (if exists) and update if exe matches
        $parts = Split-RegistryValuePathAndName -fullPath $startupFull
        $runKey = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($parts.KeyPath, $true)
        if ($null -ne $runKey) {
            $val = $runKey.GetValue($parts.ValueName)
            if ($null -ne $val) {
                $parsedRun = Parse-CommandString -cmd $val
                if ($parsedRun -and $parsedRun.ExePath) {
                    $runExe = $parsedRun.ExePath.Trim('"')
                    $runExeFull = Normalize-PathCase $runExe
                    if (-not $runExeFull) { $runExeFull = $runExe }
                    if ($exeFull -and ($runExeFull -and ($runExeFull.Equals($exeFull, 'InvariantCultureIgnoreCase')))) {
                        # Update Run value tokens
                        $runTokens = $parsedRun.Tokens
                        $runTokens = Ensure-RemotePort-TokenInTokens -tokens $runTokens -port $DefaultRemotePort
                        # Keep existing quoting/formatting for Run value; join with spaces
                        $newRunValue = '"' + $runExeFull + '" ' + ($runTokens -join ' ')
                        if ($newRunValue -ne $val) {
                            $runKey.SetValue($parts.ValueName, $newRunValue, [Microsoft.Win32.RegistryValueKind]::String)
                            Write-Host "Updated Startup Run value: $($parts.ValueName) in $($parts.KeyPath)" -ForegroundColor Green
                        } else {
                            Write-Host "Startup Run value already contains remote-debugging-port." -ForegroundColor Green
                        }
                    } else {
                        Write-Host "Startup Run value exe does not match the protocol exe; skipping startup modification." -ForegroundColor Yellow
                    }
                }
            } else {
                Write-Host "No startup value named $($parts.ValueName) found; skipping." -ForegroundColor Yellow
            }
            $runKey.Close()
        } else {
            Write-Host "Startup Run key not present: $($parts.KeyPath). Skipping startup check." -ForegroundColor Yellow
        }

        # 3) Discover desktop (OneDrive or local) and update shortcuts
        $oneDriveDesktop = $null
        if ($Env:OneDrive) { $oneDriveDesktop = Join-Path $Env:OneDrive 'Desktop' }
        if ($oneDriveDesktop -and (Test-Path $oneDriveDesktop)) { $defaultPath = $oneDriveDesktop } else { $defaultPath = [Environment]::GetFolderPath('Desktop') }

        Write-Host "Default Path: $defaultPath"
        $chooseDifferent = Read-Host "Do you wish to choose a different location where you set your game shortcuts? (Y/N)"
        if ($chooseDifferent -match '^(?i:Y|Yes)$') {
            Add-Type -AssemblyName System.Windows.Forms
            $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
            $dlg.Description = 'Locate folder where you put HoYoPlay.lnk, Genshin Impact.lnk, etc'
            $dlg.SelectedPath = $defaultPath
            $res = $dlg.ShowDialog()
            if ($res -eq [System.Windows.Forms.DialogResult]::OK) {
                $desktopPath = $dlg.SelectedPath
            } else {
                $desktopPath = $defaultPath
            }
        } else {
            $desktopPath = $defaultPath
        }

        Write-Host "Searching shortcuts under: $desktopPath"
        $lnks = Get-ChildItem -Path $desktopPath -Filter *.lnk -Recurse -ErrorAction SilentlyContinue
        $countChanged = 0
        foreach ($lnk in $lnks) {
            try {
                $sc = $WshShell.CreateShortcut($lnk.FullName)
                $target = $sc.TargetPath
                if (-not $target) { continue }
                $targetFull = Normalize-PathCase $target
                if (-not $targetFull) { $targetFull = $target }
                if ($exeFull -and ($targetFull.Equals($exeFull, 'InvariantCultureIgnoreCase'))) {
                    # Update arguments: add remote port if missing
                    $existingArgs = $sc.Arguments
                    $argTokens = @()
                    if ($existingArgs) {
                        $matches = [regex]::Matches($existingArgs, '("[^"]*"|\S+)')
                        foreach ($m in $matches) { $argTokens += $m.Value.Trim('"') }
                    }
                    if (-not (Tokens-ContainsRemoteFlag -tokens $argTokens)) {
                        $argTokens += "--remote-debugging-port=$DefaultRemotePort"
                        # Rebuild arguments keeping non-URI format (do not force each token quoted)
                        $sc.Arguments = ($argTokens | ForEach-Object { if ($_ -match '\s') { '"' + $_ + '"' } else { $_ } }) -join ' '
                        $sc.Save()
                        $countChanged++
                        Write-Host "Updated shortcut: $($lnk.FullName)" -ForegroundColor Green
                    }
                }
            } catch {
                # ignore errors per-shortcut
            }
        }

        Write-Host "Finished. Shortcuts updated: $countChanged" -ForegroundColor Cyan
    }
}

Write-Host "Setup script finished." -ForegroundColor Cyan
