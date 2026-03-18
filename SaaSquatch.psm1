#Requires -Version 5.1

<#
.SYNOPSIS
    PowerShell module for the SaaS Alerts Partner API.
.DESCRIPTION
    Provides cmdlets for interacting with the SaaS Alerts API, including retrieving
    customers, users, and security events with full pagination support.

    API notes (documented from live endpoint testing):
      - Base URL : https://us-central1-the-byway-248217.cloudfunctions.net/reportApi/api/v1
      - Auth     : X-API-Key request header
      - Events   : Hard cap of 10 results per request; offset parameter is ignored.
                   Use -All on Get-SaaSquatchEvent to paginate via time-window sliding.
      - Swagger  : https://app.swaggerhub.com/apis/SaaS_Alerts/functions/0.18.0

.NOTES
    Author  : Geoff Tankersley
    Version : 1.0.0
#>

Set-StrictMode -Version Latest

#region Module State

$Script:BaseUri    = 'https://us-central1-the-byway-248217.cloudfunctions.net/reportApi/api/v1'
$Script:ApiKey     = $null
$Script:Headers    = @{ Accept = 'application/json' }
$Script:MaxRetries = 3

#endregion

#region Authentication

function Set-SaaSquatchApiKey {
<#
.SYNOPSIS
    Configures the API key used for all subsequent SaaS Alerts requests.
.DESCRIPTION
    Stores the API key in the module session and adds it to the default request headers.
    Accepts a plain string or a SecureString to avoid token exposure in session history.
.PARAMETER ApiKey
    The API key as a plain string.
.PARAMETER SecureApiKey
    The API key as a SecureString (preferred — keeps the value out of shell history).
.EXAMPLE
    Set-SaaSquatchApiKey -ApiKey 'your-api-key-here'
.EXAMPLE
    $key = Read-Host 'Enter API key' -AsSecureString
    Set-SaaSquatchApiKey -SecureApiKey $key
#>
    [CmdletBinding(DefaultParameterSetName = 'Plain')]
    param(
        [Parameter(Mandatory, ParameterSetName = 'Plain')]
        [ValidateNotNullOrEmpty()]
        [string]$ApiKey,

        [Parameter(Mandatory, ParameterSetName = 'Secure')]
        [SecureString]$SecureApiKey
    )

    if ($PSCmdlet.ParameterSetName -eq 'Secure') {
        $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureApiKey)
        try   { $ApiKey = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr) }
        finally { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
    }

    $Script:ApiKey              = $ApiKey
    $Script:Headers['X-API-Key'] = $ApiKey
    Write-Verbose 'SaaS Alerts API key configured.'
}

function Clear-SaaSquatchApiKey {
<#
.SYNOPSIS
    Removes the stored API key from the module session.
.EXAMPLE
    Clear-SaaSquatchApiKey
#>
    [CmdletBinding()]
    param()
    $Script:ApiKey = $null
    $Script:Headers.Remove('X-API-Key')
    Write-Verbose 'SaaS Alerts API key cleared.'
}

function Test-SaaSquatchConnection {
<#
.SYNOPSIS
    Verifies that the configured API key can reach the SaaS Alerts API.
.DESCRIPTION
    Makes a lightweight call to GET /customers. Returns $true on success, $false otherwise.
.EXAMPLE
    Test-SaaSquatchConnection
    if (-not (Test-SaaSquatchConnection)) { throw 'Check your API key.' }
#>
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    Assert-SaaSquatchApiKey
    try {
        Invoke-SaaSquatchRequest -Endpoint '/customers' | Out-Null
        Write-Verbose 'Connection test successful.'
        return $true
    }
    catch {
        Write-Warning "Connection test failed: $($_.Exception.Message)"
        return $false
    }
}

#endregion

#region Internal Helpers

function Assert-SaaSquatchApiKey {
    if (-not $Script:ApiKey) {
        throw 'API key not configured. Run Set-SaaSquatchApiKey first.'
    }
}

