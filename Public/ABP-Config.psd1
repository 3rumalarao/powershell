# Configuration file (hashtable)
@{
    PrimaryServer      = "Serverp21"
    TargetServers      = @("Serverp22", "Serverp25", "Serverp27")

    ABPServiceName     = "ABP Server"
    ExpectedProcess    = @{
        Name        = "ABPServer.exe"
        Description = "Excelergy Revenue Manager"
    }

    ABP_TaxData        = "D:\Program Files (x86)\ABP\TaxData"
    ABP_Taxelec        = "D:\Program Files (x86)\ABP\Taxeleclookup"
    ZCUtilPath         = "D:\Program Files (x86)\ABP\TaxData\ZCUtil_2.4.1.4"
    PORConsolePath     = "D:\Program Files (x86)\PORTaxRatesConsole"
    PORConsoleServer   = "Serverp22"
    BackupRoot         = "D:\Backup_CCH"
    LogFileRoot        = "D:\ABPLogs"

    TargetConfigPaths  = @{
        TaxData        = "D:\Program Files (x86)\ABP\TaxData"
        Taxeleclookup  = "D:\Program Files (x86)\ABP\Taxeleclookup"
    }


    BoltServers = @{
        'BTServerp34' = @{
            DestinationPaths = @('c$\Windows\SysWOW64\TaxData')
            ZCUtilPath       = 'C:\Windows\SysWOW64\TaxData\ZCUtil_2.4.1.4'
        }
        'BTServerp36' = @{
            DestinationPaths = @('c$\Windows\SysWOW64\TaxData')
            ZCUtilPath       = 'C:\Windows\SysWOW64\TaxData\ZCUtil_2.4.1.4'
        }
        'BTServerp005' = @{
            DestinationPaths = @(
                'c$\Windows\SysWOW64\TaxData',
                'd$\Program Files (x86)\ABP\TaxData'
            )
            ZCUtilPath       = 'C:\Windows\SysWOW64\TaxData\ZCUtil_2.4.1.4'
        }
    }
}
