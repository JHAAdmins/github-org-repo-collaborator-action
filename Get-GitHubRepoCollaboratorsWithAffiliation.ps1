
param (
    [Parameter(Mandatory = $true)]
    [string]$Token,

    [Parameter(Mandatory = $true)]
    [string]$Org
)

$headers = @{
    Authorization = "Bearer $Token"
    "User-Agent"  = "PowerShell-GitHub-Audit"
    Accept        = "application/vnd.github+json"
}

function Invoke-GitHubGraphQL {
    param (
        [string]$Query,
        [hashtable]$Variables = @{}
    )
    $body = @{
        query     = $Query
        variables = $Variables
    } | ConvertTo-Json -Depth 10

    $response = Invoke-RestMethod -Uri "https://api.github.com/graphql" -Headers $headers -Method Post -Body $body -ContentType "application/json"
    Check-RateLimit
    return $response
}

function Check-RateLimit {
    $limitQuery = @"
query {
  rateLimit {
    remaining
    limit
    resetAt
  }
}
"@

    $rate = Invoke-RestMethod -Uri "https://api.github.com/graphql" -Headers $headers -Method Post -Body (@{ query = $limitQuery } | ConvertTo-Json) -ContentType "application/json"
    $info = $rate.data.rateLimit

    Write-Host "🔄 Rate Limit: $($info.remaining)/$($info.limit) requests remaining. Resets at $($info.resetAt) UTC." -ForegroundColor Cyan

    if ($info.remaining -lt 20) {
        Write-Warning "⚠️ Low rate limit. Sleeping until reset..."
        $resetTime = [DateTime]::Parse($info.resetAt).ToUniversalTime()
        $now = [DateTime]::UtcNow
        $sleepSeconds = [int]($resetTime - $now).TotalSeconds + 10
        Start-Sleep -Seconds $sleepSeconds
    }
}

# Step 1: Get org members
Write-Host "Fetching org members with roles..."
$members = @{}
$cursor = $null

do {
    $memberQuery = @"
query MembersWithRole(\$org: String!, \$cursor: String) {
  organization(login: \$org) {
    membersWithRole(first: 100, after: \$cursor) {
      nodes {
        login
        role
      }
      pageInfo {
        hasNextPage
        endCursor
      }
    }
  }
}
"@
    $vars = @{ org = $Org; cursor = $cursor }
    $result = Invoke-GitHubGraphQL -Query $memberQuery -Variables $vars

    foreach ($m in $result.data.organization.membersWithRole.nodes) {
        $members[$m.login] = $m.role
    }

    $cursor = $result.data.organization.membersWithRole.pageInfo.endCursor
} while ($result.data.organization.membersWithRole.pageInfo.hasNextPage)

# Step 2: Get repositories
Write-Host "Fetching repositories..."
$repos = @()
$cursor = $null

do {
    $repoQuery = @"
query Repos(\$org: String!, \$cursor: String) {
  organization(login: \$org) {
    repositories(first: 100, after: \$cursor) {
      nodes {
        name
      }
      pageInfo {
        hasNextPage
        endCursor
      }
    }
  }
}
"@

    $vars = @{ org = $Org; cursor = $cursor }
    $result = Invoke-GitHubGraphQL -Query $repoQuery -Variables $vars
    $repos += $result.data.organization.repositories.nodes
    $cursor = $result.data.organization.repositories.pageInfo.endCursor
} while ($result.data.organization.repositories.pageInfo.hasNextPage)

# Step 3: Process collaborators
$report = @()

foreach ($repo in $repos) {
    Write-Host "🔍 $($repo.name)" -ForegroundColor Green
    $cursor = $null

    do {
        $collabQuery = @"
query Collaborators(\$org: String!, \$repo: String!, \$cursor: String) {
  repository(owner: \$org, name: \$repo) {
    collaborators(first: 100, after: \$cursor) {
      nodes {
        login
        permission
      }
      pageInfo {
        hasNextPage
        endCursor
      }
    }
  }
}
"@

        $vars = @{ org = $Org; repo = $repo.name; cursor = $cursor }
        $result = Invoke-GitHubGraphQL -Query $collabQuery -Variables $vars
        $collaborators = $result.data.repository.collaborators.nodes

        foreach ($c in $collaborators) {
            $affil = if ($members.ContainsKey($c.login)) {
                if ($members[$c.login] -eq "ADMIN") { "Owner" } else { "Member" }
            } else {
                "Outside"
            }

            $report += [pscustomobject]@{
                Repository  = $repo.name
                Username    = $c.login
                Permission  = $c.permission
                Affiliation = $affil
            }
        }

        $cursor = $result.data.repository.collaborators.pageInfo.endCursor
    } while ($result.data.repository.collaborators.pageInfo.hasNextPage)
}

# Step 4: Export
$csvPath = "./github-collaborator-affiliation-report.csv"
$report | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8
Write-Host "✅ Report saved to $csvPath"
