param($Timer)

$apiKey = $env:API_FOOTBALL_KEY
$teamId = 33

$headers = @{
    "x-apisports-key" = $apiKey
}

Write-Output "Starting Manchester United Matchday fetcher..."

$uri = "https://v3.football.api-sports.io/fixtures?team=$teamId&next=1"
try {
    $response = Invoke-RestMethod -Uri $uri -Headers $headers -Method Get -TimeoutSec 15
    Write-Output "API payload received. Checking for internal errors..."
    
    # Force the logs to show if the API rejected our key silently
    if ($response.errors) {
        Write-Warning "API-Sports Error: $($response.errors | ConvertTo-Json -Compress)"
    }
}
catch {
    Write-Error "HTTP Request Failed: $_"
    return
}

# 1. Define a robust fallback record 
# This ensures the database is created and the frontend works even if the API is empty
$matchData = @{
    PartitionKey = "NextMatch"
    RowKey       = "1"
    FixtureId    = "000000"
    MatchDate    = (Get-Date).AddDays(7).ToString("o")
    Opponent     = "TBD (Off-season or API Check)"
    Venue        = "Old Trafford"
    Competition  = "Premier League"
    IsHomeMatch  = $true
    LastUpdated  = (Get-Date).ToString("o")
}

# 2. Overwrite fallback data ONLY if we got a valid fixture back
if ($response.response -and $response.response.Count -gt 0) {
    $fixture = $response.response[0]
    
    $opponent = if ($fixture.teams.away.name -eq "Manchester United") { $fixture.teams.home.name } else { $fixture.teams.away.name }
    $isHome = if ($fixture.teams.home.name -eq "Manchester United") { $true } else { $false }
    
    $matchData.FixtureId = $fixture.fixture.id.ToString()
    $matchData.MatchDate = $fixture.fixture.date
    $matchData.Opponent = $opponent
    $matchData.Venue = $fixture.fixture.venue.name
    $matchData.Competition = $fixture.league.name
    $matchData.IsHomeMatch = $isHome
    
    Write-Output "Successfully parsed real match vs $opponent"
}
else {
    Write-Warning "No live fixture data found. Pushing fallback data to ensure database and dashboard remain active."
}

# 3. Push to Table Storage (This will automatically create 'manutdfixtures' if missing)
Push-OutputBinding -Name tableOutput -Value $matchData
Write-Output "Data successfully pushed to Azure Storage Table."