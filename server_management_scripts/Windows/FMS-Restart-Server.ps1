# =============================================================================
# FMS-Restart-Server.ps1 -- FileMaker Server Safe Shutdown & Restart
# Platform: Windows PowerShell 5.1+
#
# Usage:
#   .\FMS-Restart-Server.ps1 "fmsadmin_user" "fmsadmin_password"
#
# Both arguments are required. The script will:
#   1. Detect whether FileMaker Server is running
#   2. Disconnect all clients (with retries)
#   3. Close all hosted databases (with retries)
#   4. Restart the server
#
# If any step fails, the script attempts to reopen databases and exits
# without restarting.
#
# If FileMaker Server is not installed/running, the script performs a
# plain restart with no FMS steps.
#
# Logs: C:\ProgramData\fms_restart\fms_shutdown.log (rotates at 5 MB)
#
# SECURITY NOTE
# Credentials are passed to fmsadmin.exe as command-line arguments. They
# are visible in the Windows process list to local administrators for the
# brief duration of each fmsadmin call. This is a known limitation of
# fmsadmin's command-line auth model.
#
# =============================================================================
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:AdminUser = if ($args.Count -ge 1) { [string]$args[0] } else { '' }
$script:AdminPW   = if ($args.Count -ge 2) { [string]$args[1] } else { '' }

if (-not $script:AdminUser -or -not $script:AdminPW) {
    Write-Host 'Usage: .\FMS-Restart-Server.ps1 "fmsadmin_user" "fmsadmin_password"' -ForegroundColor Yellow
    exit 1
}

$FMSAdminPath = 'C:\Program Files\FileMaker\FileMaker Server\Database Server\fmsadmin.exe'
$MaxRetries = 10
$RetryInterval = 4
$LogDir = 'C:\ProgramData\fms_restart'
$LogFile = Join-Path $LogDir 'fms_shutdown.log'
$LockFile = Join-Path $env:TEMP 'fms_restart_server.lock'
$MaxLogBytes = 5MB
$script:FilesWereClosed = $false

# =============================================================================
# LOGGING
# =============================================================================
function Initialize-Logging {
    if (-not (Test-Path -LiteralPath $LogDir)) {
        New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
    }
    Rotate-Log
}

function Rotate-Log {
    if (-not (Test-Path -LiteralPath $LogFile)) { return }
    if ((Get-Item -LiteralPath $LogFile).Length -le $MaxLogBytes) { return }

    if (Test-Path -LiteralPath "$LogFile.3") { Remove-Item -LiteralPath "$LogFile.3" -Force }
    if (Test-Path -LiteralPath "$LogFile.2") { Move-Item -LiteralPath "$LogFile.2" -Destination "$LogFile.3" -Force }
    if (Test-Path -LiteralPath "$LogFile.1") { Move-Item -LiteralPath "$LogFile.1" -Destination "$LogFile.2" -Force }
    Move-Item -LiteralPath $LogFile -Destination "$LogFile.1" -Force
}

function Write-Log {
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR')][string]$Level = 'INFO'
    )

    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $entry = "[$timestamp] [$Level] $Message"

    switch ($Level) {
        'ERROR' { Write-Host $entry -ForegroundColor Red }
        'WARN'  { Write-Host $entry -ForegroundColor Yellow }
        default { Write-Host $entry -ForegroundColor Cyan }
    }

    try {
        Add-Content -LiteralPath $LogFile -Value $entry -Encoding UTF8
    }
    catch {
        Write-Host "[$timestamp] [WARN] Failed to write to log file: $($_.Exception.Message)" -ForegroundColor Yellow
    }
}

