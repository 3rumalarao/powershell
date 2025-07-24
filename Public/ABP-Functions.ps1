# ===================================================================
# Private Helper Functions (Internal to this module)
# ===================================================================

# Private function to handle the logic for backing up configuration files.
function Invoke-ConfigBackup {
    param (
        [string]$StepName,
        [hashtable[]]$BackupMap,
        [string]$LogFilePath
    )

    Write-Host "`n🛠️ Executing $StepName..." -ForegroundColor Cyan

    foreach ($map in $BackupMap) {
        $src = $map.Source
        $dst = $map.Dest

        if (-not (Test-Path -Path $src)) {
            $msg = "Source folder not found: $src"
            Write-Host "❌ $msg" -ForegroundColor Red
            Write-Log -Message $msg -LogFilePath $LogFilePath -Level "ERROR"
            continue
        }

        # Silently create destination if it doesn't exist
        if (-not (Test-Path -Path $dst)) {
            New-Item -Path $dst -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null
        }

        $txtFiles = Get-ChildItem -Path $src -Filter *.txt -File
        foreach ($file in $txtFiles) {
            try {
                Copy-Item -Path $file.FullName -Destination $dst -Force -ErrorAction Stop
                $msg = "Copied $($file.Name) to $dst"
                Write-Host "✅ $msg" -ForegroundColor Green
                Write-Log -Message $msg -LogFilePath $LogFilePath -Level "SUCCESS"
            } catch {
                $msg = "Failed to copy $($file.Name) to ${dst}: $_"
                Write-Host "❌ $msg" -ForegroundColor Red
                Write-Log -Message $msg -LogFilePath $LogFilePath -Level "ERROR"
            }
        }
    }
}


# ===================================================================
# Public Step Functions
# ===================================================================

function Invoke-PreFlightChecks {
    param(
        [string[]]$AllServers,
        [string]$LogFilePath,
        [string[]]$RequiredPaths
    )
    $step = "Step 0: Pre-flight Checks"
    Write-Host "`n✈️  Executing $step..." -ForegroundColor Cyan
    $allChecksPassed = $true

    # Check Server Connectivity
    Write-Host "  - Checking server connectivity..."
    foreach ($server in $AllServers) {
        if (-not (Test-Connection -ComputerName $server -Count 1 -Quiet)) {
            $msg = "Server is offline or unreachable: $server"
            Write-Host "  ❌ $msg" -ForegroundColor Red
            Write-Log -Message $msg -LogFilePath $LogFilePath -Level "ERROR"
            $allChecksPassed = $false
        } else {
            Write-Host "  ✅ Server online: $server" -ForegroundColor Green
        }
    }

    # Check Required Paths
    Write-Host "  - Checking required local paths..."
    foreach ($path in $RequiredPaths) {
        if (-not (Test-Path -Path $path)) {
            $msg = "Required path not found: $path"
            Write-Host "  ❌ $msg" -ForegroundColor Red
            Write-Log -Message $msg -LogFilePath $LogFilePath -Level "ERROR"
            $allChecksPassed = $false
        } else {
            Write-Host "  ✅ Path exists: $path" -ForegroundColor Green
        }
    }

    if ($allChecksPassed) {
        Write-Host "`n🟢 $step complete. All checks passed." -ForegroundColor Green
        Confirm-Step -Message "⏸️  Press ENTER to begin the deployment"
    } else {
        Write-Host "`n❌ $step failed. Please review errors above and restart." -ForegroundColor Red
    }

    return $allChecksPassed
}

