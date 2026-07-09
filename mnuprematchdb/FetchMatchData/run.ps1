param($Timer)

# Configuring API parameters
$apiKey = $env:API_FOOTBALL_KEY
$teamId = 66 # Manchester United's ID on Football-Data.org

$headers = @{
    "X-Auth-Token" = $apiKey
}

Write-Output "Starting Manchester United Dashboard Aggregator..."

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

# Fetching top scorers for the league
$scorersUri = "https://api.football-data.org/v4/competitions/PL/scorers?limit=100"
$scorersResponse = $null
try {
    $scorersResponse = Invoke-RestMethod -Uri $scorersUri -Headers $headers -Method Get -TimeoutSec 15
    Write-Output "Scorers payload received."
}
catch {
    Write-Warning "Failed to fetch scorers (rate limit or API issue). Stats will default to N/A. Error: $_"
}

# Parsing the next upcoming match
$nextMatch = $null
if ($matchesResponse.matches -and $matchesResponse.matches.Count -gt 0) {
    # Find the very first match that is SCHEDULED or TIMED
    $upcomingFixtures = $matchesResponse.matches | Where-Object { $_.status -in @("SCHEDULED", "TIMED") }
    if ($upcomingFixtures -and $upcomingFixtures.Count -gt 0) {
        $nextMatch = $upcomingFixtures[0]
    }
}

# Compressing all fixtures into a JSON string
$fixturesJson = "[]"
if ($matchesResponse.matches) {
    # We strip out unnecessary heavy data and keep only what the dashboard table needs
    $minimalFixtures = foreach ($m in $matchesResponse.matches) {
        $isHome = ($m.homeTeam.id -eq $teamId)
        @{
            id          = $m.id
            date        = $m.utcDate
            status      = $m.status
            opponent    = if ($isHome) { $m.awayTeam.name } else { $m.homeTeam.name }
            isHome      = $isHome
            scoreHome   = $m.score.fullTime.home
            scoreAway   = $m.score.fullTime.away
            competition = $m.competition.name
        }
    }
    # Compress into a single string (Azure Table columns can hold 64KB, this will be ~5KB)
    $fixturesJson = $minimalFixtures | ConvertTo-Json -Compress
}

# Extracting Manchester United player statistics
$topScorerName = "N/A"
$topScorerGoals = 0
$topAssistName = "N/A"
$topAssistCount = 0

if ($scorersResponse -and $scorersResponse.scorers) {
    # Filter the Premier League top 100 to ONLY show Manchester United players
    $muPlayers = $scorersResponse.scorers | Where-Object { $_.team.id -eq $teamId }

    if ($muPlayers -and $muPlayers.Count -gt 0) {
        # Sort by goals and grab the highest
        $topScorer = $muPlayers | Sort-Object -Property goals -Descending | Select-Object -First 1
        if ($topScorer) {
            $topScorerName = $topScorer.player.name
            $topScorerGoals = $topScorer.goals
        }
        
        # Sort by assists and grab the highest
        $topAssister = $muPlayers | Sort-Object -Property assists -Descending | Select-Object -First 1
        if ($topAssister -and $topAssister.assists -gt 0) {
            $topAssistName = $topAssister.player.name
            $topAssistCount = $topAssister.assists
        }
    }
}

# Building the final dashboard entity
# Determine Next Match specific variables
$isNextHome = if ($nextMatch) { $nextMatch.homeTeam.id -eq $teamId } else { $true }
$nextOpponent = if ($nextMatch) { if ($isNextHome) { $nextMatch.awayTeam.name } else { $nextMatch.homeTeam.name } } else { "TBD (No upcoming matches)" }
$nextVenue = if ($nextMatch) { if ($isNextHome) { "Old Trafford" } else { "Away Stadium" } } else { "TBD" }
$nextDate = if ($nextMatch) { $nextMatch.utcDate } else { (Get-Date).AddDays(7).ToString("o") }
$nextComp = if ($nextMatch) { $nextMatch.competition.name } else { "Premier League" }

$matchData = @{
    PartitionKey    = "NextMatch"
    RowKey          = [string]([long]::MaxValue - (Get-Date).Ticks)
    
    # Next Match Highlight Card
    Opponent        = $nextOpponent
    MatchDate       = $nextDate
    Venue           = $nextVenue
    Competition     = $nextComp
    IsHomeMatch     = $isNextHome
    
    # Stats Cards
    TopScorerName   = $topScorerName
    TopScorerGoals  = $topScorerGoals
    TopAssistName   = $topAssistName
    TopAssistCount  = $topAssistCount
    
    # Season Table Array
    AllFixturesJSON = $fixturesJson
    
    LastUpdated     = (Get-Date).ToString("o")
}

# Pushing data to Azure Table Storage
Push-OutputBinding -Name tableOutput -Value $matchData
Write-Output "Aggregated Dashboard Data successfully pushed to Azure Storage Table."