function Invoke-SaaSquatchRequest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Endpoint,

        [ValidateSet('GET', 'POST')]
        [string]$Method = 'GET',

        [hashtable]$QueryParameters,

        [object]$Body
    )

    Assert-SaaSquatchApiKey

    # Build URI
    $uri = "$Script:BaseUri$Endpoint"
    if ($QueryParameters -and $QueryParameters.Count -gt 0) {
        $qs = ($QueryParameters.GetEnumerator() | ForEach-Object {
            "$($_.Key)=$([Uri]::EscapeDataString($_.Value.ToString()))"
        }) -join '&'
        $uri += "?$qs"
    }

    $params = @{
        Uri         = $uri
        Method      = $Method
        Headers     = $Script:Headers
        ErrorAction = 'Stop'
    }

    if ($Body) {
        $params['Body']        = ($Body | ConvertTo-Json -Depth 10)
        $params['ContentType'] = 'application/json'
    }

    $attempt = 0
    while ($true) {
        $attempt++
        try {
            Write-Verbose "$Method $uri"
            return Invoke-RestMethod @params
        }
        catch {
            $status = $null
            if ($_.Exception.Response) {
                $status = [int]$_.Exception.Response.StatusCode
            }

            # Retry on 429 with exponential back-off
            if ($status -eq 429 -and $attempt -le $Script:MaxRetries) {
                $wait = [Math]::Pow(2, $attempt)
                Write-Warning "Rate limited (429). Waiting ${wait}s before retry $attempt/$($Script:MaxRetries)…"
                Start-Sleep -Seconds $wait
                continue
            }

            # Surface API validation errors clearly
            $detail = $null
            try {
                $errBody = $_.ErrorDetails.Message | ConvertFrom-Json -ErrorAction SilentlyContinue
                if ($errBody.message) { $detail = "$($errBody.message): $($errBody.details | ConvertTo-Json -Compress)" }
            } catch {}

            $msg = if ($detail) { $detail } else { $_.Exception.Message }
            throw [System.Exception]"SaaS Alerts API error [$status] ${Endpoint}: $msg"
        }
    }
}

function Invoke-SaaSquatchPagedEvents {
<#
    Internal helper. Paginates GET /reports/events by sliding the time window forward
    using the timestamp of the last event returned, since offset is ignored by the API.
#>
    [CmdletBinding()]
    param(
        [hashtable]$BaseQuery,
        [datetime]$Start,
        [datetime]$End,
        [int]$PageSize = 10
    )

    $all        = [System.Collections.Generic.List[object]]::new()
    $windowStart = $Start
    $seen       = [System.Collections.Generic.HashSet[string]]::new()
    $fmt        = "yyyy-MM-dd'T'HH:mm:ss"

    do {
        $query = $BaseQuery.Clone()
        $query['startDate'] = $windowStart.ToUniversalTime().ToString($fmt)
        $query['endDate']   = $End.ToUniversalTime().ToString($fmt)
        $query['limit']     = $PageSize

        $batch = Invoke-SaaSquatchRequest -Endpoint '/reports/events' -QueryParameters $query

        if (-not $batch -or $batch.Count -eq 0) { break }

        $newItems   = 0
        $latestTime = $windowStart

        foreach ($evt in $batch) {
            # Some products (e.g. SAAS_ALERTS_MANAGE) return events with an empty eventId.
            # Fall back to a composite key so they aren't all collapsed to one.
            $key = if ($evt.eventId) { $evt.eventId } else { "$($evt.time)|$($evt.jointType)|$($evt.user.name)" }
            if ($seen.Add($key)) {
                $all.Add($evt)
                $newItems++
                $t = [datetime]::Parse($evt.time)
                if ($t -gt $latestTime) { $latestTime = $t }
            }
        }

        # If nothing new came back, or we didn't fill a full page, we're done
        if ($newItems -eq 0 -or $batch.Count -lt $PageSize) { break }

        # Advance window by 1 second past the latest event seen
        $windowStart = $latestTime.AddSeconds(1)

    } while ($windowStart -lt $End)

    return $all
}

