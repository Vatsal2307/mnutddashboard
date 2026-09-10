param($Timer)

# Configuring API parameters
$apiKey = $env:API_FOOTBALL_KEY
$teamId = 66 

$headers = @{
    "X-Auth-Token" = $apiKey
}

Write-Output "Starting Manchester United Dashboard Aggregator (Syntax Fix)..."

# Determine current football season (seasons start in Aug, e.g. 2025 = 2025/26)
$season = (Get-Date).Year
if ((Get-Date).Month -lt 7) { $season = $season - 1 }
$dateFrom = (Get-Date -Format "yyyy-MM-dd")

# Fetching only current-season upcoming matches (pre-filtered by API)
$matchesUri = "https://api.football-data.org/v4/teams/$teamId/matches?season=$season&dateFrom=$dateFrom&status=SCHEDULED,TIMED"
try {
    $matchesResponse = Invoke-RestMethod -Uri $matchesUri -Headers $headers -Method Get -TimeoutSec 15
    Write-Output "Matches payload received. Count: $($matchesResponse.matches.Count)"
}
catch {
    Write-Error "HTTP Request Failed (Matches): $_"
    return
}

# Fetching top scorers
$scorersUri = "https://api.football-data.org/v4/competitions/PL/scorers?limit=100"
$scorersResponse = $null
try {
    $scorersResponse = Invoke-RestMethod -Uri $scorersUri -Headers $headers -Method Get -TimeoutSec 15
    Write-Output "Scorers payload received."
}
catch {
    Write-Warning "Failed to fetch scorers (rate limit or API issue). Stats will default to N/A."
}

# Parsing the next upcoming match — API already filtered by dateFrom + status, so first result is correct
$nextMatch = $null
if ($matchesResponse.matches -and $matchesResponse.matches.Count -gt 0) {
    # Sort ascending by utcDate to ensure the earliest upcoming match is first
    $nextMatch = $matchesResponse.matches | Sort-Object { [datetime]$_.utcDate } | Select-Object -First 1
}

# Compressing all fixtures into a JSON string
$fixturesJson = "[]"
if ($matchesResponse.matches) {
    $minimalFixtures = foreach ($m in $matchesResponse.matches) {
        $isHome = ($m.homeTeam.id -eq $teamId)
        @{
            date        = $m.utcDate
            status      = $m.status
            opponent    = if ($isHome) { $m.awayTeam.name } else { $m.homeTeam.name }
            competition = $m.competition.name
            isHome      = $isHome
        }
    }
    $fixturesJson = $minimalFixtures | ConvertTo-Json -Compress
}

# Extracting Manchester United player statistics
$top5Scorers = @()
$top5Assists = @()

if ($scorersResponse -and $scorersResponse.scorers) {
    $muPlayers = $scorersResponse.scorers | Where-Object { $_.team.id -eq $teamId }
    if ($muPlayers) {
        $top5Scorers = $muPlayers | Sort-Object { [int]($_.goals ?? 0) } -Descending | Select-Object -First 5 | ForEach-Object { @{ name = $_.player.name; count = [int]($_.goals ?? 0) } }
        # Assists can be null in the API response — guard against null before sorting
        $top5Assists = $muPlayers | Where-Object { $_.assists -ne $null } | Sort-Object { [int]$_.assists } -Descending | Select-Object -First 5 | ForEach-Object { @{ name = $_.player.name; count = [int]$_.assists } }
    }
}

# Standard PowerShell logic for venue name
$isNextHome = $true
if ($nextMatch) { $isNextHome = ($nextMatch.homeTeam.id -eq $teamId) }

$venueName = "Away Stadium"
if ($isNextHome) {
    $venueName = "Old Trafford"
}
elseif ($nextMatch) {
    # MU is the away team — fetch the HOME team's (opponent's) venue
    $awayTeamId = $nextMatch.homeTeam.id
    try {
        $awayTeamUri = "https://api.football-data.org/v4/teams/$awayTeamId"
        $awayTeamResponse = Invoke-RestMethod -Uri $awayTeamUri -Headers $headers -Method Get -TimeoutSec 15
        if ($awayTeamResponse.venue) {
            $venueName = $awayTeamResponse.venue
        }
        Write-Output "Away venue resolved: $venueName"
    }
    catch {
        Write-Warning "Could not fetch away team venue: $_"
        # Falls back to "Away Stadium" already set above
    }
}

# Final Data Assembly
$matchData = @{
    PartitionKey    = "NextMatch"
    RowKey          = "CurrentDashboardState"
    Opponent        = if ($nextMatch) { if ($isNextHome) { $nextMatch.awayTeam.name } else { $nextMatch.homeTeam.name } } else { "TBD" }
    MatchDate       = if ($nextMatch) { $nextMatch.utcDate } else { (Get-Date).ToString("o") }
    Competition     = if ($nextMatch) { $nextMatch.competition.name } else { "" }
    IsHome          = $isNextHome.ToString()
    Venue           = $venueName
    TopScorersJSON  = $top5Scorers | ConvertTo-Json -Compress
    TopAssistsJSON  = $top5Assists | ConvertTo-Json -Compress
    AllFixturesJSON = $fixturesJson
}

Push-OutputBinding -Name tableOutput -Value $matchData
Write-Output "Aggregated Dashboard Data successfully pushed to Azure Storage Table."