function Stop-ABPPrimary {
    param (
        [string]$ServerName,
        [string]$ServiceName,
        [System.Management.Automation.PSCredential]$Credential,
        [string]$LogFilePath
    )
    $step = "Step 1"
    Write-Host "`n🛠️ Executing ${step}: Stopping '$ServiceName' on $ServerName..." -ForegroundColor Cyan

    try {
        $result = Invoke-Command -ComputerName $ServerName -Credential $Credential -ScriptBlock {
            param ($svcName)
            
            $service = Get-Service -Name $svcName -ErrorAction SilentlyContinue
            if ($null -eq $service) {
                return "NOT_FOUND"
            }

            if ($service.Status -eq 'Running') {
                Stop-Service -Name $svcName -Force -ErrorAction Stop
                Start-Sleep -Seconds 3 # Reduced sleep time
                $newStatus = (Get-Service -Name $svcName).Status
                if ($newStatus -eq 'Stopped') {
                    return "STOPPED"
                } else {
                    return "FAILED_TO_STOP"
                }
            } else {
                return "ALREADY_STOPPED"
            }
        } -ArgumentList $ServiceName

        # Handle result
        switch ($result) {
            "STOPPED"         { Write-Host "✅ $ServiceName stopped on $ServerName" -ForegroundColor Green; Write-Log -Message "$ServiceName stopped on $ServerName" -LogFilePath $LogFilePath -Level "SUCCESS" }
            "ALREADY_STOPPED" { Write-Host "ℹ️ $ServiceName already stopped on $ServerName" -ForegroundColor Yellow; Write-Log -Message "$ServiceName already stopped on $ServerName" -LogFilePath $LogFilePath -Level "INFO" }
            "NOT_FOUND"       { Write-Host "❌ Service '$ServiceName' not found on $ServerName" -ForegroundColor Red; Write-Log -Message "Service '$ServiceName' not found on $ServerName" -LogFilePath $LogFilePath -Level "ERROR" }
            default           { Write-Host "❌ Failed to stop $ServiceName on $ServerName" -ForegroundColor Red; Write-Log -Message "Failed to stop $ServiceName on $ServerName" -LogFilePath $LogFilePath -Level "ERROR" }
        }

    } catch {
        Write-Host "❌ Error processing ${ServerName}: $_" -ForegroundColor Red
        Write-Log -Message "Error processing ${ServerName}: $_" -LogFilePath $LogFilePath -Level "ERROR"
            }

    # User Confirmation Prompt
    Write-Host "`n🟢 $step complete." -ForegroundColor Green
    Confirm-Step -Message "⏸️  Press ENTER to proceed to Step 2"
}

function Test-ABPStopped {
    param (
        [string[]]$Servers,
        [string]$ServiceName,
        [string]$ProcessMatch,
        [System.Management.Automation.PSCredential]$Credential,
        [string]$LogFilePath
    )
    $step = "Step 2"
    foreach ($server in $Servers) {
        Write-Host "`n🔍 Executing ${step}: Validating ABP service/process is stopped on $server..." -ForegroundColor Cyan

        try {
            $validationResult = Invoke-Command -ComputerName $server -Credential $Credential -ScriptBlock {
                param ($svcName, $procDesc)

                # Check service first. If it's not found or not stopped, it's a failure condition.
                $svc = Get-Service -Name $svcName -ErrorAction SilentlyContinue
                if ($null -eq $svc -or $svc.Status -ne 'Stopped') {
                    return "SERVICE_NOT_STOPPED"
                }

                # If service is stopped, check for lingering processes.
                $found = Get-Process | Where-Object { $_.Description -like "*$procDesc*" -or $_.Name -like "*ABP*" }
                if ($found) {
                    return "PROCESS_RUNNING"
                }

                return "VALIDATED_STOPPED"
            } -ArgumentList $ServiceName, $ProcessMatch

            switch ($validationResult) {
                "VALIDATED_STOPPED" {
                    $msg = "ABP service/process fully stopped on $server"
                    Write-Host "✅ $msg" -ForegroundColor Green
                    Write-Log -Message $msg -LogFilePath $LogFilePath -Level "SUCCESS"
                }
                "PROCESS_RUNNING" {
                    $msg = "Service stopped but ABP process still running on $server"
                    Write-Host "⚠️ $msg" -ForegroundColor Yellow
                    Write-Log -Message $msg -LogFilePath $LogFilePath -Level "WARNING"
                }
                "SERVICE_NOT_STOPPED" {
                    $msg = "ABP service is not in a 'Stopped' state on $server (it may be running or not installed)."
                    Write-Host "❌ $msg" -ForegroundColor Red
                    Write-Log -Message $msg -LogFilePath $LogFilePath -Level "ERROR"
                }
                default {
                    $msg = "Unknown validation result on ${server}: $validationResult"
                    Write-Host "❌ $msg" -ForegroundColor Red
                    Write-Log -Message $msg -LogFilePath $LogFilePath -Level "ERROR"
                }
            }
        } catch {
            $msg = "Exception occurred while validating status on ${server}: $_"
            Write-Host "❌ $msg" -ForegroundColor Red
            Write-Log -Message $msg -LogFilePath $LogFilePath -Level "ERROR"
        }
    }

    Write-Host "`n🟢 $step complete." -ForegroundColor Green
    Confirm-Step -Message "⏸️  Press ENTER to proceed to Step 3"
}

