<#
.SYNOPSIS
    PowerShell script to export all GitHub organization repository collaborators and their SSO/verified emails.

.PARAMETER Token
    GitHub Personal Access Token (or GitHub App installation token).

.PARAMETER Org
    GitHub organization name.

.PARAMETER Permission
    Filter by permission (ADMIN, MAINTAIN, WRITE, TRIAGE, READ, ALL). Default: ADMIN.

.PARAMETER Affil
    Collaborators affiliation (ALL, OUTSIDE, DIRECT). Default: ALL.

.PARAMETER CSVPath
    Output CSV file path.

.PARAMETER JSONPath
    Output JSON file path (optional).

.PARAMETER RetryCount
    Number of retries for API calls. Default: 5.

.PARAMETER Delay
    Initial delay (ms) for retry backoff. Default: 2000.

.EXAMPLE
    .\Get-GitHubOrgRepoCollaborators.ps1 -Token 'ghp_...' -Org 'octo-org' -Permission "WRITE"
#>
param(
    [Parameter(Mandatory=$true)][string]$Token,
    [Parameter(Mandatory=$true)][string]$Org,
    [string]$Permission = "ADMIN",
    [string]$Affil = "ALL",
    [string]$CSVPath = "./reports/$Org-$Permission.csv",
    [string]$JSONPath = "./reports/$Org-$Permission.json",
    [int]$RetryCount = 5,
    [int]$Delay = 2000
)

function Write-Log { param($msg) Write-Host "[$((Get-Date).ToString('s'))] $msg" }
function Write-ErrorLog { param($msg) Write-Host "[$((Get-Date).ToString('s'))] ERROR: $msg" -ForegroundColor Red }

function Merge-Headers {
    param($base, $override)
    $merged = @{}
    foreach ($key in $base.Keys) { $merged[$key] = $base[$key] }
    if ($override) {
        foreach ($key in $override.Keys) { $merged[$key] = $override[$key] }
    }
    return $merged
}

function Log-RateLimitHeaders {
    param($Headers, [string]$ApiType)
    if ($Headers) {
        $limit = $Headers["X-RateLimit-Limit"]
        $remaining = $Headers["X-RateLimit-Remaining"]
        $reset = $Headers["X-RateLimit-Reset"]
        $retry = $Headers["Retry-After"]
        $secondary = $Headers["X-RateLimit-Secondary-Remaining"]

        if ($limit -or $remaining -or $reset) {
            Write-Log "$ApiType Rate Limit: limit=$limit, remaining=$remaining, reset=$reset"
        }
        if ($retry) {
            Write-Log "$ApiType Secondary Rate Limit: Retry-After=$retry seconds"
        }
        if ($secondary) {
            Write-Log "$ApiType Secondary Rate Limit: secondary remaining=$secondary"
        }
    }
}

function Get-RateLimit {
    $uri = "https://api.github.com/rate_limit"
    $headers = @{
        Authorization = "token $Token"
        Accept        = "application/vnd.github+json"
        "User-Agent"  = "PowerShell-GitHub-Action"
    }
    try {
        $resp = Invoke-WebRequest -Uri $uri -Headers $headers -UseBasicParsing
        Log-RateLimitHeaders $resp.Headers "REST"
        $content = $resp.Content | ConvertFrom-Json
        $remaining = $content.resources.core.remaining
        $reset = $content.resources.core.reset
        return @{ remaining = $remaining; reset = $reset }
    } catch {
        if ($_.Exception.Response) {
            Log-RateLimitHeaders $_.Exception.Response.Headers "REST"
        }
        Write-ErrorLog "Could not get rate limit info: $($_.Exception.Message)"
        return @{ remaining = 0; reset = [int][DateTimeOffset]::UtcNow.ToUnixTimeSeconds() + 60 }
    }
}