#endregion

#region Customer Cmdlets

function Get-SaaSquatchCustomer {
<#
.SYNOPSIS
    Returns all customers associated with your partner account.
.DESCRIPTION
    Calls GET /customers and returns the full list. Each object includes name,
    domain, status, monitored products, IP ranges, allowed countries, and billing info.
.EXAMPLE
    Get-SaaSquatchCustomer
.EXAMPLE
    Get-SaaSquatchCustomer | Where-Object status -eq 'active' | Select-Object name, customerDomain
.OUTPUTS
    [PSCustomObject[]]
#>
    [CmdletBinding()]
    param()

    return Invoke-SaaSquatchRequest -Endpoint '/customers'
}

function Get-SaaSquatchCustomerById {
<#
.SYNOPSIS
    Returns a specific customer by ID.
.PARAMETER Id
    The customer ID (e.g. 'your-customer-id').
.EXAMPLE
    Get-SaaSquatchCustomerById -Id 'your-customer-id'
.EXAMPLE
    Get-SaaSquatchCustomer | Where-Object name -match 'Acme' | Get-SaaSquatchCustomerById
.OUTPUTS
    [PSCustomObject]
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, ValueFromPipelineByPropertyName)]
        [Alias('customerId')]
        [string]$Id
    )
    process {
        return Invoke-SaaSquatchRequest -Endpoint "/customers/$Id"
    }
}

#endregion

#region User Cmdlets

function Get-SaaSquatchUser {
<#
.SYNOPSIS
    Returns all monitored users for a given customer.
.DESCRIPTION
    Calls GET /reports/users?customerId=... . Returns every user account SaaS Alerts
    has observed across all monitored products for that customer, including role,
    product, billing status, and last seen time/IP.
.PARAMETER CustomerId
    The customer ID. Pipe from Get-SaaSquatchCustomer or supply directly.
.EXAMPLE
    Get-SaaSquatchUser -CustomerId 'your-customer-id'
.EXAMPLE
    Get-SaaSquatchCustomer | ForEach-Object { Get-SaaSquatchUser -CustomerId $_.id }
.EXAMPLE
    Get-SaaSquatchUser -CustomerId 'your-customer-id' | Where-Object isBillable -eq $true
.OUTPUTS
    [PSCustomObject[]]
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, ValueFromPipelineByPropertyName)]
        [Alias('id')]
        [string]$CustomerId
    )
    process {
        return Invoke-SaaSquatchRequest -Endpoint '/reports/users' -QueryParameters @{ customerId = $CustomerId }
    }
}

#endregion

#region Event Cmdlets

