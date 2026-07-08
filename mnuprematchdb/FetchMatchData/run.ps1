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
}
catch {
    Write-Error "Failed to reach API-Football: $_"
    return
}

if ($response.response -and $response.response.Count -gt 0) {
    $fixture = $response.response[0]
    
    $opponent = if ($fixture.teams.away.name -eq "Manchester United") { $fixture.teams.home.name } else { $fixture.teams.away.name }
    $isHome = if ($fixture.teams.home.name -eq "Manchester United") { $true } else { $false }
    
    $matchData = @{
        PartitionKey = "NextMatch"
        RowKey       = "1"
        FixtureId    = $fixture.fixture.id.ToString()
        MatchDate    = $fixture.fixture.date
        Opponent     = $opponent
        Venue        = $fixture.fixture.venue.name
        Competition  = $fixture.league.name
        IsHomeMatch  = $isHome
        LastUpdated  = (Get-Date).ToString("o")
    }

    # The output binding handles the table creation and insertion automatically
    Push-OutputBinding -Name tableOutput -Value $matchData
    Write-Output "Successfully updated Azure Storage Table with the latest match data."
}
else {
    Write-Warning "No upcoming fixtures found for Manchester United or API limit reached."
}