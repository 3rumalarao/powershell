# Helper functions: Write-Log, Confirm-Step, etc.
# Reusable Helper Functions for ABP Deployment

function Write-Log {
    param (
        [string]$Message,
        [string]$LogFilePath,
        [ValidateSet("INFO", "SUCCESS", "WARNING", "ERROR")]
        [string]$Level = "INFO" # Enforce consistent log levels
    )
    $timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    $entry = "$timestamp - $Level - $Message"
    $entry | Out-File -FilePath $LogFilePath -Append
}

function Confirm-Step {
    param (
        [string]$Message = "⏸️  Press ENTER to continue..."
    )
    Read-Host $Message
}

function Show-ManualStep {
    param (
        [string]$ServerName,
        [string[]]$Instructions,
        [string]$Title = "Manual Task"
    )

    Write-Host "`n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Yellow
    Write-Host "📌 $Title on $ServerName" -ForegroundColor Magenta
    foreach ($line in $Instructions) {
        Write-Host "  • $line" -ForegroundColor White # Indent for readability
    }
    Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Yellow
}
