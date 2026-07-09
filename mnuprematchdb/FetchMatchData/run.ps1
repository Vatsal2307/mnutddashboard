param($Timer)

# API configuration
$apiKey = $env:API_FOOTBALL_KEY
$teamId = 66
$headers = @{ "X-Auth-Token" = $apiKey }

Write-Output "Starting Manchester United Dashboard Aggregator (Stats Upgrade)..."

# 1. Fetch Fixtures
$matchesUri = "https://api.football-data.org/v4/teams/$teamId/matches?status=SCHEDULED"
$matchesResponse = Invoke-RestMethod -Uri $matchesUri -Headers $headers -Method Get -TimeoutSec 15

# 2. Fetch Player Stats
$scorersUri = "https://api.football-data.org/v4/competitions/PL/scorers?limit=100"
$scorersResponse = Invoke-RestMethod -Uri $scorersUri -Headers $headers -Method Get -TimeoutSec 15

# 3. Process Next Match with dynamic Venue logic
$nextMatch = $matchesResponse.matches[0]
$isNextHome = ($nextMatch.homeTeam.id -eq $teamId)

# Capturing the actual venue name
$venueName = if ($isNextHome) { "Old Trafford" } else { $nextMatch.venue ?: "Away Stadium" }

# 4. Process Top 5 Stats
$muPlayers = $scorersResponse.scorers | Where-Object { $_.team.id -eq $teamId }

$top5Scorers = $muPlayers | Sort-Object goals -Descending | Select-Object -First 5 | ForEach-Object { 
    @{ name = $_.player.name; count = $_.goals } 
} | ConvertTo-Json -Compress

$top5Assists = $muPlayers | Sort-Object assists -Descending | Select-Object -First 5 | ForEach-Object { 
    @{ name = $_.player.name; count = $_.assists } 
} | ConvertTo-Json -Compress

# 5. Compress all fixtures for the table
$allFixtures = $matchesResponse.matches | ForEach-Object { 
    @{ date = $_.utcDate; opponent = $($_.awayTeam.name); isHome = ($_.homeTeam.id -eq $teamId) } 
} | ConvertTo-Json -Compress

# 6. Bundle Dashboard State
$matchData = @{
    PartitionKey    = "NextMatch"
    RowKey          = [string]([long]::MaxValue - (Get-Date).Ticks)
    Opponent        = if ($isNextHome) { $nextMatch.awayTeam.name } else { $nextMatch.homeTeam.name }
    MatchDate       = $nextMatch.utcDate
    Venue           = $venueName
    TopScorersJSON  = $top5Scorers
    TopAssistsJSON  = $top5Assists
    AllFixturesJSON = $allFixtures
}

Push-OutputBinding -Name tableOutput -Value $matchData