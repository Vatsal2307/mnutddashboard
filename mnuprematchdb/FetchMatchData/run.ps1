param($Timer)

$apiKey = $env:API_FOOTBALL_KEY
$teamId = 33

$headers = @{
    "x-apisports-key" = $apiKey
}

Write-Output "Starting Manchester United Matchday fetcher..."

# THE WORKAROUND: Instead of 'next=1', we ask for a date range (which is allowed on the Free Plan)
$today = (Get-Date).ToString("yyyy-MM-dd")
$future = (Get-Date).AddMonths(12).ToString("yyyy-MM-dd")
$uri = "https://v3.football.api-sports.io/fixtures?team=$teamId&from=$today&to=$future"

try {
    $response = Invoke-RestMethod -Uri $uri -Headers $headers -Method Get -TimeoutSec 15
    Write-Output "API payload received. Checking for internal errors..."
    
    if ($response.errors -and $response.errors.Count -gt 0) {
        Write-Warning "API-Sports Error: $($response.errors | ConvertTo-Json -Compress)"
    }
}
catch {
    Write-Error "HTTP Request Failed: $_"
    return
}

# 1. Define fallback record
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

# 2. Overwrite fallback data ONLY if we got valid fixtures back
if ($response.response -and $response.response.Count -gt 0) {
    # The API returns a list. We sort it chronologically and grab the very first one ([0])
    $upcomingFixtures = $response.response | Sort-Object -Property @{Expression = { $_.fixture.timestamp }; Ascending = $true }
    $fixture = $upcomingFixtures[0]
    
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
    Write-Warning "No live fixture data found in that date range. Pushing fallback data."
}

# 3. Push to Table Storage
Push-OutputBinding -Name tableOutput -Value $matchData
Write-Output "Data successfully pushed to Azure Storage Table."