function New-BackupFolders {
    param (
        [string]$BackupRoot,
        [string]$CurrentMonth,
        [string]$PrevMonth, # Renamed from PastMonth to match calling script
        [string]$Year,
        [string]$LogFilePath
    )
    $step = "Step 3"
    Write-Host "`n🛠️ Executing ${step}: Creating backup folder structure..." -ForegroundColor Cyan

    # Define root folder
    $deploymentLabel = "TaxFileupdate_${CurrentMonth}${Year}"
    $baseFolder = Join-Path $BackupRoot $deploymentLabel

    # Define all 4 subfolders
    $foldersToCreate = @(
        "$baseFolder\$PrevMonth\TaxData",
        "$baseFolder\$PrevMonth\Taxeleclookup",
        "$baseFolder\$CurrentMonth\TaxData",
        "$baseFolder\$CurrentMonth\Taxeleclookup"
    )

    foreach ($folder in $foldersToCreate) {
        try {
            if (-not (Test-Path -Path $folder)) {
                New-Item -Path $folder -ItemType Directory -Force -ErrorAction Stop | Out-Null
                $msg = "Created folder: $folder"
                Write-Host "✅ $msg" -ForegroundColor Green
                Write-Log -Message $msg -LogFilePath $LogFilePath -Level "SUCCESS"
            } else {
                $msg = "Folder already exists: $folder"
                Write-Host "ℹ️ $msg" -ForegroundColor Yellow
                Write-Log -Message $msg -LogFilePath $LogFilePath -Level "INFO"
            }
        } catch {
            $msg = "Error creating folder ${folder}: $_"
            Write-Host "❌ $msg" -ForegroundColor Red
            Write-Log -Message $msg -LogFilePath $LogFilePath -Level "ERROR"
        }
    }

    Write-Host "`n🟢 $step complete. Folder structure is ready." -ForegroundColor Green
    Confirm-Step -Message "⏸️  Press ENTER to proceed to Step 4"
}

function Backup-PreUpdateConfig {
    param (
        [string]$ABP_TaxData,
        [string]$ABP_Taxeleclookup,
        [string]$BackupRoot,
        [string]$PrevMonth, # Renamed from PastMonth to match calling script
        [string]$Year,
        [string]$CurrentMonth,
        [string]$LogFilePath
    )
    $step = "Step 4"
    $deploymentLabel = "TaxFileupdate_${CurrentMonth}${Year}"
    $destRoot = Join-Path $BackupRoot $deploymentLabel

    $backupMap = @(
        @{ Source = $ABP_TaxData;        Dest = "$destRoot\$PrevMonth\TaxData" },
        @{ Source = $ABP_Taxeleclookup;  Dest = "$destRoot\$PrevMonth\Taxeleclookup" }
    )

    Invoke-ConfigBackup -StepName "${step}: Backing up pre-update config files for month '$PrevMonth'" -BackupMap $backupMap -LogFilePath $LogFilePath

    Write-Host "`n🟢 $step complete. Pre-update backup saved." -ForegroundColor Green
    Confirm-Step -Message "⏸️  Press ENTER to proceed to Step 5"
}

function Show-ZipProductManager {
    param (
        [string]$ServerName,
        [string]$LogFilePath,
        [switch]$InstructionsOnly # Parameter from calling script
    )
    $step = "Step 5"
    $title = "Manual Step – Run ZipProductManager GUI tool"
    Write-Host "`n📢 Executing ${step}: $title" -ForegroundColor Cyan
    Write-Log -Message "Awaiting user to complete ZipProductManager actions on $ServerName." -LogFilePath $LogFilePath

    $instructions = @(
        "Go to your Desktop.",
        "Right-click on 'ZipProductManager' shortcut and select 'Run as Administrator'.",
        "For each product in the list:",
        "   → Click 'Download Updates'",
        "   → Enter the password when prompted (check monthly mail)",
        "After all updates are downloaded, close the GUI."
    )
    Show-ManualStep -ServerName $ServerName -Instructions $instructions -Title "MANUAL ACTION REQUIRED"

    Confirm-Step -Message "⏸️  Press ENTER once you have completed the above manual steps"

    Write-Log -Message "User confirmed ZipProductManager execution complete." -LogFilePath $LogFilePath
    Write-Host "`n🟢 $step complete. Proceeding..." -ForegroundColor Green
    Confirm-Step -Message "⏸️  Press ENTER to proceed to Step 6"
}