function Get-SaaSquatchEvent {
<#
.SYNOPSIS
    Retrieves security events from SaaS Alerts.
.DESCRIPTION
    Calls GET /reports/events with optional filters. The API returns a maximum of 10
    events per request and ignores the offset parameter.

    Use -All to automatically page through all matching events by sliding the time
    window forward. When -All is used, -StartDate and -EndDate are required.

    Each event includes: time, IP, geo-location (with threat intel), user, customer,
    product, alertStatus, jointType (event type), jointDesc, device, and operation.
.PARAMETER CustomerId
    Filter events to a specific customer ID.
.PARAMETER PartnerId
    Filter events by partner ID.
.PARAMETER EventType
    One or more event type strings (e.g. 'login.failure', 'new.device').
    See Get-SaaSquatchEventType for the full reference list.
.PARAMETER AlertStatus
    One or more alert severity levels: low, medium, critical.
.PARAMETER StartDate
    Start of the time window (inclusive). Required when -All is used.
.PARAMETER EndDate
    End of the time window (inclusive). Defaults to now when -All is used.
.PARAMETER All
    Page through all matching events. Requires -StartDate.
    WARNING: Large time windows can generate many API calls. Use -StartDate/-EndDate
    to scope the query.
.EXAMPLE
    # Last 10 events for a customer
    Get-SaaSquatchEvent -CustomerId 'your-customer-id'
.EXAMPLE
    # All critical events in March 2026
    Get-SaaSquatchEvent -CustomerId 'your-customer-id' `
        -AlertStatus critical `
        -StartDate '2026-03-01T00:00:00' -EndDate '2026-03-31T23:59:59' `
        -All
.EXAMPLE
    # Failed logins in the last 48 hours
    $start = (Get-Date).AddHours(-48) | ConvertTo-SaaSquatchDateTime
    $end   = Get-Date | ConvertTo-SaaSquatchDateTime
    Get-SaaSquatchEvent -EventType 'login.failure','login.failure.3.attempts' `
        -StartDate $start -EndDate $end -All
.EXAMPLE
    # Pipe customers and pull all events for each
    Get-SaaSquatchCustomer | ForEach-Object {
        Get-SaaSquatchEvent -CustomerId $_.id `
            -StartDate '2026-03-01T00:00:00' -All
    }
.OUTPUTS
    [PSCustomObject[]]
#>
    [CmdletBinding()]
    param(
        [Parameter(ValueFromPipelineByPropertyName)]
        [Alias('id')]
        [string]$CustomerId,

        [string]$PartnerId,

        [Alias('EventTypes')]
        [string[]]$EventType,

        [Alias('AlertStatuses')]
        [ValidateSet('low', 'medium', 'critical')]
        [string[]]$AlertStatus,

        [string]$StartDate,

        [string]$EndDate,

        [switch]$All
    )

    process {
        $query = @{}
        if ($CustomerId)   { $query['customerId']    = $CustomerId }
        if ($PartnerId)    { $query['partnerId']     = $PartnerId }
        if ($EventType)    { $query['eventTypes']    = $EventType -join ',' }
        if ($AlertStatus)  { $query['alertStatuses'] = $AlertStatus -join ',' }
        if ($StartDate)    { $query['startDate']     = $StartDate }
        if ($EndDate)      { $query['endDate']       = $EndDate }

        if ($All) {
            if (-not $StartDate) {
                throw '-StartDate is required when using -All.'
            }
            $start = [datetime]::Parse($StartDate)
            $end   = if ($EndDate) { [datetime]::Parse($EndDate) } else { Get-Date }
            $results = Invoke-SaaSquatchPagedEvents -BaseQuery $query -Start $start -End $end
        } else {
            $results = Invoke-SaaSquatchRequest -Endpoint '/reports/events' -QueryParameters $query
        }

        # The API ignores eventTypes and alertStatuses server-side — filter client-side.
        if ($EventType)   { $results = @($results | Where-Object { $_.jointType -in $EventType }) }
        if ($AlertStatus) { $results = @($results | Where-Object { $_.alertStatus -in $AlertStatus }) }

        return $results
    }
}

function Get-SaaSquatchEventById {
<#
.SYNOPSIS
    Retrieves a specific event by its ID.
.PARAMETER EventId
    The event ID string.
.EXAMPLE
    Get-SaaSquatchEventById -EventId '2235783306607606325'
.OUTPUTS
    [PSCustomObject]
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, ValueFromPipelineByPropertyName)]
        [string]$EventId
    )
    process {
        # API ignores the eventId query param — filter client-side from the returned batch.
        # Note: only events present in the current default result set (≤10) can be matched this way.
        $batch = Invoke-SaaSquatchRequest -Endpoint '/reports/events' -QueryParameters @{ eventId = $EventId }
        return @($batch | Where-Object { $_.eventId -eq $EventId })
    }
}

#endregion

#region SOC Helper Cmdlets

function Get-SaaSquatchCriticalEvent {
<#
.SYNOPSIS
    Returns critical-severity events within a lookback window.
.PARAMETER Hours
    How many hours back to search (default: 24, max: 168).
.PARAMETER CustomerId
    Optionally scope to a single customer.
.EXAMPLE
    Get-SaaSquatchCriticalEvent -Hours 4
.EXAMPLE
    Get-SaaSquatchCriticalEvent -Hours 24 -CustomerId 'your-customer-id'
.OUTPUTS
    [PSCustomObject[]]
#>
    [CmdletBinding()]
    param(
        [ValidateRange(1, 168)]
        [int]$Hours = 24,

        [string]$CustomerId
    )

    $start = (Get-Date).AddHours(-$Hours) | ConvertTo-SaaSquatchDateTime
    $end   = Get-Date | ConvertTo-SaaSquatchDateTime

    $splat = @{
        AlertStatus = 'critical'
        StartDate   = $start
        EndDate     = $end
        All         = $true
    }
    if ($CustomerId) { $splat['CustomerId'] = $CustomerId }

    return Get-SaaSquatchEvent @splat
}

function Get-SaaSquatchFailedLogin {
<#
.SYNOPSIS
    Returns failed login events within a lookback window.
.PARAMETER Hours
    How many hours back to search (default: 24, max: 168).
.PARAMETER IncludeMultipleAttempts
    Also include login.failure.3.attempts events.
.PARAMETER CustomerId
    Optionally scope to a single customer.
.EXAMPLE
    Get-SaaSquatchFailedLogin -Hours 12 -IncludeMultipleAttempts
.OUTPUTS
    [PSCustomObject[]]
#>
    [CmdletBinding()]
    param(
        [ValidateRange(1, 168)]
        [int]$Hours = 24,

        [switch]$IncludeMultipleAttempts,

        [string]$CustomerId
    )

    $types = @('login.failure')
    if ($IncludeMultipleAttempts) { $types += 'login.failure.3.attempts' }

    $start = (Get-Date).AddHours(-$Hours) | ConvertTo-SaaSquatchDateTime
    $end   = Get-Date | ConvertTo-SaaSquatchDateTime

    $splat = @{
        EventType = $types
        StartDate = $start
        EndDate   = $end
        All       = $true
    }
    if ($CustomerId) { $splat['CustomerId'] = $CustomerId }

    return Get-SaaSquatchEvent @splat
}

function Get-SaaSquatchAnomalousActivity {
<#
.SYNOPSIS
    Returns events associated with anomalous or suspicious user behaviour.
.DESCRIPTION
    Searches for cross-IP connections, logins from outside approved locations,
    multiple connections from different IPs, new devices, multiple password resets,
    and account lockouts.
.PARAMETER Hours
    How many hours back to search (default: 24, max: 168).
.PARAMETER CustomerId
    Optionally scope to a single customer.
.EXAMPLE
    Get-SaaSquatchAnomalousActivity -Hours 48
.OUTPUTS
    [PSCustomObject[]]
#>
    [CmdletBinding()]
    param(
        [ValidateRange(1, 168)]
        [int]$Hours = 24,

        [string]$CustomerId
    )

    $types = @(
        'cross.ip.connections',
        'outside.own.location',
        'multiple.connection.diff.ip',
        'multiple.login.diff.ip',
        'new.device',
        'multiple.password.reset',
        'multiple.account.locks'
    )

    $start = (Get-Date).AddHours(-$Hours) | ConvertTo-SaaSquatchDateTime
    $end   = Get-Date | ConvertTo-SaaSquatchDateTime

    $splat = @{
        EventType = $types
        StartDate = $start
        EndDate   = $end
        All       = $true
    }
    if ($CustomerId) { $splat['CustomerId'] = $CustomerId }

    return Get-SaaSquatchEvent @splat
}

function Get-SaaSquatchFileShareEvent {
<#
.SYNOPSIS
    Returns file sharing events (internal and external).
.PARAMETER Hours
    How many hours back to search (default: 24, max: 168).
.PARAMETER ExternalOnly
    Only return events where files were shared externally.
.PARAMETER CustomerId
    Optionally scope to a single customer.
.EXAMPLE
    Get-SaaSquatchFileShareEvent -Hours 72 -ExternalOnly
.OUTPUTS
    [PSCustomObject[]]
#>
    [CmdletBinding()]
    param(
        [ValidateRange(1, 168)]
        [int]$Hours = 24,

        [switch]$ExternalOnly,

        [string]$CustomerId
    )

    $types = if ($ExternalOnly) {
        @('file.sharing.external', 'file.download.local.device')
    } else {
        @('file.sharing.internal', 'file.sharing.external', 'file.download.local.device', 'orphaned.links')
    }

    $start = (Get-Date).AddHours(-$Hours) | ConvertTo-SaaSquatchDateTime
    $end   = Get-Date | ConvertTo-SaaSquatchDateTime

    $splat = @{
        EventType = $types
        StartDate = $start
        EndDate   = $end
        All       = $true
    }
    if ($CustomerId) { $splat['CustomerId'] = $CustomerId }

    return Get-SaaSquatchEvent @splat
}

#endregion

#region Utility Cmdlets

function ConvertTo-SaaSquatchDateTime {
<#
.SYNOPSIS
    Formats a DateTime object into the string format required by the SaaS Alerts API.
.DESCRIPTION
    Returns yyyy-MM-ddTHH:mm:ss, which is the format accepted by startDate/endDate
    parameters on the events endpoint.
.PARAMETER DateTime
    The DateTime to convert. Accepts pipeline input.
.EXAMPLE
    Get-Date | ConvertTo-SaaSquatchDateTime
.EXAMPLE
    (Get-Date).AddHours(-24) | ConvertTo-SaaSquatchDateTime
.OUTPUTS
    [string]
#>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [datetime]$DateTime
    )
    process {
        return $DateTime.ToString("yyyy-MM-dd'T'HH:mm:ss")
    }
}

function Get-SaaSquatchEventType {
<#
.SYNOPSIS
    Returns the full reference list of supported SaaS Alerts event types.
.DESCRIPTION
    Use these values with the -EventType parameter on Get-SaaSquatchEvent.
    Grouped by category for easy reference.
.EXAMPLE
    Get-SaaSquatchEventType
.EXAMPLE
    Get-SaaSquatchEventType | Where-Object Category -eq 'Authentication'
.OUTPUTS
    [PSCustomObject[]]
#>
    [CmdletBinding()]
    param()

    return @(
        # Authentication
        [PSCustomObject]@{ Category = 'Authentication'; EventType = 'login.success';              Description = 'Successful login' }
        [PSCustomObject]@{ Category = 'Authentication'; EventType = 'login.failure';              Description = 'Failed login attempt' }
        [PSCustomObject]@{ Category = 'Authentication'; EventType = 'login.failure.3.attempts';   Description = 'Three or more consecutive login failures' }
        [PSCustomObject]@{ Category = 'Authentication'; EventType = 'cross.ip.connections';       Description = 'Login from an unexpected IP address' }
        [PSCustomObject]@{ Category = 'Authentication'; EventType = 'multiple.connection.diff.ip';Description = 'Multiple simultaneous connections from different IPs' }
        [PSCustomObject]@{ Category = 'Authentication'; EventType = 'multiple.login.diff.ip';     Description = 'Multiple logins from different IP addresses' }
        [PSCustomObject]@{ Category = 'Authentication'; EventType = 'multiple.account.locks';     Description = 'Multiple account lockouts' }
        [PSCustomObject]@{ Category = 'Authentication'; EventType = 'unable.refresh.token';       Description = 'Unable to refresh OAuth token' }

        # Location & Device
        [PSCustomObject]@{ Category = 'Location/Device'; EventType = 'outside.own.location';     Description = 'Login from outside the approved geographic location' }
        [PSCustomObject]@{ Category = 'Location/Device'; EventType = 'new.device';               Description = 'Login from a new/unrecognised device' }

        # Credentials & Account
        [PSCustomObject]@{ Category = 'Credentials';  EventType = 'password.reset';             Description = 'Password reset performed' }
        [PSCustomObject]@{ Category = 'Credentials';  EventType = 'password.change';            Description = 'Password changed' }
        [PSCustomObject]@{ Category = 'Credentials';  EventType = 'multiple.password.reset';    Description = 'Multiple password resets in a short period' }
        [PSCustomObject]@{ Category = 'Credentials';  EventType = 'account.locks';              Description = 'Account locked out (Dropbox-specific)' }

        # Permissions & OAuth
        [PSCustomObject]@{ Category = 'Permissions';  EventType = 'oauth.granted.permission';   Description = 'OAuth permission granted to an application' }
        [PSCustomObject]@{ Category = 'Permissions';  EventType = 'user.promoted.to.admin';     Description = 'User account elevated to administrator' }
        [PSCustomObject]@{ Category = 'Permissions';  EventType = 'app.perm.shared.with.add.app';Description = 'Application permissions shared with another app' }

        # File Activity
        [PSCustomObject]@{ Category = 'File Activity'; EventType = 'file.sharing.internal';     Description = 'File shared internally within the organisation' }
        [PSCustomObject]@{ Category = 'File Activity'; EventType = 'file.sharing.external';     Description = 'File shared externally outside the organisation' }
        [PSCustomObject]@{ Category = 'File Activity'; EventType = 'file.download.local.device';Description = 'File downloaded to a local device' }
        [PSCustomObject]@{ Category = 'File Activity'; EventType = 'orphaned.links';            Description = 'Shared links with no active recipient' }
        [PSCustomObject]@{ Category = 'File Activity'; EventType = 'link.cross.sharing';        Description = 'Cross-tenant link sharing detected' }

        # Policy & Security Config
        [PSCustomObject]@{ Category = 'Policy';       EventType = 'security.group.changes';     Description = 'Security group membership changed' }
        [PSCustomObject]@{ Category = 'Policy';       EventType = 'security.policy.changes';    Description = 'Security policy modified' }
        [PSCustomObject]@{ Category = 'Policy';       EventType = 'db.team.policies.changed';   Description = 'Dropbox team policy changed' }

        # Salesforce
        [PSCustomObject]@{ Category = 'Salesforce';   EventType = 'sf.external.datasource.added'; Description = 'External data source added in Salesforce' }
        [PSCustomObject]@{ Category = 'Salesforce';   EventType = 'sf.external.obh.add.updates';  Description = 'External object handler updates in Salesforce' }

        # Integration / Misc
        [PSCustomObject]@{ Category = 'Integration';  EventType = 'domain.access.attempt';      Description = 'Attempt to access a monitored domain' }
        [PSCustomObject]@{ Category = 'Integration';  EventType = 'integration.detail.link.shared'; Description = 'Integration detail link shared' }
        [PSCustomObject]@{ Category = 'Integration';  EventType = 'application.event.saas.integration'; Description = 'SaaS integration application event' }
    )
}

function Export-SaaSquatchEvent {
<#
.SYNOPSIS
    Exports SaaS Alerts events to a CSV or JSON file.
.DESCRIPTION
    Retrieves events using Get-SaaSquatchEvent (with -All for full pagination) and
    writes a flat, analytics-friendly file. Nested location, user, customer, and
    product objects are flattened into top-level columns.
.PARAMETER OutputPath
    Destination file path. Extension determines format if -Format is omitted (.csv / .json).
.PARAMETER Format
    CSV or JSON. Inferred from OutputPath extension when not specified.
.PARAMETER CustomerId
    Scope events to a specific customer.
.PARAMETER AlertStatus
    Filter by severity: low, medium, critical.
.PARAMETER EventType
    Filter by one or more event type strings.
.PARAMETER StartDate
    Start of time window (required).
.PARAMETER EndDate
    End of time window (defaults to now).
.EXAMPLE
    Export-SaaSquatchEvent -OutputPath '.\events.csv' `
        -CustomerId 'your-customer-id' `
        -StartDate '2026-03-01T00:00:00'
.EXAMPLE
    Export-SaaSquatchEvent -OutputPath '.\critical.json' `
        -AlertStatus critical `
        -StartDate '2026-01-01T00:00:00' -EndDate '2026-03-31T23:59:59'
.OUTPUTS
    None (writes file to disk)
#>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [string]$OutputPath,

        [ValidateSet('CSV', 'JSON')]
        [string]$Format,

        [string]$CustomerId,

        [ValidateSet('low', 'medium', 'critical')]
        [string[]]$AlertStatus,

        [string[]]$EventType,

        [Parameter(Mandatory)]
        [string]$StartDate,

        [string]$EndDate
    )

    # Infer format from extension
    if (-not $Format) {
        $ext = [System.IO.Path]::GetExtension($OutputPath).TrimStart('.').ToUpper()
        if ($ext -in 'CSV', 'JSON') { $Format = $ext }
        else { throw "Cannot infer format from extension '$ext'. Use -Format CSV or JSON." }
    }

    $splat = @{ StartDate = $StartDate; All = $true }
    if ($CustomerId)  { $splat['CustomerId']  = $CustomerId }
    if ($AlertStatus) { $splat['AlertStatus'] = $AlertStatus }
    if ($EventType)   { $splat['EventType']   = $EventType }
    if ($EndDate)     { $splat['EndDate']      = $EndDate }

    Write-Verbose "Retrieving events…"
    $events = Get-SaaSquatchEvent @splat

    if (-not $events -or $events.Count -eq 0) {
        Write-Warning 'No events matched the specified criteria.'
        return
    }

    # Flatten nested objects
    $flat = $events | ForEach-Object {
        [PSCustomObject]@{
            Time               = $_.time
            EventId            = $_.eventId
            AlertStatus        = $_.alertStatus
            EventType          = $_.jointType
            Description        = $_.jointDesc
            DescriptionDetail  = $_.jointDescAdditional
            UserName           = $_.user.name
            UserId             = $_.user.id
            IP                 = $_.ip
            Country            = $_.location.country
            Region             = $_.location.region
            City               = $_.location.city
            IPOwner            = $_.location.ip_owner
            IsThreat           = $_.location.ipInfo.threat.is_threat
            IsVPN              = $_.location.ipInfo.threat.is_vpn
            IsProxy            = $_.location.ipInfo.threat.is_proxy
            TrustScore         = $_.location.ipInfo.threat.scores.trust_score
            CustomerName       = $_.customer.name
            CustomerId         = $_.customer.id
            PartnerName        = $_.partner.name
            PartnerId          = $_.partner.id
            ProductName        = $_.product.name
            ProductType        = $_.product.type
            Operation          = $_.operation
            LogonError         = $_.logonError
        }
    }

    $dir = Split-Path $OutputPath -Parent
    if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }

    if ($PSCmdlet.ShouldProcess($OutputPath, "Export $($flat.Count) events as $Format")) {
        switch ($Format) {
            'CSV'  { $flat | Export-Csv -Path $OutputPath -NoTypeInformation -Encoding UTF8 }
            'JSON' { $flat | ConvertTo-Json -Depth 5 | Set-Content -Path $OutputPath -Encoding UTF8 }
        }
        Write-Verbose "Exported $($flat.Count) events to $OutputPath"
    }
}

function Get-SaaSquatchConfiguration {
<#
.SYNOPSIS
    Displays the current module configuration and connection status.
.EXAMPLE
    Get-SaaSquatchConfiguration
.OUTPUTS
    [PSCustomObject]
#>
    [CmdletBinding()]
    param()

    [PSCustomObject]@{
        BaseUri          = $Script:BaseUri
        ApiKeyConfigured = [bool]$Script:ApiKey
        MaxRetries       = $Script:MaxRetries
    }
}

#endregion

#region Module Exports

Export-ModuleMember -Function @(
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

#endregion
