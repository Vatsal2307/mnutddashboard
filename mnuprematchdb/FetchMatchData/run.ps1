param($Timer)

# Grabbing the new Football-Data.org API Key
$apiKey = $env:API_FOOTBALL_KEY 

# Manchester United's ID on Football-Data.org is 66
$teamId = 66

# Football-Data uses a different header name for auth
$headers = @{
    "X-Auth-Token" = $apiKey
}

Write-Output "Starting Manchester United Matchday fetcher (using Football-Data.org)..."

# This API has a brilliant 'status=SCHEDULED' filter, so we don't even need dates!
$uri = "https://api.football-data.org/v4/teams/$teamId/matches?status=SCHEDULED"

try {
    $response = Invoke-RestMethod -Uri $uri -Headers $headers -Method Get -TimeoutSec 15
    Write-Output "API payload received."
}
catch {
    Write-Error "HTTP Request Failed: $_"
    return
}

# 1. Define fallback record
$matchData = @{
    PartitionKey = "NextMatch"
    RowKey       = [string]([long]::MaxValue - (Get-Date).Ticks) 
    FixtureId    = "000000"
    MatchDate    = (Get-Date).AddDays(7).ToString("o")
    Opponent     = "TBD (No upcoming matches scheduled)"
    Venue        = "TBD"
    Competition  = "Premier League"
    IsHomeMatch  = $true
    LastUpdated  = (Get-Date).ToString("o")
}

# 2. Overwrite fallback data ONLY if we got valid scheduled matches back
if ($response.matches -and $response.matches.Count -gt 0) {
    # The API returns them in chronological order, so [0] is the very next match
    $fixture = $response.matches[0]
    
    $isHome = if ($fixture.homeTeam.name -match "Manchester United") { $true } else { $false }
    $opponent = if ($isHome) { $fixture.awayTeam.name } else { $fixture.homeTeam.name }
    
    $matchData.FixtureId = $fixture.id.ToString()
    $matchData.MatchDate = $fixture.utcDate
    $matchData.Opponent = $opponent
    # This API doesn't always list the stadium, so we infer it based on Home/Away
    $matchData.Venue = if ($isHome) { "Old Trafford" } else { "Away Stadium" } 
    $matchData.Competition = $fixture.competition.name
    $matchData.IsHomeMatch = $isHome
    
    Write-Output "Successfully parsed real upcoming match vs $opponent"
}
else {
    Write-Warning "No scheduled matches found. Pushing fallback data."
}

# 3. Push to Table Storage
Push-OutputBinding -Name tableOutput -Value $matchData
Write-Output "Data successfully pushed to Azure Storage Table."