function Show-ZCUtilPrimary {
    param (
        [string]$ZCUtilPath,
        [string]$LogFilePath
    )
    $step = "Step 6"
    $serverName = "Primary Server" # Generic name for primary
    $title = "Manual Step – Run ZCUtil GUI tool"
    Write-Host "`n📢 Executing ${step}: $title" -ForegroundColor Cyan
    Write-Log -Message "Awaiting user to complete ZCUtil GUI update on $serverName." -LogFilePath $LogFilePath

    if (-not (Test-Path -Path $ZCUtilPath)) {
        Write-Host "⚠️ WARNING: Could not find ZCUtil at: $ZCUtilPath" -ForegroundColor Red
        Write-Log -Message "ZCUtil.exe not found at $ZCUtilPath" -LogFilePath $LogFilePath -Level "ERROR"
    }

    $instructions = @(
        "Navigate to the following folder:",
        "   $ZCUtilPath",
        "Right-click on 'ZipUtil.exe' and choose 'Run as Administrator'.",
        "In the GUI window:",
        "   → Login using username: admin | password: admin",
        "   → Click on 'Utilities' tab.",
        "   → Click 'Update' and follow prompts until completed.",
        "Close the window after update completes."
    )
    Show-ManualStep -ServerName $serverName -Instructions $instructions -Title "MANUAL ACTION REQUIRED"

    Confirm-Step -Message "⏸️  Press ENTER after completing the above manual ZCUtil steps"

    Write-Log -Message "User confirmed ZCUtil completed on $serverName." -LogFilePath $LogFilePath
    Write-Host "`n🟢 $step complete. Proceeding..." -ForegroundColor Green
    Confirm-Step -Message "⏸️  Press ENTER to proceed to Step 7"
}

function Backup-PostUpdateConfig {
    param (
        [string]$ABP_TaxData,
        [string]$ABP_Taxeleclookup,
        [string]$BackupRoot,
        [string]$CurrentMonth,
        [string]$Year,
        [string]$LogFilePath
    )
    $step = "Step 7"
    $deploymentLabel = "TaxFileupdate_${CurrentMonth}${Year}"
    $destRoot = Join-Path $BackupRoot $deploymentLabel

    $backupMap = @(
        @{ Source = $ABP_TaxData;        Dest = "$destRoot\$CurrentMonth\TaxData" },
        @{ Source = $ABP_Taxeleclookup;  Dest = "$destRoot\$CurrentMonth\Taxeleclookup" }
    )

    Invoke-ConfigBackup -StepName "${step}: Backing up post-update config files for month '$CurrentMonth'" -BackupMap $backupMap -LogFilePath $LogFilePath

    Write-Host "`n🟢 $step complete. Post-update backup saved." -ForegroundColor Green
    Confirm-Step -Message "⏸️  Press ENTER to proceed to Step 8"
}

