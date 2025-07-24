# Main controller script
# ==========================
# ABP Monthly Deployment Controller
# ==========================

# Load Module Functions and Helpers
Import-Module "$PSScriptRoot\ABPDeployment.psm1" -Force

# Load Configuration
$config     = Import-PowerShellDataFile "$PSScriptRoot\Public\ABP-Config.psd1"
$logFile    = Join-Path $config.LogFileRoot "ABPDeploy_$(Get-Date -Format 'yyyyMMdd_HHmm').log"
$startTime  = Get-Date
$Credential = Get-Credential

# Resolve Effective Date (handles weekend fallback)
$today = Get-Date
$effectiveDate = switch ($today.DayOfWeek) {
    'Saturday' { $today.AddDays(-1) }
    'Sunday'   { $today.AddDays(-2) }
    default    { $today }
}
$CurrentMonth = $effectiveDate.ToString("MMM")
$PrevMonth    = $effectiveDate.AddMonths(-1).ToString("MMM")
$Year         = $effectiveDate.ToString("yyyy")

# --- Parameter Splatting Hashtables ---
$commonParams = @{
    LogFilePath = $logFile;
    StartTime   = $startTime;
}
$credentialParams = @{
    Credential  = $Credential
    LogFilePath = $logFile
}
$dateParams = @{
    CurrentMonth = $CurrentMonth
    PrevMonth    = $PrevMonth
    Year         = $Year
}
$backupParams = @{
    ABP_TaxData       = $config.ABP_TaxData
    ABP_Taxeleclookup = $config.ABP_Taxelec
    BackupRoot        = $config.BackupRoot
}

# Display Info
Write-Host "`n🚀 Starting ABP Deployment for $CurrentMonth $Year" -ForegroundColor Cyan
Write-Log -Message "ABP Deployment started for $CurrentMonth $Year" @commonParams

# --- Pre-Flight Checks ---
$allServers = @($config.PrimaryServer) + $config.TargetServers
$requiredPaths = @(
    $config.BackupRoot,
    $config.LogFileRoot,
    $config.ABP_TaxData,
    $config.ABP_Taxelec,
    $config.ZCUtilPath,
    $config.PORConsolePath
)

$checksPassed = Invoke-PreFlightChecks -AllServers $allServers -RequiredPaths $requiredPaths -LogFilePath $logFile

# ------------------------
# Sequential Step Execution
# ------------------------

if ($checksPassed) {
    # Step 1: Stop ABP on Primary
    Stop-ABPPrimary -ServerName $config.PrimaryServer -ServiceName $config.ABPServiceName @credentialParams

    # Step 2: Validate ABP Stopped
    Test-ABPStopped -Servers $config.PrimaryServer -ServiceName $config.ABPServiceName -ProcessMatch $config.ExpectedProcess.Description @credentialParams

    # Step 3: Create Folder Hierarchy
    New-BackupFolders -BackupRoot $config.BackupRoot @dateParams @commonParams

    # Step 4: Backup Pre-Update Configs
    Backup-PreUpdateConfig @backupParams @dateParams @commonParams

    # Step 5: Manual - Run ZipProductManager on Primary
    Show-ZipProductManager -InstructionsOnly -ServerName $config.PrimaryServer @commonParams

    # Step 6: Manual - Run ZCUtil on Primary
    Show-ZCUtilPrimary -ZCUtilPath $config.ZCUtilPath @commonParams

    # Step 7: Backup Post-Update Configs
    Backup-PostUpdateConfig @backupParams @dateParams @commonParams

    # Step 8: Push Updated Configs to Targets
    Copy-UpdatedConfigsToTargets -TargetServers $config.TargetServers -TargetConfigPaths $config.TargetConfigPaths -BackupRoot $config.BackupRoot @dateParams @commonParams

    # Step 9: Stop ABP on Target Servers
    Stop-ABPOnTargets -TargetServers $config.TargetServers -ServiceName $config.ABPServiceName @credentialParams

    # Step 10: Manual - Run ZCUtil on Target Servers
    Start-ZCUtilTargets -TargetServers $config.TargetServers -ZCUtilPath $config.ZCUtilPath @commonParams

    # Step 11: Manual - Run POR Console on Serverp22
    Show-PORConsoleInstructions -ServerName $config.PORConsoleServer -PORConsolePath $config.PORConsolePath @commonParams

    # Step 12: Start ABP Service on All Servers
    Start-ABPAll -Servers $allServers -ServiceName $config.ABPServiceName @credentialParams

    # Step 13: Show Summary Report
    Show-SummaryReport @commonParams
} else {
    Write-Log -Message "Deployment aborted due to failed pre-flight checks." @commonParams
    # Show summary of errors found during pre-flight
    Show-SummaryReport @commonParams
}


# ════════════════════════════════════════════════
# STEP 14 - Copy Configs to Bolt Servers
# ════════════════════════════════════════════════
Write-Log -Message "STEP 14: Copying config files to Bolt Servers..." -LogFilePath $logFile
Copy-BoltConfigsToTargets -BoltServers $config.BoltServers `
                          -BackupRoot $config.BackupRoot `
                          -CurrentMonth $CurrentMonth `
                          -Year $Year `
                          -LogFilePath $logFile
Confirm-Step

# ════════════════════════════════════════════════
# STEP 15 - Manual: Run ZCUTIL on each Bolt Server
# ════════════════════════════════════════════════
Write-Log -Message "STEP 15: Manual GUI ZCUTIL execution on Bolt Servers..." -LogFilePath $logFile
foreach ($bolt in $config.BoltServers.Keys) {
    Show-ZCUtilBoltInstructions -ServerName $bolt `
                                -ZCUtilPath $config.BoltServers[$bolt].ZCUtilPath `
                                -LogFilePath $logFile
}
Confirm-Step

# ════════════════════════════════════════════════
# STEP 16 - Validate Excelergy ABP Service Running on Bolt Servers
# ════════════════════════════════════════════════
Write-Log -Message "STEP 16: Validating ABP service on Bolt Servers..." -LogFilePath $logFile
foreach ($bolt in $config.BoltServers.Keys) {
    Test-BoltServiceRunning -ServerName $bolt `
                            -ServiceName $config.ABPServiceName `
                            -LogFilePath $logFile
}
Confirm-Step