function Wait-IfRateLimited {
    $rateInfo = Get-RateLimit
    if ($rateInfo.remaining -lt 5) { # Set threshold as needed
        $waitSeconds = $rateInfo.reset - [int][DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
        if ($waitSeconds -gt 0) {
            Write-Log "Rate limit low ($($rateInfo.remaining)). Waiting $waitSeconds seconds until reset."
            Start-Sleep -Seconds $waitSeconds
        }
    }
}

function Invoke-GitHubREST {
    param(
        [string]$Uri,
        [string]$Method = "GET",
        $Body = $null,
        $Headers = $null
    )
    $defaultHeaders = @{
        Authorization = "token $Token"
        Accept        = "application/vnd.github+json"
        "User-Agent"  = "PowerShell-GitHub-Action"
    }
    $headers = Merge-Headers $defaultHeaders $Headers
    for ($i=0; $i -lt $RetryCount; $i++) {
        Wait-IfRateLimited
        try {
            $resp = Invoke-WebRequest -Uri $Uri -Headers $headers -Method $Method -UseBasicParsing
            Log-RateLimitHeaders $resp.Headers "REST"
            if ($resp.Content) {
                return $resp.Content | ConvertFrom-Json
            }
            return $null
        } catch {
            if ($_.Exception.Response) {
                Log-RateLimitHeaders $_.Exception.Response.Headers "REST"
            }
            Write-ErrorLog "$($_.Exception.Message) (attempt $($i+1))"
            if ($i -eq $RetryCount-1) { throw }
            Start-Sleep -Milliseconds ($Delay * [math]::Pow(2,$i))
        }
    }
    return $null
}

function Invoke-GitHubGraphQL {
    param(
        [string]$Query,
        $Variables = $null
    )
    $defaultHeaders = @{
        Authorization = "token $Token"
        Accept        = "application/vnd.github+json"
        "User-Agent"  = "PowerShell-GitHub-Action"
    }
    $headers = Merge-Headers $defaultHeaders $null
    $body = @{ query = $Query }
    if ($Variables) { $body.variables = $Variables }
    $jsonBody = $body | ConvertTo-Json -Depth 10
    $resp = $null
    for ($i=0; $i -lt $RetryCount; $i++) {
        Wait-IfRateLimited
        try {
            $webResp = Invoke-WebRequest -Uri "https://api.github.com/graphql" -Method POST -Headers $headers -Body $jsonBody -ContentType "application/json" -UseBasicParsing
            Log-RateLimitHeaders $webResp.Headers "GraphQL"
            $respObj = $webResp.Content | ConvertFrom-Json
            if ($respObj.errors) { throw ($respObj.errors | ConvertTo-Json) }
            return $respObj.data
        } catch {
            if ($_.Exception.Response) {
                Log-RateLimitHeaders $_.Exception.Response.Headers "GraphQL"
            }
            Write-ErrorLog "GraphQL: $($_.Exception.Message) (attempt $($i+1))"
            if ($i -eq $RetryCount-1) { throw }
            Start-Sleep -Milliseconds ($Delay * [math]::Pow(2,$i))
        }
    }
    return $null
}

# --- SSO Email Extraction Function ---
function Get-GitHubOrgSSOEmails {
    param(
        [string]$Token,
        [string]$Org
    )
    Write-Log "Checking for SSO/SAML provider ..."
    $ssoQuery = @'
query SSOProvider($org: String!) {
  organization(login: $org) {
    samlIdentityProvider { id }
  }
}
'@
    try {
        Write-Log "Executing SSO Query..."
        $ssoData = Invoke-GitHubGraphQL -Query $ssoQuery -Variables @{ org = $Org }
        Write-Log "SSO Query Response: $($ssoData | ConvertTo-Json -Depth 10)"
    } catch {
        $errMsg = $_.Exception.Message
        Write-ErrorLog "SSO Query Error: $errMsg"
        if ($errMsg -like "*SAML identity provider is disabled when an Enterprise SAML identity provider is available*" -or
            $errMsg -like "*FORBIDDEN*") {
            Write-Log "Enterprise SAML detected; SSO/SAML email extraction is not available via GitHub API."
            return @()
        } else {
            throw
        }
    }
    if (-not $ssoData.organization.samlIdentityProvider) {
        Write-Log "Organization does not have SAML SSO enabled or token lacks permission."
        return @()
    }

    Write-Log "Fetching SSO emails for $Org ..."
    $ssoEmailQuery = @'
query SSOEmails($org: String!, $cursor: String) {
  organization(login: $org) {
    samlIdentityProvider {
      externalIdentities(first: 50, after: $cursor) {
        edges {
          node {
            samlIdentity { nameId }
            user { login }
          }
        }
        pageInfo { hasNextPage endCursor }
      }
    }
  }
}
'@
    $emailArray = @()
    $endCursor = $null
    do {
        $qvars = @{ org = $Org; cursor = $endCursor }
        Write-Log "SSO Email Query Variables: $($qvars | ConvertTo-Json -Depth 10)"
        $result = Invoke-GitHubGraphQL -Query $ssoEmailQuery -Variables $qvars
        Write-Log "SSO Email Query Response: $($result | ConvertTo-Json -Depth 10)"
        if (-not $result.organization.samlIdentityProvider) { break }
        $edges = $result.organization.samlIdentityProvider.externalIdentities.edges
        foreach ($edge in $edges) {
            if ($edge.node.user) {
                $emailArray += [PSCustomObject]@{
                    login   = $edge.node.user.login
                    ssoEmail = $edge.node.samlIdentity.nameId
                }
            }
        }
        $pi = $result.organization.samlIdentityProvider.externalIdentities.pageInfo
        Write-Log "Pagination Info: hasNextPage=$($pi.hasNextPage), endCursor=$($pi.endCursor)"
        $endCursor = $pi.endCursor
    } while ($pi.hasNextPage)
    Write-Log "Fetched $($emailArray.Count) SSO emails."
    return $emailArray
}

# 1. Get org ID (GraphQL)
Write-Log "Getting org ID for $Org ..."
$orgIdQuery = @'
query OrgId($org: String!) {
  organization(login: $org) { id }
}
'@
$orgIdData = Invoke-GitHubGraphQL -Query $orgIdQuery -Variables @{ org = $Org }
$orgId = $orgIdData.organization.id
if (-not $orgId) { throw "Could not get org ID for $Org" }

# 2. Get all repositories in org (REST, paginated)
Write-Log "Listing repositories in org $Org ..."
$repos = @()
$page = 1
do {
    $uri = "https://api.github.com/orgs/$Org/repos?type=all&per_page=100&page=$page"
    $resp = Invoke-GitHubREST -Uri $uri
    if ($resp) { $repos += $resp }
    $page++
} while ($resp.Count -eq 100)
Write-Log "$($repos.Count) repositories found."

# 3. Get SSO/SAML emails (GraphQL) - modular call with enterprise SAML handling
$emailArray = @()
try {
    $emailArray = Get-GitHubOrgSSOEmails -Token $Token -Org $Org
} catch {
    $errMsg = $_.Exception.Message
    if ($errMsg -like "*SAML identity provider is disabled when an Enterprise SAML identity provider is available*" -or
        $errMsg -like "*FORBIDDEN*") {
        Write-Log "Enterprise SAML detected; SSO/SAML email extraction is not available via GitHub API."
        $emailArray = @()
    } else {
        throw
    }
}

# 4. Get all org members with role (GraphQL)
Write-Log "Fetching org members with role ..."
$memberArray = @()
$endCursor = $null
do {
    $membersQuery = @'
query MembersWithRole($org: String!, $cursor: String) {
  organization(login: $org) {
    membersWithRole(first: 50, after: $cursor) {
      edges {
        node { login }
        role
      }
      pageInfo { hasNextPage endCursor }
    }
  }
}
'@
    $qvars = @{ org = $Org; cursor = $endCursor }
    $membersData = Invoke-GitHubGraphQL -Query $membersQuery -Variables $qvars
    $edges = $membersData.organization.membersWithRole.edges
    foreach ($edge in $edges) {
        $memberArray += [PSCustomObject]@{
            login = $edge.node.login
            role = $edge.role
        }
    }
    $pi = $membersData.organization.membersWithRole.pageInfo
    $endCursor = $pi.endCursor
} while ($pi.hasNextPage)
Write-Log "Fetched $($memberArray.Count) org members with role."

# 5. For each repo, get collaborators (REST), filter by permission type
Write-Log "Processing repo collaborators..."
$collabsArray = @()
$permKey = $Permission.ToLower()
foreach ($repo in $repos) {
    Write-Log "Repo: $($repo.name)"
    $collabUri = "https://api.github.com/repos/$Org/$($repo.name)/collaborators?affiliation=$Affil&per_page=100"
    $collabs = Invoke-GitHubREST -Uri $collabUri
    if ($collabs) {
        foreach ($collab in $collabs) {
            $login = $collab.login
            $name = $collab.name

            # Determine permission for output
            $permissions = $collab.permissions
            $matchedPermission = ""
            if ($Permission -eq "ALL") {
                foreach ($key in $permissions.PSObject.Properties) {
                    if ($key.Value) {
                        $matchedPermission = $key.Name
                        break
                    }
                }
            } else {
                if ($permissions.$permKey) {
                    $matchedPermission = $permKey
                }
            }

            if ($matchedPermission) {
                # SSO email extraction (from $emailArray)
                $ssoEmailObj = $emailArray | Where-Object { $_.login -eq $login }
                $ssoEmailValue = if ($ssoEmailObj) { $ssoEmailObj.ssoEmail } else { "" }

                # Avoid per-user profile call to conserve rate limit
                $publicEmail = ""

                $member = $memberArray | Where-Object { $_.login -eq $login }
                $memberValue = if ($member) { $member.role } else { "OUTSIDE COLLABORATOR" }

                $collabsArray += [PSCustomObject]@{
                    orgRepo = $repo.name
                    visibility = $repo.visibility
                    login = $login
                    name = $name
                    ssoEmail = $ssoEmailValue
                    publicEmail = $publicEmail
                    permission = $matchedPermission
                    org = $Org
                    orgpermission = $memberValue
                }
            }
        }
    }
    Start-Sleep -Seconds 2 # Longer sleep to respect rate limits
}

# 6. Sort and export
Write-Log "Exporting CSV to $CSVPath ..."
$collabsArray | Sort-Object orgRepo | Export-Csv -Path $CSVPath -NoTypeInformation -Encoding UTF8

if ($JSONPath) {
    Write-Log "Exporting JSON to $JSONPath ..."
    $collabsArray | Sort-Object orgRepo | ConvertTo-Json -Depth 10 | Out-File -Encoding UTF8 $JSONPath
}

Write-Log "Done. $($collabsArray.Count) rows exported."