# =============================================================================
# LOCK (prevent concurrent runs)
# =============================================================================
function Acquire-Lock {
    if (Test-Path -LiteralPath $LockFile) {
        $lockPidRaw = Get-Content -LiteralPath $LockFile -ErrorAction SilentlyContinue | Select-Object -First 1
        $lockPid = 0
        if ([int]::TryParse(($lockPidRaw | Out-String).Trim(), [ref]$lockPid) -and $lockPid -gt 0) {
            $existingProcess = Get-Process -Id $lockPid -ErrorAction SilentlyContinue
            if ($existingProcess) {
                throw "Another instance is already running under PID $lockPid."
            }
        }

        Remove-Item -LiteralPath $LockFile -Force -ErrorAction SilentlyContinue
    }

    $lockStream = $null
    try {
        $lockStream = [System.IO.File]::Open($LockFile, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
        $bytes = [System.Text.Encoding]::UTF8.GetBytes([string]$PID)
        $lockStream.Write($bytes, 0, $bytes.Length)
        $lockStream.Flush()
    }
    catch {
        throw "Unable to acquire lock file '$LockFile': $($_.Exception.Message)"
    }
    finally {
        if ($lockStream) { $lockStream.Dispose() }
    }
}

function Release-Lock {
    if (Test-Path -LiteralPath $LockFile) {
        Remove-Item -LiteralPath $LockFile -Force -ErrorAction SilentlyContinue
    }
}

# =============================================================================
# FMSADMIN WRAPPER
# =============================================================================
function Invoke-FMSCommand {
    param(
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [switch]$AllowFailure,
        [switch]$Silent
    )

    if (-not (Test-Path -LiteralPath $FMSAdminPath)) {
        throw "fmsadmin.exe not found at '$FMSAdminPath'."
    }

    $escapedArgs = ($Arguments | ForEach-Object {
            if ($_ -match '\s') { "`"$_`"" } else { $_ }
        }) -join ' '
    $escapedUser = if ($script:AdminUser -match '\s') { "`"$($script:AdminUser)`"" } else { $script:AdminUser }
    $escapedPass = if ($script:AdminPW -match '\s') { "`"$($script:AdminPW)`"" }   else { $script:AdminPW }
    $argString = "$escapedArgs -u $escapedUser -p $escapedPass"

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $FMSAdminPath
    $psi.Arguments = $argString
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $psi
    $null = $process.Start()
    $stdout = $process.StandardOutput.ReadToEnd()
    $stderr = $process.StandardError.ReadToEnd()
    $process.WaitForExit()

    $sanitizedCommand = ($Arguments -join ' ')

    if (-not $Silent) {
        Write-Log "fmsadmin $sanitizedCommand  [exit $($process.ExitCode)]"

        $isListCommand = ($sanitizedCommand -match '^list\s')
        if ($stdout.Trim() -and -not $isListCommand) {
            $lines = @($stdout.Trim() -split '\s*\|\s*' | Where-Object { $_.Trim() -ne '' })
            if ($lines.Count -gt 1) {
                foreach ($line in $lines) {
                    $trimmed = $line.Trim()
                    if ($trimmed) { Write-Log "  $trimmed" }
                }
            }
            else {
                Write-Log "  $($stdout.Trim())"
            }
        }

        if ($stderr.Trim()) {
            Write-Log "  STDERR: $($stderr.Trim())" 'WARN'
        }
    }

    $result = [pscustomobject]@{
        ExitCode = $process.ExitCode
        StdOut   = $stdout
        StdErr   = $stderr
        Success  = ($process.ExitCode -eq 0)
    }

    if (-not $result.Success -and -not $AllowFailure) {
        throw "fmsadmin command failed: $sanitizedCommand (exit code $($result.ExitCode))."
    }

    return $result
}

# =============================================================================
# FMS OPERATIONS
# =============================================================================
function Get-CurrentClients {
    $result = Invoke-FMSCommand -Arguments @('list', 'clients')
    $clientIds = New-Object System.Collections.Generic.List[string]

    foreach ($line in ($result.StdOut -split "`r?`n")) {
        if ($line -match '^\s*(\d+)\b') {
            [void]$clientIds.Add($Matches[1])
        }
    }

    Write-Log "Connected client count: $($clientIds.Count)"
    return @($clientIds)
}

function Disconnect-Clients {
    for ($attempt = 1; $attempt -le $MaxRetries; $attempt++) {
        $clients = @(Get-CurrentClients)
        if ($clients.Count -eq 0) {
            Write-Log 'No connected clients remain.'
            return $true
        }

        Write-Log "Disconnecting clients (attempt $attempt/$MaxRetries). Client IDs: $($clients -join ', ')"
        Invoke-FMSCommand -Arguments @('disconnect', 'client', '-y') | Out-Null
        Start-Sleep -Seconds $RetryInterval
    }

    $remainingClients = @(Get-CurrentClients)
    if ($remainingClients.Count -gt 0) {
        Write-Log "Client disconnect did not complete. Remaining client IDs: $($remainingClients -join ', ')" 'WARN'
        return $false
    }

    return $true
}

function Get-OpenFiles {
    param([switch]$Silent)
    $result = Invoke-FMSCommand -Arguments @('list', 'files', '-s') -Silent:$Silent
    $fileIds = New-Object System.Collections.Generic.List[string]

    foreach ($line in ($result.StdOut -split "`r?`n")) {
        if ($line -match '^\s*(\d+)\b') {
            $fileId = $Matches[1]
            if ($line -match '\bNormal\b') {
                [void]$fileIds.Add($fileId)
            }
        }
    }

    if (-not $Silent) { Write-Log "Open file count: $($fileIds.Count)" }
    return @($fileIds)
}

function Close-AllFiles {
    for ($attempt = 1; $attempt -le $MaxRetries; $attempt++) {
        $files = @(Get-OpenFiles)
        if ($files.Count -eq 0) {
            Write-Log 'No open databases remain.'
            $script:FilesWereClosed = $true
            return $true
        }

        Write-Log "Closing databases (attempt $attempt/$MaxRetries). File IDs: $($files -join ', ')"
        Invoke-FMSCommand -Arguments @('close', '-y') | Out-Null
        Start-Sleep -Seconds $RetryInterval
    }

    $remainingFiles = @(Get-OpenFiles)
    if ($remainingFiles.Count -gt 0) {
        Write-Log "Database close did not complete. Remaining file IDs: $($remainingFiles -join ', ')" 'WARN'
        return $false
    }

    $script:FilesWereClosed = $true
    return $true
}

function Reopen-DatabasesIfNeeded {
    if (-not $script:FilesWereClosed) {
        Write-Log 'Skipping reopen because no successful close operation was recorded.'
        return
    }

    try {
        Write-Log 'Attempting to reopen databases.'
        Invoke-FMSCommand -Arguments @('open', '-y') -AllowFailure | Out-Null
        Write-Log 'Reopen command issued.'
    }
    catch {
        Write-Log "Database reopen attempt failed: $($_.Exception.Message)" 'WARN'
    }
}

function Test-PendingReboot {
    $rebootPaths = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending'
    )

    foreach ($path in $rebootPaths) {
        if (Test-Path -LiteralPath $path) {
            Write-Log "Pending reboot indicator detected at $path" 'WARN'
            return $true
        }
    }

    Write-Log 'No pending reboot indicator detected.'
    return $false
}

function Confirm-FMSReachable {
    $result = Invoke-FMSCommand -Arguments @('list', 'files') -AllowFailure
    if (-not $result.Success) {
        throw "Cannot communicate with FileMaker Server (exit code $($result.ExitCode))."
    }
    Write-Log 'FileMaker Server is reachable.'
}

function Start-ForcedRestart {
    Write-Log 'Issuing Restart-Computer -Force.'
    Restart-Computer -Force
}

# =============================================================================
# MAIN
# =============================================================================
Initialize-Logging
Write-Log '=========================================='
Write-Log 'Restart script started.'

try {
    Acquire-Lock

    $fmsService = Get-Service -Name 'FileMaker Server' -ErrorAction SilentlyContinue
    $fmsOperational = $false
    if (Test-Path -LiteralPath $FMSAdminPath) {
        if (($null -ne $fmsService) -and ($fmsService.Status -eq 'Running')) {
            $fmsOperational = $true
        } else {
            try {
                $null = & $FMSAdminPath -V 2>&1
                if ($LASTEXITCODE -eq 0) { $fmsOperational = $true }
            } catch { }
        }
    }

    if (-not $fmsOperational) {
        Write-Log 'FileMaker Server not detected (or incomplete install). Proceeding with plain restart.'
        Start-ForcedRestart
        exit 0
    }

    Write-Log 'FileMaker Server detected. Entering safe shutdown path.'
    Write-Log 'Credentials provided via CLI arguments.'
    [void](Test-PendingReboot)
    Confirm-FMSReachable

    $clientsOk = Disconnect-Clients
    $filesOk = Close-AllFiles

    if (-not $clientsOk -or -not $filesOk) {
        throw "Safe shutdown did not complete. Clients disconnected: $clientsOk. Files closed: $filesOk."
    }

    $finalFiles = @(Get-OpenFiles -Silent)
    if ($finalFiles.Count -gt 0) {
        throw "Final verification failed. Remaining open file IDs: $($finalFiles -join ', ')."
    }

    Write-Log 'All safety checks passed.'
    Start-ForcedRestart
    exit 0
}
catch {
    Write-Log "Unhandled error: $($_.Exception.Message)" 'ERROR'
    Reopen-DatabasesIfNeeded
    exit 1
}
finally {
    Release-Lock
    Write-Log 'Lock released.'
    Write-Log 'Restart script finished.'
    Write-Log '=========================================='
}