function Copy-UpdatedConfigsToTargets {
    param (
        [string[]]$TargetServers,
        [hashtable]$TargetConfigPaths,
        [string]$BackupRoot,
        [string]$CurrentMonth,
        [string]$Year,
        [string]$LogFilePath
    )
    $step = "Step 8"
    Write-Host "`n🛠️ Executing ${step}: Distributing updated configs to target servers..." -ForegroundColor Cyan

    $deploymentLabel = "TaxFileupdate_${CurrentMonth}${Year}"
    $sourceRoot = Join-Path $BackupRoot $deploymentLabel

    foreach ($server in $TargetServers) {
        Write-Host "`n➡️  Processing server: $server" -ForegroundColor White
        foreach ($folderType in $TargetConfigPaths.Keys) {
            $srcPath = Join-Path $sourceRoot "$CurrentMonth\$folderType"
            # Converts a local path like 'D:\path' to a UNC admin share path '\\server\d$\path'
            $destPath = Join-Path "\\$server" ($TargetConfigPaths[$folderType].Replace(':', '$'))

            if (-not (Test-Path -Path $srcPath)) {
                $msg = "Source folder missing, skipping: $srcPath"
                Write-Host "❌ $msg" -ForegroundColor Red
                Write-Log -Message "($server) $msg" -LogFilePath $LogFilePath -Level "ERROR"
                continue
            }

            $txtFiles = Get-ChildItem -Path $srcPath -Filter *.txt -File
            foreach ($file in $txtFiles) {
                try {
                    Copy-Item -Path $file.FullName -Destination $destPath -Force -ErrorAction Stop
                    $msg = "Copied $($file.Name) to $server\$folderType"
                    Write-Host "✅ $msg" -ForegroundColor Green
                    Write-Log -Message $msg -LogFilePath $LogFilePath -Level "SUCCESS"
                } catch {
                    $msg = "Failed to copy $($file.Name) to ${server}: $_"
                    Write-Host "❌ $msg" -ForegroundColor Red
                    Write-Log -Message $msg -LogFilePath $LogFilePath -Level "ERROR"
                }
            }

            # Validate file count
            $srcCount = $txtFiles.Count
            try {
                $destCount = (Get-ChildItem -Path $destPath -Filter *.txt -File -ErrorAction Stop).Count
                if ($srcCount -eq $destCount) {
                    $msg = "File count matched for $server/$folderType ($srcCount files)"
                    Write-Host "🟢 $msg" -ForegroundColor Green
                    Write-Log -Message $msg -LogFilePath $LogFilePath -Level "INFO"
                } else {
                    $msg = "File count mismatch for $server/${folderType}: Source has $srcCount, Destination has $destCount"
                    Write-Host "⚠️ $msg" -ForegroundColor Yellow
                    Write-Log -Message $msg -LogFilePath $LogFilePath -Level "WARNING"
                }
            } catch {
                $msg = "Could not validate file count on $server/${folderType}: $_"
                Write-Host "⚠️ $msg" -ForegroundColor Yellow
                Write-Log -Message $msg -LogFilePath $LogFilePath -Level "WARNING"
            }
        }
    }

    Write-Host "`n🟢 $step complete. Config files distributed." -ForegroundColor Green
    Confirm-Step -Message "⏸️  Press ENTER to proceed to Step 9"
}

function Stop-ABPOnTargets {
    param (
        [string[]]$TargetServers,
        [string]$ServiceName,
        [System.Management.Automation.PSCredential]$Credential,
        [string]$LogFilePath
    )
    $step = "Step 9"
    Write-Host "`n🛠️ Executing ${step}: Stopping ABP service on target servers..." -ForegroundColor Cyan

    foreach ($server in $TargetServers) {
        Write-Host "➡️ Stopping $ServiceName on $server..." -ForegroundColor White

        try {
            $result = Invoke-Command -ComputerName $server -Credential $Credential -ScriptBlock {
                param ($svcName)
                $service = Get-Service -Name $svcName -ErrorAction SilentlyContinue
                if ($null -eq $service) {
                    return "NOT_FOUND"
                }
                if ($service.Status -eq 'Running') {
                    Stop-Service -Name $svcName -Force -ErrorAction Stop
                    Start-Sleep -Seconds 3
                    $newStatus = (Get-Service -Name $svcName).Status
                    if ($newStatus -eq 'Stopped') { return "STOPPED" } else { return "FAILED_TO_STOP" }
                } else {
                    return "ALREADY_STOPPED"
                }
            } -ArgumentList $ServiceName

            switch ($result) {
                "STOPPED"         { $msg = "$ServiceName stopped on $server"; Write-Host "✅ $msg" -ForegroundColor Green; Write-Log -Message $msg -LogFilePath $LogFilePath -Level "SUCCESS" }
                "ALREADY_STOPPED" { $msg = "$ServiceName already stopped on $server"; Write-Host "ℹ️ $msg" -ForegroundColor Yellow; Write-Log -Message $msg -LogFilePath $LogFilePath -Level "INFO" }
                "NOT_FOUND"       { $msg = "Service '$ServiceName' not found on $server"; Write-Host "❌ $msg" -ForegroundColor Red; Write-Log -Message $msg -LogFilePath $LogFilePath -Level "ERROR" }
                default           { $msg = "Failed to stop $ServiceName on $server (status: $result)"; Write-Host "❌ $msg" -ForegroundColor Red; Write-Log -Message $msg -LogFilePath $LogFilePath -Level "ERROR" }
            }

        } catch {
            $msg = "Error processing ${server}: $_"
            Write-Host "❌ $msg" -ForegroundColor Red
            Write-Log -Message $msg -LogFilePath $LogFilePath -Level "ERROR"
        }
    }

    Write-Host "`n🟢 $step complete. ABP services stopped on all targets." -ForegroundColor Green
    Confirm-Step -Message "⏸️  Press ENTER to proceed to Step 10"
}

