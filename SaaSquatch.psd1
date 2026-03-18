@{
    # Module identity
    ModuleVersion     = '1.0.0'
    GUID              = 'a3f7c2e1-84b9-4d6f-a012-3e5c7f891b24'
    Author            = 'Geoff Tankersley'
    CompanyName       = 'Geoff Tankersley'
    Copyright         = '(c) 2026 Geoff Tankersley. All rights reserved.'
    Description       = 'PowerShell module for the SaaS Alerts Partner API. Provides cmdlets for retrieving customers, users, and security events with full time-window pagination support.'

    # Requirements
    PowerShellVersion = '5.1'

    # Root module
    RootModule        = 'SaaSquatch.psm1'

    # Exported functions (explicit list — no wildcards)
    FunctionsToExport = @(
        # Auth
        'Set-SaaSquatchApiKey'
        'Clear-SaaSquatchApiKey'
        'Test-SaaSquatchConnection'

        # Customers
        'Get-SaaSquatchCustomer'
        'Get-SaaSquatchCustomerById'

        # Users
        'Get-SaaSquatchUser'

        # Events
        'Get-SaaSquatchEvent'
        'Get-SaaSquatchEventById'

        # SOC helpers
        'Get-SaaSquatchCriticalEvent'
        'Get-SaaSquatchFailedLogin'
        'Get-SaaSquatchAnomalousActivity'
        'Get-SaaSquatchFileShareEvent'

        # Utilities
        'ConvertTo-SaaSquatchDateTime'
        'Get-SaaSquatchEventType'
        'Export-SaaSquatchEvent'
        'Get-SaaSquatchConfiguration'
    )

    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()

    # PSGallery metadata
    PrivateData = @{
        PSData = @{
            Tags         = @('SaaSquatch', 'SaaSAlerts', 'Security', 'MSP', 'SOC', 'SIEM', 'API', 'SaaS')
            ProjectUri   = ''
            ReleaseNotes = @'
1.0.0 — Initial release.
  - Get-SaaSquatchCustomer / Get-SaaSquatchCustomerById
  - Get-SaaSquatchUser
  - Get-SaaSquatchEvent with full time-window pagination (-All)
  - Get-SaaSquatchEventById
  - SOC helpers: Get-SaaSquatchCriticalEvent, Get-SaaSquatchFailedLogin,
    Get-SaaSquatchAnomalousActivity, Get-SaaSquatchFileShareEvent
  - Export-SaaSquatchEvent (CSV / JSON with flattened schema)
  - Get-SaaSquatchEventType reference table
  - ConvertTo-SaaSquatchDateTime pipeline helper
  - Get-SaaSquatchConfiguration
'@
        }
    }
}
