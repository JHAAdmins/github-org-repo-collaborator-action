<#
.SYNOPSIS
    Export all GitHub organization repository collaborators, including SSO, verified org domain emails, as well as team-based permissions.

.PARAMETER Token
    GitHub Personal Access Token (or GitHub App installation token).

.PARAMETER Org
    GitHub organization name.

.PARAMETER Permission
    Filter by permission (ADMIN, MAINTAIN, WRITE, TRIAGE, READ, ALL). Default: ALL.

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

.PARAMETER FetchNames
    If set, fetch each user's "name" from their profile if not present in the collaborator API response.

.EXAMPLE
    .\Get-GitHubOrgRepoCollaborators.ps1 -Token 'ghp_...' -Org 'octo-org' -FetchNames
#>
param(
    [Parameter(Mandatory=$true)][string]$Token,
    [Parameter(Mandatory=$true)][string]$Org,
    [Parameter(Mandatory=$true)][string]$Permission,
    [string]$Affil = "ALL",
    [string]$CSVPath = "./reports/$Org-$Permission.csv",
    [string]$JSONPath = "./reports/$Org-$Permission.json",
    [int]$RetryCount = 5,
    [int]$Delay = 2000,
    [switch]$FetchNames
)

Write-Log "========== Script started =========="
Write-Log "Step 0: Parameters received."
Write-Host "DEBUG: Org parameter received: '$Org'"  

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
            Write-Log "REST API Call: $Method $Uri (attempt $($i+1))"
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
            Write-Log "GraphQL API Call (attempt $($i+1)), Query: $($Query.Substring(0, 40))..."
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

function Get-GitHubUserName {
    param([string]$Username)
    Write-Log "Fetching public profile name for user: $Username"
    $uri = "https://api.github.com/users/$Username"
    $resp = Invoke-GitHubREST -Uri $uri
    return $resp.name
}

# Removed Get-GitHubUserPublicEmail function