function Start-ZCUtilTargets {
    param (
        [string[]]$TargetServers,
        [string]$ZCUtilPath,
        [string]$LogFilePath
    )
    $step = "Step 10"
    Write-Host "`n📢 Executing ${step}: Manual ZCUtil update on target servers..." -ForegroundColor Cyan

    $instructions = @(
        "Login to the server via RDP or console.",
        "Navigate to: $ZCUtilPath",
        "Right-click 'ZipUtil.exe' → Run as Administrator",
        "Login: admin / admin",
        "Click 'Utilities' → 'Update' and follow the wizard",
        "Close the tool after completion"
    )

    foreach ($server in $TargetServers) {
        Show-ManualStep -ServerName $server -Instructions $instructions -Title "MANUAL ACTION REQUIRED"

        Write-Log -Message "Awaiting user to run ZCUtil manually on $server." -LogFilePath $LogFilePath -Level "INFO"

        Confirm-Step -Message "⏸️  After completing the ZCUtil update on $server, press ENTER to continue to the next server"

        Write-Log -Message "User confirmed ZCUtil update complete on $server." -LogFilePath -Level "INFO"
    }

    Write-Host "`n🟢 $step complete. ZCUtil run completed on all target servers." -ForegroundColor Green
    Confirm-Step -Message "⏸️  Press ENTER to proceed to Step 11"
}

function Show-PORConsoleInstructions {
    param (
        [string]$ServerName,
        [string]$PORConsolePath,
        [string]$LogFilePath
    )
    $step = "Step 11"
    $title = "Manual POR Tax Rates Update"
    Write-Host "`n📢 Executing ${step}: $title on $ServerName..." -ForegroundColor Cyan

    $instructions = @(
        "Log into the server (via RDP or console).",
        "Navigate to: $PORConsolePath",
        "Right-click 'PORTaxRatesConsole.exe' → Run as Administrator.",
        "Let the utility run to completion (follow prompts).",
        "Close the window once done."
    )

    Show-ManualStep -ServerName $ServerName -Instructions $instructions -Title "MANUAL ACTION REQUIRED"

    Write-Log -Message "Awaiting manual run of PORTaxRatesConsole on $ServerName." -LogFilePath $LogFilePath -Level "INFO"

    Confirm-Step -Message "⏸️  After completing the manual execution on $ServerName, press ENTER to confirm"

    Write-Log -Message "User confirmed PORTaxRatesConsole execution complete on $ServerName." -LogFilePath $LogFilePath -Level "INFO"

    Write-Host "`n🟢 $step complete. Manual task confirmed on $ServerName." -ForegroundColor Green
    Confirm-Step -Message "⏸️  Press ENTER to proceed to Step 12"
}

