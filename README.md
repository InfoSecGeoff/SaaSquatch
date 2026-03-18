# SaaSquatch

A PowerShell module for the [SaaS Alerts](https://www.saasalerts.com) Partner API. Provides cmdlets for retrieving customers, users, and security events, with full time-window pagination, SOC-focused helper functions, and CSV/JSON export support.

> This appears to be the first publicly documented PowerShell module for the SaaS Alerts API.

---

## Contents

- [Requirements](#requirements)
- [Installation](#installation)
- [Quick Start](#quick-start)
- [API Notes](#api-notes)
- [Command Reference](#command-reference)
  - [Authentication](#authentication)
  - [Customers](#customers)
  - [Users](#users)
  - [Events](#events)
  - [SOC Helpers](#soc-helpers)
  - [Utilities](#utilities)
- [Pagination](#pagination)
- [Event Types Reference](#event-types-reference)
- [Examples](#examples)

---

## Requirements

- PowerShell 5.1 or later (Windows PowerShell or PowerShell 7+)
- A SaaS Alerts partner account with an API key
  - Generate your key in the SaaS Alerts portal under **Settings > API > GET APIKEY**

---

## Quick Start

```powershell
# 1. Import the module
Import-Module '.\SaaSquatch\SaaSquatch.psd1'

# 2. Set your API key (use SecureString to keep it out of shell history)
$key = Read-Host 'SaaS Alerts API Key' -AsSecureString
Set-SaaSquatchApiKey -SecureApiKey $key

# 3. Verify connectivity
Test-SaaSquatchConnection

# 4. List your customers
Get-SaaSquatchCustomer | Select-Object name, customerDomain, status

# 5. Pull the last 10 events for a customer
Get-SaaSquatchEvent -CustomerId '<customer-id>'

# 6. Check for critical events in the last 24 hours
Get-SaaSquatchCriticalEvent -Hours 24
```

---

## API Notes

| Item | Detail |
|---|---|
| Base URL | `https://us-central1-the-byway-248217.cloudfunctions.net/reportApi/api/v1` |
| Auth | `X-API-Key` request header |
| Events per request | Hard-capped at **10** regardless of the `limit` parameter |
| Pagination | The `offset` parameter is **ignored** by the API. Use `-All` on `Get-SaaSquatchEvent` to paginate via time-window sliding (see [Pagination](#pagination)) |
| `eventTypes` filter | The `eventTypes` query parameter is **ignored** by the API. Filtering is applied client-side by the module. |
| `alertStatuses` filter | The `alertStatuses` query parameter is **ignored** by the API. Filtering is applied client-side by the module. |
| `eventId` field | Events from the `SAAS_ALERTS_MANAGE` product have an **empty `eventId`**. All other products return a populated ID. |
| Date format | `yyyy-MM-ddTHH:mm:ss` — use `ConvertTo-SaaSquatchDateTime` for pipeline convenience |
| Rate limiting | 429 responses are automatically retried with exponential back-off (up to 3 attempts) |
| Swagger spec | [SaaS_Alerts/functions/0.18.0](https://app.swaggerhub.com/apis/SaaS_Alerts/functions/0.18.0) |

---

## Command Reference

### Authentication

#### `Set-SaaSquatchApiKey`

Stores the API key in the module session for all subsequent requests.

```powershell
# Plain string
Set-SaaSquatchApiKey -ApiKey 'your-api-key'

# SecureString (recommended — keeps key out of shell history)
$key = Read-Host 'API Key' -AsSecureString
Set-SaaSquatchApiKey -SecureApiKey $key
```

| Parameter | Type | Required | Description |
|---|---|---|---|
| `-ApiKey` | `string` | Yes* | API key as plain text |
| `-SecureApiKey` | `SecureString` | Yes* | API key as SecureString |

*One of the two parameter sets must be used.

---

#### `Clear-SaaSquatchApiKey`

Removes the stored API key from the module session.

```powershell
Clear-SaaSquatchApiKey
```

---

#### `Test-SaaSquatchConnection`

Validates the configured API key by making a lightweight call to `/customers`. Returns `$true` on success.

```powershell
if (-not (Test-SaaSquatchConnection)) {
    throw 'Check your SaaS Alerts API key.'
}
```

---

### Customers

#### `Get-SaaSquatchCustomer`

Returns all customers associated with your partner account.

```powershell
Get-SaaSquatchCustomer

# Filter to active customers only
Get-SaaSquatchCustomer | Where-Object status -eq 'active'

# Show monitored products per customer
Get-SaaSquatchCustomer | Select-Object name, @{
    n = 'Products'
    e = { ($_.products.name) -join ', ' }
}
```

**Returns:** Array of customer objects with fields including `name`, `id`, `customerDomain`, `status`, `products`, `ipRanges`, `countries`, `asnList`, `createTime`, `billingUsers`, `totalAccountsAmount`.

---

#### `Get-SaaSquatchCustomerById`

Returns a specific customer by ID. Accepts pipeline input.

```powershell
Get-SaaSquatchCustomerById -Id 'your-customer-id'

# Pipeline
Get-SaaSquatchCustomer | Where-Object name -match 'Acme' | Get-SaaSquatchCustomerById
```

| Parameter | Type | Required | Description |
|---|---|---|---|
| `-Id` | `string` | Yes | Customer ID. Also accepts `id` and `customerId` via pipeline. |

---

### Users

#### `Get-SaaSquatchUser`

Returns all monitored user accounts for a given customer across all of their connected SaaS products.

```powershell
Get-SaaSquatchUser -CustomerId 'your-customer-id'

# Billable users only
Get-SaaSquatchUser -CustomerId 'your-customer-id' |
    Where-Object isBillable -eq $true

# All users across all customers
Get-SaaSquatchCustomer | ForEach-Object {
    Get-SaaSquatchUser -CustomerId $_.id |
        Select-Object *, @{ n = 'CustomerName'; e = { $c.name } }
}
```

| Parameter | Type | Required | Description |
|---|---|---|---|
| `-CustomerId` | `string` | Yes | Customer ID. Accepts `id` from pipeline. |

**Returns:** Array of user objects with fields including `name`, `email`, `id`, `role`, `product`, `accountEnabled`, `isBillable`, `time` (last seen), `ip` (last seen IP).

---

### Events

#### `Get-SaaSquatchEvent`

The primary event retrieval cmdlet. Returns up to 10 events per call. Use `-All` with `-StartDate` to retrieve all matching events via automatic pagination.

```powershell
# Latest 10 events (no filters)
Get-SaaSquatchEvent

# Latest 10 events for a specific customer
Get-SaaSquatchEvent -CustomerId 'your-customer-id'

# Critical events for March 2026, all pages
Get-SaaSquatchEvent `
    -CustomerId 'your-customer-id' `
    -AlertStatus critical `
    -StartDate '2026-03-01T00:00:00' `
    -EndDate   '2026-03-31T23:59:59' `
    -All

# Failed logins in the last 48 hours across all customers
$start = (Get-Date).AddHours(-48) | ConvertTo-SaaSquatchDateTime
$end   = Get-Date | ConvertTo-SaaSquatchDateTime

Get-SaaSquatchCustomer | ForEach-Object {
    Get-SaaSquatchEvent `
        -CustomerId $_.id `
        -EventType  'login.failure', 'login.failure.3.attempts' `
        -StartDate  $start `
        -EndDate    $end `
        -All
}
```

| Parameter | Type | Required | Description |
|---|---|---|---|
| `-CustomerId` | `string` | No | Filter to a specific customer |
| `-PartnerId` | `string` | No | Filter by partner ID |
| `-EventType` | `string[]` | No | One or more event type strings (see [Event Types Reference](#event-types-reference)) |
| `-AlertStatus` | `string[]` | No | `low`, `medium`, or `critical` |
| `-StartDate` | `string` | No* | Start of time window (`yyyy-MM-ddTHH:mm:ss`). Required with `-All`. |
| `-EndDate` | `string` | No | End of time window. Defaults to now when `-All` is used. |
| `-All` | `switch` | No | Paginate through all matching events. Requires `-StartDate`. |

**Returns:** Array of event objects. Key fields:

| Field | Description |
|---|---|
| `time` | Event timestamp (ISO 8601) |
| `eventId` | Unique event identifier |
| `alertStatus` | `low`, `medium`, or `critical` |
| `jointType` | Event type string (e.g. `login.failure`) |
| `jointDesc` | Human-readable event description |
| `user.name` / `user.id` | User who triggered the event |
| `ip` | Source IP address |
| `location.country/region/city` | Geo-location of the source IP |
| `location.ipInfo.threat` | Threat intelligence flags (`is_vpn`, `is_proxy`, `is_threat`, `trust_score`, etc.) |
| `customer.name` / `customer.id` | Customer the event belongs to |
| `product.name` / `product.type` | SaaS product the event came from |
| `device` | Device mapping status |
| `operation` | Product-specific operation string |

---

#### `Get-SaaSquatchEventById`

Retrieves a specific event by its ID.

> **Limitation:** The API ignores the `eventId` query parameter server-side and always returns its default result set. The module filters client-side, so this cmdlet can only match an event that is present in the most recent ~10 results. For reliable lookup of older events, use `Get-SaaSquatchEvent -All` with a narrow `-StartDate`/`-EndDate` window and filter with `Where-Object`.

```powershell
Get-SaaSquatchEventById -EventId '2235783306607606325'

# Pipeline — works when the target event is in the current result set
$events | Where-Object eventId | Get-SaaSquatchEventById
```

| Parameter | Type | Required | Description |
|---|---|---|---|
| `-EventId` | `string` | Yes | Event ID. Accepts pipeline input. |

---

### SOC Helpers

Pre-built queries for common SOC workflows. All helpers use `-All` pagination internally.

---

#### `Get-SaaSquatchCriticalEvent`

Returns all `critical`-severity events within a lookback window.

```powershell
# Last 4 hours, all customers
Get-SaaSquatchCriticalEvent -Hours 4

# Last 24 hours, scoped to one customer
Get-SaaSquatchCriticalEvent -Hours 24 -CustomerId 'your-customer-id'
```

| Parameter | Type | Default | Description |
|---|---|---|---|
| `-Hours` | `int` | `24` | Lookback window (1–168) |
| `-CustomerId` | `string` | — | Optional customer scope |

---

#### `Get-SaaSquatchFailedLogin`

Returns failed login events, optionally including repeated-failure events.

```powershell
Get-SaaSquatchFailedLogin -Hours 12

# Include "3 consecutive failures" events
Get-SaaSquatchFailedLogin -Hours 24 -IncludeMultipleAttempts
```

| Parameter | Type | Default | Description |
|---|---|---|---|
| `-Hours` | `int` | `24` | Lookback window (1–168) |
| `-IncludeMultipleAttempts` | `switch` | — | Also include `login.failure.3.attempts` |
| `-CustomerId` | `string` | — | Optional customer scope |

---

#### `Get-SaaSquatchAnomalousActivity`

Returns events associated with suspicious or anomalous user behaviour, including cross-IP logins, logins outside approved locations, new devices, multiple password resets, and account lockouts.

```powershell
Get-SaaSquatchAnomalousActivity -Hours 48

Get-SaaSquatchAnomalousActivity -Hours 24 -CustomerId 'your-customer-id'
```

| Parameter | Type | Default | Description |
|---|---|---|---|
| `-Hours` | `int` | `24` | Lookback window (1–168) |
| `-CustomerId` | `string` | — | Optional customer scope |

**Event types included:** `cross.ip.connections`, `outside.own.location`, `multiple.connection.diff.ip`, `multiple.login.diff.ip`, `new.device`, `multiple.password.reset`, `multiple.account.locks`

---

#### `Get-SaaSquatchFileShareEvent`

Returns file sharing and data exfiltration-related events.

```powershell
# All file share events (internal + external) — last 72 hours
Get-SaaSquatchFileShareEvent -Hours 72

# External sharing and local downloads only
Get-SaaSquatchFileShareEvent -Hours 24 -ExternalOnly
```

| Parameter | Type | Default | Description |
|---|---|---|---|
| `-Hours` | `int` | `24` | Lookback window (1–168) |
| `-ExternalOnly` | `switch` | — | Only external sharing and local device downloads |
| `-CustomerId` | `string` | — | Optional customer scope |

---

### Utilities

#### `ConvertTo-SaaSquatchDateTime`

Converts a `DateTime` object to the `yyyy-MM-ddTHH:mm:ss` string format required by the API. Designed for pipeline use.

```powershell
# Current time
Get-Date | ConvertTo-SaaSquatchDateTime

# 30 days ago
(Get-Date).AddDays(-30) | ConvertTo-SaaSquatchDateTime

# Use directly in event queries
Get-SaaSquatchEvent `
    -StartDate ((Get-Date).AddHours(-6) | ConvertTo-SaaSquatchDateTime) `
    -All
```

---

#### `Get-SaaSquatchEventType`

Returns the full reference table of supported event type strings, grouped by category.

```powershell
# All event types
Get-SaaSquatchEventType | Format-Table -AutoSize

# Filter by category
Get-SaaSquatchEventType | Where-Object Category -eq 'File Activity'

# Get just the type strings for use in a query
$fileTypes = Get-SaaSquatchEventType |
    Where-Object Category -eq 'File Activity' |
    Select-Object -ExpandProperty EventType
Get-SaaSquatchEvent -EventType $fileTypes -StartDate '2026-03-01T00:00:00' -All
```

---

#### `Export-SaaSquatchEvent`

Retrieves events and writes them to a flat CSV or JSON file. Nested objects (location, threat intel, user, customer, product) are all flattened to top-level columns.

```powershell
# Export all events for March 2026 to CSV
Export-SaaSquatchEvent `
    -OutputPath   '.\march_events.csv' `
    -CustomerId   'your-customer-id' `
    -StartDate    '2026-03-01T00:00:00' `
    -EndDate      '2026-03-31T23:59:59'

# Critical events only, JSON output
Export-SaaSquatchEvent `
    -OutputPath   '.\critical_q1.json' `
    -AlertStatus  critical `
    -StartDate    '2026-01-01T00:00:00' `
    -EndDate      '2026-03-31T23:59:59'

# Preview without writing (WhatIf)
Export-SaaSquatchEvent -OutputPath '.\test.csv' -StartDate '2026-03-01T00:00:00' -WhatIf
```

| Parameter | Type | Required | Description |
|---|---|---|---|
| `-OutputPath` | `string` | Yes | Destination file path |
| `-Format` | `string` | No | `CSV` or `JSON`. Inferred from extension if omitted. |
| `-CustomerId` | `string` | No | Scope to a specific customer |
| `-AlertStatus` | `string[]` | No | `low`, `medium`, `critical` |
| `-EventType` | `string[]` | No | Event type filter |
| `-StartDate` | `string` | Yes | Start of time window |
| `-EndDate` | `string` | No | End of time window (defaults to now) |

**Flattened export columns:** `Time`, `EventId`, `AlertStatus`, `EventType`, `Description`, `DescriptionDetail`, `UserName`, `UserId`, `IP`, `Country`, `Region`, `City`, `IPOwner`, `IsThreat`, `IsVPN`, `IsProxy`, `TrustScore`, `CustomerName`, `CustomerId`, `PartnerName`, `PartnerId`, `ProductName`, `ProductType`, `Operation`, `LogonError`

---

#### `Get-SaaSquatchConfiguration`

Displays current module configuration.

```powershell
Get-SaaSquatchConfiguration
```

```
BaseUri          : https://us-central1-the-byway-248217.cloudfunctions.net/reportApi/api/v1
ApiKeyConfigured : True
MaxRetries       : 3
```

---

## Pagination

The SaaS Alerts API returns a maximum of **10 events per request** and silently ignores the `offset` parameter. To retrieve more than 10 events, use `-All` on `Get-SaaSquatchEvent`.

When `-All` is specified, the module paginates by **sliding the time window forward** after each batch:

1. Request events from `StartDate` to `EndDate`
2. Record the timestamp of the latest event returned
3. Advance `StartDate` to `latestTimestamp + 1 second`
4. Repeat until a partial batch (fewer than 10) is returned or the window is exhausted
5. Deduplicate throughout to prevent duplicates at window boundaries — by `eventId` for products that supply one, or by a composite `time|eventType|user` key for products (e.g. `SAAS_ALERTS_MANAGE`) that return an empty `eventId`

```powershell
# Pull everything for a customer over the last 90 days
$start = (Get-Date).AddDays(-90) | ConvertTo-SaaSquatchDateTime
$end   = Get-Date | ConvertTo-SaaSquatchDateTime

$allEvents = Get-SaaSquatchEvent `
    -CustomerId 'your-customer-id' `
    -StartDate  $start `
    -EndDate    $end `
    -All

Write-Host "Retrieved $($allEvents.Count) total events"
```

> **Performance note:** Each page requires one API call. A 90-day window with high event volume could generate many requests. `-EventType` and `-AlertStatus` filters are applied client-side after each page is received (the API ignores them), so they reduce the size of the returned result set but do not reduce the number of API calls made.

---

## Event Types Reference

```powershell
Get-SaaSquatchEventType | Format-Table -AutoSize
```

| Category | EventType | Description |
|---|---|---|
| Authentication | `login.success` | Successful login |
| Authentication | `login.failure` | Failed login attempt |
| Authentication | `login.failure.3.attempts` | Three or more consecutive login failures |
| Authentication | `cross.ip.connections` | Login from an unexpected IP address |
| Authentication | `multiple.connection.diff.ip` | Multiple simultaneous connections from different IPs |
| Authentication | `multiple.login.diff.ip` | Multiple logins from different IP addresses |
| Authentication | `multiple.account.locks` | Multiple account lockouts |
| Authentication | `unable.refresh.token` | Unable to refresh OAuth token |
| Location/Device | `outside.own.location` | Login from outside the approved geographic location |
| Location/Device | `new.device` | Login from a new/unrecognised device |
| Credentials | `password.reset` | Password reset performed |
| Credentials | `password.change` | Password changed |
| Credentials | `multiple.password.reset` | Multiple password resets in a short period |
| Credentials | `account.locks` | Account locked out (Dropbox-specific) |
| Permissions | `oauth.granted.permission` | OAuth permission granted to an application |
| Permissions | `user.promoted.to.admin` | User account elevated to administrator |
| Permissions | `app.perm.shared.with.add.app` | Application permissions shared with another app |
| File Activity | `file.sharing.internal` | File shared internally within the organisation |
| File Activity | `file.sharing.external` | File shared externally outside the organisation |
| File Activity | `file.download.local.device` | File downloaded to a local device |
| File Activity | `orphaned.links` | Shared links with no active recipient |
| File Activity | `link.cross.sharing` | Cross-tenant link sharing detected |
| Policy | `security.group.changes` | Security group membership changed |
| Policy | `security.policy.changes` | Security policy modified |
| Policy | `db.team.policies.changed` | Dropbox team policy changed |
| Salesforce | `sf.external.datasource.added` | External data source added in Salesforce |
| Salesforce | `sf.external.obh.add.updates` | External object handler updates in Salesforce |
| Integration | `domain.access.attempt` | Attempt to access a monitored domain |
| Integration | `integration.detail.link.shared` | Integration detail link shared |
| Integration | `application.event.saas.integration` | SaaS integration application event |

---

## Examples

### Morning SOC check across all customers

```powershell
Import-Module '.\SaaSquatch\SaaSquatch.psd1'
Set-SaaSquatchApiKey -ApiKey $env:SAASALERTS_API_KEY

$customers = Get-SaaSquatchCustomer | Where-Object status -eq 'active'

foreach ($customer in $customers) {
    $critical = Get-SaaSquatchCriticalEvent -Hours 12 -CustomerId $customer.id
    $anomalous = Get-SaaSquatchAnomalousActivity -Hours 12 -CustomerId $customer.id

    if ($critical.Count -gt 0 -or $anomalous.Count -gt 0) {
        Write-Host "$($customer.name): $($critical.Count) critical, $($anomalous.Count) anomalous" -ForegroundColor Yellow
    }
}
```

### Export all events for a date range for SIEM ingestion

```powershell
Get-SaaSquatchCustomer | ForEach-Object {
    Export-SaaSquatchEvent `
        -OutputPath  ".\exports\$($_.id)_events.csv" `
        -CustomerId  $_.id `
        -StartDate   '2026-03-01T00:00:00' `
        -EndDate     '2026-03-31T23:59:59'
}
```

### Find admin promotions in the last 30 days

```powershell
$start = (Get-Date).AddDays(-30) | ConvertTo-SaaSquatchDateTime

Get-SaaSquatchCustomer | ForEach-Object {
    Get-SaaSquatchEvent `
        -CustomerId $_.id `
        -EventType  'user.promoted.to.admin' `
        -StartDate  $start `
        -All
} | Select-Object time, @{n='Customer';e={$_.customer.name}}, @{n='User';e={$_.user.name}}, ip
```

### Find external file shares with low trust score IPs

```powershell
$start = (Get-Date).AddDays(-7) | ConvertTo-SaaSquatchDateTime

Get-SaaSquatchCustomer | ForEach-Object {
    Get-SaaSquatchFileShareEvent -CustomerId $_.id -Hours 168 -ExternalOnly
} | Where-Object {
    $_.location.ipInfo.threat.scores.trust_score -lt 50
} | Select-Object time,
    @{n='Customer'; e={$_.customer.name}},
    @{n='User';     e={$_.user.name}},
    ip,
    @{n='TrustScore'; e={$_.location.ipInfo.threat.scores.trust_score}}
```

### Identify OAuth grants (potential app consent abuse)

```powershell
$start = (Get-Date).AddDays(-30) | ConvertTo-SaaSquatchDateTime

Get-SaaSquatchEvent `
    -EventType 'oauth.granted.permission' `
    -StartDate $start `
    -All |
Select-Object time,
    @{n='Customer'; e={$_.customer.name}},
    @{n='User';     e={$_.user.name}},
    @{n='Product';  e={$_.product.name}},
    jointDesc |
Sort-Object Customer, time
```

---

*Module version 1.0.0 — Geoff Tankersley*