function Get-GitHubOrgSSOEmails {
    param(
        [string]$Token,
        [string]$Org
    )
    Write-Log "Step 3: Checking for SSO/SAML provider ..."
    $ssoQuery = @'
query SSOProvider($Org: String!) {
  organization(login: $Org) {
    samlIdentityProvider { id }
  }
}
'@
    try {
        Write-Log "Org parameter value: '$Org'"
        Write-Log "Executing SSO Query..."
        $ssoData = Invoke-GitHubGraphQL -Query $ssoQuery -Variables @{ Org = $Org }
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
query SSOEmails($Org: String!, $cursor: String) {
  organization(login: $Org) {
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
        $qvars = @{ Org = $Org; cursor = $endCursor }
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

function Get-GitHubOrgVerifiedEmails {
    param(
        [string]$Token,
        [string]$Org,
        [string[]]$Logins
    )
    Write-Log "Step 10: Fetching organization-verified emails for users..."
    $results = @()
    foreach ($login in $Logins) {
        $query = @'
query($Org: String!, $login: String!) {
  user(login: $login) {
    organizationVerifiedDomainEmails(login: $Org)
  }
}
'@
        try {
            Write-Log "Org parameter value: '$Org', login: '$login'"
            $data = Invoke-GitHubGraphQL -Query $query -Variables @{ Org = $Org; login = $login }
            $emails = $data.user.organizationVerifiedDomainEmails
            if ($emails) {
                $results += [PSCustomObject]@{
                    login = $login
                    verifiedEmail = ($emails -join ', ')
                }
            }
        } catch {
            Write-ErrorLog "Verified email query for $login failed: $($_.Exception.Message)"
        }
        Start-Sleep -Milliseconds 200 # To avoid rate limits
    }
    Write-Log "Fetched $($results.Count) verified emails."
    return $results
}

# Permission mapping (API key => display name, and display name => API key)
$permissionMap = @{
    "read" = "pull"
    "write" = "push"
    "admin" = "admin"
    "maintain" = "maintain"
    "triage" = "triage"
    "all" = "all"
}
$permissionDisplay = @{
    "pull" = "read"
    "push" = "write"
    "admin" = "admin"
    "maintain" = "maintain"
    "triage" = "triage"
}

$permKey = $Permission.ToLower()
$apiPermKey = $permissionMap[$permKey]

# 1. Get org ID (GraphQL)
Write-Log "Step 1: Getting org ID for $Org ..."
$orgIdQuery = @'
query OrgId($Org: String!) {
  organization(login: $Org) { id }
}
'@
$orgIdData = Invoke-GitHubGraphQL -Query $orgIdQuery -Variables @{ Org = $Org }
$orgId = $orgIdData.organization.id
if (-not $orgId) { throw "Could not get org ID for $Org" }
Write-Log "Step 1: Org ID = $orgId"

# 2. Get all repositories in org (REST, paginated)
Write-Log "Step 2: Listing repositories in org $Org ..."
$repos = @()
$page = 1
do {
    Write-Log "Fetching repo page $page ..."
    $uri = "https://api.github.com/orgs/$Org/repos?type=all&per_page=100&page=$page"
    $resp = Invoke-GitHubREST -Uri $uri
    if ($resp) { $repos += $resp }
    $page++
} while ($resp.Count -eq 100)
Write-Log "Step 2: $($repos.Count) repositories found."

# 3. Get SSO/SAML emails (GraphQL)
$emailArray = @()
try {
    Write-Log "Step 3: Getting SSO/SAML emails for $Org ..."
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
Write-Log "Step 3: SSO/SAML emails fetched: $($emailArray.Count)"

# 4. Get all org members with role (GraphQL)
Write-Log "Step 4: Fetching org members with role ..."
$memberArray = @()
$endCursor = $null
do {
    Write-Log "Fetching org member page with cursor '$endCursor' ..."
    $membersQuery = @'
query MembersWithRole($Org: String!, $cursor: String) {
  organization(login: $Org) {
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
    $qvars = @{ Org = $Org; cursor = $endCursor }
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
Write-Log "Step 4: Fetched $($memberArray.Count) org members with role."

# 5. Get all teams in org (REST)
Write-Log "Step 5: Fetching teams in org ..."
$teams = @()
$page = 1
do {
    Write-Log "Fetching teams page $page ..."
    $uri = "https://api.github.com/orgs/$Org/teams?per_page=100&page=$page"
    $resp = Invoke-GitHubREST -Uri $uri
    if ($resp) { $teams += $resp }
    $page++
} while ($resp.Count -eq 100)
Write-Log "Step 5: $($teams.Count) teams found."

# 6. Build team-repo-permission map and team-member map
Write-Log "Step 6: Building team-repo-permission and team-member map ..."
$teamRepoPerms = @()
$teamMembers = @()
foreach ($team in $teams) {
    $teamSlug = $team.slug
    Write-Log "Processing team: $teamSlug"

    # Get all repos for team and their permissions
    $pageTR = 1
    do {
        Write-Log "Fetching team repos (team: $teamSlug, page: $pageTR) ..."
        $uri = "https://api.github.com/orgs/$Org/teams/$teamSlug/repos?per_page=100&page=$pageTR"
        $resp = Invoke-GitHubREST -Uri $uri
        if ($resp) {
            foreach ($repoPerm in $resp) {
                $teamRepoPerms += [PSCustomObject]@{
                    repo = $repoPerm.name
                    team = $teamSlug
                    permission = $repoPerm.permissions | Get-Member -MemberType NoteProperty | Where-Object { $repoPerm.permissions."$($_.Name)" } | ForEach-Object { $_.Name }
                }
            }
        }
        $pageTR++
    } while ($resp.Count -eq 100)

    # Get all members for team
    $pageTM = 1
    do {
        Write-Log "Fetching team members (team: $teamSlug, page: $pageTM) ..."
        $uri = "https://api.github.com/orgs/$Org/teams/$teamSlug/members?per_page=100&page=$pageTM"
        $resp = Invoke-GitHubREST -Uri $uri
        if ($resp) {
            foreach ($member in $resp) {
                $teamMembers += [PSCustomObject]@{
                    team = $teamSlug
                    login = $member.login
                }
            }
        }
        $pageTM++
    } while ($resp.Count -eq 100)
}
Write-Log "Step 6: Team-repo-permission map and team-member map built."

# 7. Build team-user-repo-permission mapping (effective permissions for team memberships)
Write-Log "Step 7: Building team-user-repo-permission mapping ..."
$teamUserRepoPerms = @()
foreach ($trp in $teamRepoPerms) {
    $repoName = $trp.repo
    $teamSlug = $trp.team
    $permissions = @($trp.permission)
    $members = $teamMembers | Where-Object { $_.team -eq $teamSlug }
    foreach ($member in $members) {
        foreach ($perm in $permissions) {
            $teamUserRepoPerms += [PSCustomObject]@{
                orgRepo = $repoName
                login = $member.login
                name = ""
                ssoEmail = ""
                verifiedEmail = ""
                # Removed publicEmail field
                permission = $permissionDisplay[$perm]
                org = $Org
                orgpermission = ""
                viaTeam = $teamSlug
            }
        }
    }
}
Write-Log "Step 7: Team-user-repo-permission mapping built."

# 8. For each repo, get direct collaborators (REST), filter by permission type
Write-Log "Step 8: Processing repo collaborators..."
$collabsArray = @()
foreach ($repo in $repos) {
    Write-Log "Repo: $($repo.name)"
    $collabUri = "https://api.github.com/repos/$Org/$($repo.name)/collaborators?affiliation=$Affil&per_page=100"
    $collabs = Invoke-GitHubREST -Uri $collabUri
    if ($collabs) {
        foreach ($collab in $collabs) {
            $login = $collab.login
            $name = $collab.name
            if ($FetchNames -and ([string]::IsNullOrWhiteSpace($name))) {
                $name = Get-GitHubUserName $login
                Start-Sleep -Milliseconds 100 # To avoid rate limit
            }

            $permissions = $collab.permissions
            $directPerm = ""
            foreach ($permKeyAPI in $permissionDisplay.Keys) {
                if ($permissions.$permKeyAPI) {
                    $directPerm = $permissionDisplay[$permKeyAPI]
                }
            }

            if (($Permission -eq "ALL" -and $directPerm) -or ($permKey -eq $directPerm)) {
                $ssoEmailObj = $emailArray | Where-Object { $_.login -eq $login }
                $ssoEmailValue = if ($ssoEmailObj) { $ssoEmailObj.ssoEmail } else { "" }
                $verifiedEmail = ""
                # Removed publicEmail variable
                $member = $memberArray | Where-Object { $_.login -eq $login }
                $memberValue = if ($member) { $member.role } else { "OUTSIDE COLLABORATOR" }

                $collabsArray += [PSCustomObject]@{
                    orgRepo = $repo.name
                    login = $login
                    name = $name
                    ssoEmail = $ssoEmailValue
                    verifiedEmail = $verifiedEmail
                    # Removed publicEmail field
                    permission = $directPerm
                    org = $Org
                    orgpermission = $memberValue
                    viaTeam = ""
                }
            }
        }
    }
    Start-Sleep -Seconds 2 # Longer sleep to respect rate limits
}
Write-Log "Step 8: Repo collaborators processed."

# 9. Combine/merge both direct and team-based permissions, deduplicate by highest permission
Write-Log "Step 9: Combining and deduplicating collaborator and team permissions ..."
$allRows = @()
$rowsByKey = @{}

# Add all direct collaborators
foreach ($c in $collabsArray) {
    $key = "$($c.orgRepo):$($c.login)"
    $rowsByKey[$key] = $c
}

# Add/merge team-user-repo-permissions
foreach ($t in $teamUserRepoPerms) {
    $key = "$($t.orgRepo):$($t.login)"
    if ($rowsByKey.ContainsKey($key)) {
        # If direct and team, keep highest
        $current = $rowsByKey[$key]
        $order = @("read", "triage", "write", "maintain", "admin")
        $curIdx = $order.IndexOf($current.permission)
        $teamIdx = $order.IndexOf($t.permission)
        if ($teamIdx -gt $curIdx) {
            $rowsByKey[$key] = $t
        } elseif ($teamIdx -eq $curIdx -and -not [string]::IsNullOrWhiteSpace($t.viaTeam)) {
            # If equal, prefer direct, unless this is the only way (set viaTeam info just for info)
            $rowsByKey[$key].viaTeam += ",$($t.viaTeam)"
        }
    } else {
        $rowsByKey[$key] = $t
    }
}

$allRows = $rowsByKey.Values
Write-Log "Step 9: Combination and deduplication complete. Total rows: $($allRows.Count)"

# 10. Fetch verified and SSO emails for all unique logins
Write-Log "Step 10: Fetching verified emails for all unique logins..."
$uniqueLogins = $allRows | Select-Object -ExpandProperty login -Unique

$verifiedEmails = Get-GitHubOrgVerifiedEmails -Token $Token -Org $Org -Logins $uniqueLogins
$verifiedEmailsHash = @{}
foreach ($v in $verifiedEmails) { $verifiedEmailsHash[$v.login] = $v.verifiedEmail }

$ssoEmailsHash = @{}
foreach ($s in $emailArray) { $ssoEmailsHash[$s.login] = $s.ssoEmail }

# 11. Merge email types into each row
Write-Log "Step 11: Merging email addresses into each row ..."
foreach ($row in $allRows) {
    # Removed publicEmail assignment
    $row.verifiedEmail  = $verifiedEmailsHash[$row.login]
    $row.ssoEmail       = $ssoEmailsHash[$row.login]
    if (-not $row.name -or $row.name -eq "") {
        $row.name = Get-GitHubUserName $row.login
    }
    if (-not $row.orgpermission -or $row.orgpermission -eq "") {
        $member = $memberArray | Where-Object { $_.login -eq $row.login }
        $row.orgpermission = if ($member) { $member.role } else { "OUTSIDE COLLABORATOR" }
    }
}
Write-Log "Step 11: Email merging complete."

# 12. Filter by permission if not ALL
Write-Log "Step 12: Filtering by permission ($Permission) ..."
if ($Permission -ne "ALL") {
    $allRows = $allRows | Where-Object { $_.permission -eq $permKey }
}
Write-Log "Step 12: Filtering complete. Rows remaining: $($allRows.Count)"

# 13. Sort and export
Write-Log "Step 13: Exporting CSV to $CSVPath ..."
$allRows | Sort-Object orgRepo | Export-Csv -Path $CSVPath -NoTypeInformation -Encoding UTF8

if ($JSONPath) {
    Write-Log "Step 13: Exporting JSON to $JSONPath ..."
    $allRows | Sort-Object orgRepo | ConvertTo-Json -Depth 10 | Out-File -Encoding UTF8 $JSONPath
}

Write-Log "========== Done. $($allRows.Count) rows exported. =========="
