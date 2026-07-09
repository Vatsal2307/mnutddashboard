param($Timer)

# Configuring API parameters
$apiKey = $env:API_FOOTBALL_KEY
$teamId = 66 

$headers = @{
    "X-Auth-Token" = $apiKey
}

Write-Output "Starting Manchester United Dashboard Aggregator (Syntax Fix)..."

# Fetching all seasonal matches
$matchesUri = "https://api.football-data.org/v4/teams/$teamId/matches"
try {
    $matchesResponse = Invoke-RestMethod -Uri $matchesUri -Headers $headers -Method Get -TimeoutSec 15
    Write-Output "Matches payload received."
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

# Parsing the next upcoming match
$nextMatch = $null
if ($matchesResponse.matches -and $matchesResponse.matches.Count -gt 0) {
    $upcomingFixtures = $matchesResponse.matches | Where-Object { $_.status -in @("SCHEDULED", "TIMED") }
    if ($upcomingFixtures -and $upcomingFixtures.Count -gt 0) {
        $nextMatch = $upcomingFixtures[0]
    }
}

# Compressing all fixtures into a JSON string
$fixturesJson = "[]"
if ($matchesResponse.matches) {
    $minimalFixtures = foreach ($m in $matchesResponse.matches) {
        $isHome = ($m.homeTeam.id -eq $teamId)
        @{
            date     = $m.utcDate
            status   = $m.status
            opponent = if ($isHome) { $m.awayTeam.name } else { $m.homeTeam.name }
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
        $top5Scorers = $muPlayers | Sort-Object goals -Descending | Select-Object -First 5 | ForEach-Object { @{ name = $_.player.name; count = $_.goals } }
        $top5Assists = $muPlayers | Sort-Object assists -Descending | Select-Object -First 5 | ForEach-Object { @{ name = $_.player.name; count = $_.assists } }
    }
}

# Standard PowerShell logic for venue name
$isNextHome = $true
if ($nextMatch) { $isNextHome = ($nextMatch.homeTeam.id -eq $teamId) }

$venueName = "Away Stadium"
if ($isNextHome) {
    $venueName = "Old Trafford"
}
elseif ($nextMatch.venue) {
    $venueName = $nextMatch.venue
}

# Final Data Assembly
$matchData = @{
    PartitionKey    = "NextMatch"
    RowKey          = [string]([long]::MaxValue - (Get-Date).Ticks)
    Opponent        = if ($nextMatch) { if ($isNextHome) { $nextMatch.awayTeam.name } else { $nextMatch.homeTeam.name } } else { "TBD" }
    MatchDate       = if ($nextMatch) { $nextMatch.utcDate } else { (Get-Date).ToString("o") }
    Venue           = $venueName
    TopScorersJSON  = $top5Scorers | ConvertTo-Json -Compress
    TopAssistsJSON  = $top5Assists | ConvertTo-Json -Compress
    AllFixturesJSON = $fixturesJson
}

Push-OutputBinding -Name tableOutput -Value $matchData
Write-Output "Aggregated Dashboard Data successfully pushed to Azure Storage Table."