function Start-ABPAll {
    param (
        [string[]]$Servers, # Renamed for consistency
        [string]$ServiceName,
        [System.Management.Automation.PSCredential]$Credential,
        [string]$LogFilePath
    )
    $step = "Step 12"
    Write-Host "`n🛠️ Executing ${step}: Starting ABP service on all servers..." -ForegroundColor Cyan

    foreach ($server in $Servers) {
        Write-Host "➡️ Starting $ServiceName on $server..." -ForegroundColor White

        try {
            $result = Invoke-Command -ComputerName $server -Credential $Credential -ScriptBlock {
                param ($svcName)
                $service = Get-Service -Name $svcName -ErrorAction SilentlyContinue
                if ($null -eq $service) {
                    return "NOT_FOUND"
                }
                if ($service.Status -ne 'Running') {
                    Start-Service -Name $svcName -ErrorAction Stop
                    Start-Sleep -Seconds 3
                    $newStatus = (Get-Service -Name $svcName).Status
                    if ($newStatus -eq 'Running') { return "STARTED" } else { return "FAILED_TO_START" }
                } else {
                    return 'ALREADY_RUNNING'
                }
            } -ArgumentList $ServiceName

            switch ($result) {
                "STARTED"         { $msg = "$ServiceName started on $server"; Write-Host "✅ $msg" -ForegroundColor Green; Write-Log -Message $msg -LogFilePath $LogFilePath -Level "SUCCESS" }
                "ALREADY_RUNNING" { $msg = "$ServiceName was already running on $server"; Write-Host "ℹ️ $msg" -ForegroundColor Yellow; Write-Log -Message $msg -LogFilePath $LogFilePath -Level "INFO" }
                "NOT_FOUND"       { $msg = "Service '$ServiceName' not found on $server"; Write-Host "❌ $msg" -ForegroundColor Red; Write-Log -Message $msg -LogFilePath $LogFilePath -Level "ERROR" }
                default           { $msg = "Failed to start $ServiceName on $server (status: $result)"; Write-Host "❌ $msg" -ForegroundColor Red; Write-Log -Message $msg -LogFilePath $LogFilePath -Level "ERROR" }
            }

        } catch {
            $msg = "Failed to start $ServiceName on ${server}: $_"
            Write-Host "❌ $msg" -ForegroundColor Red
            Write-Log -Message $msg -LogFilePath $LogFilePath -Level "ERROR"
        }
    }

    Write-Host "`n🟢 $step complete. ABP service is now running on all servers." -ForegroundColor Green
    Confirm-Step -Message "⏸️  Press ENTER to proceed to Step 13"
}

function Show-SummaryReport {
    param (
        [string]$LogFilePath,
        [datetime]$StartTime
    )

    $step = "Step 13"
    Write-Host "`n📢 Executing ${step}: Showing summary report..." -ForegroundColor Cyan

    if (-not (Test-Path $LogFilePath)) {
        Write-Host "❌ Log file not found: $LogFilePath" -ForegroundColor Red
        return
    }

    $logContent = Get-Content -Path $LogFilePath

    $successLines = $logContent | Where-Object { $_ -match 'SUCCESS' }
    $errorLines   = $logContent | Where-Object { $_ -match 'ERROR' }
    $warnLines    = $logContent | Where-Object { $_ -match 'WARNING' -or $_ -match 'SKIPPED' -or $_ -match 'INFO' }

    $duration = New-TimeSpan -Start $StartTime -End (Get-Date)

    Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Yellow
    Write-Host "📋 ABP Deployment Summary Report" -ForegroundColor Cyan
    Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    Write-Host "✅ Successes : $($successLines.Count)" -ForegroundColor Green
    Write-Host "⚠️  Warnings  : $($warnLines.Count)"  -ForegroundColor Yellow
    Write-Host "❌ Errors    : $($errorLines.Count)"    -ForegroundColor Red
    Write-Host "⏱️ Duration  : $($duration.ToString('hh\:mm\:ss'))" -ForegroundColor Cyan

    if ($errorLines.Count -gt 0) {
        Write-Host "`n🔎 ERROR DETAILS:" -ForegroundColor Red
        $errorLines | ForEach-Object { Write-Host "  $_" -ForegroundColor Red }
    }

    if ($warnLines.Count -gt 0) {
        Write-Host "`n⚠️ WARNING DETAILS:" -ForegroundColor Yellow
        $warnLines | ForEach-Object { Write-Host "  $_" -ForegroundColor Yellow }
    }

    Write-Host "`n📄 Full log saved at: $LogFilePath" -ForegroundColor Cyan
    Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Yellow

    if ($errorLines.Count -gt 0) {
        Write-Host "`n❌ ABP Monthly Deployment Completed with ERRORS." -ForegroundColor Red
        Write-Log -Message "Deployment finished with errors." -LogFilePath $LogFilePath -Level "ERROR"
    } else {
        Write-Host "`n✅ ABP Monthly Deployment Completed Successfully!" -ForegroundColor Green
        Write-Log -Message "Deployment finished successfully." -LogFilePath $LogFilePath -Level "SUCCESS"
    }
}
