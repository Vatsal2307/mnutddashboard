param($Timer)

# ── API credentials & team IDs ──────────────────────────────────────────────
$apiKey          = $env:API_FOOTBALL_KEY     # football-data.org
$apiSportsKey    = $env:API_SPORTS_KEY       # api-sports.io
$teamId          = 66                        # Man United in football-data.org
$apiSportsTeamId = 33                        # Man United in API-Sports

$fdHeaders = @{ "X-Auth-Token"    = $apiKey }
$asHeaders = @{ "x-apisports-key" = $apiSportsKey }

Write-Output "Starting Manchester United Dashboard Aggregator..."

# Current football season (seasons start in August)
$season   = (Get-Date).Year
if ((Get-Date).Month -lt 7) { $season = $season - 1 }
$dateFrom = (Get-Date -Format "yyyy-MM-dd")

# ── 1. Upcoming domestic fixtures (football-data.org) ───────────────────────
$matchesResponse = $null
try {
    $upcomingUri     = "https://api.football-data.org/v4/teams/$teamId/matches?season=$season&dateFrom=$dateFrom&status=SCHEDULED,TIMED"
    $matchesResponse = Invoke-RestMethod -Uri $upcomingUri -Headers $fdHeaders -Method Get -TimeoutSec 15
    Write-Output "Upcoming matches: $($matchesResponse.matches.Count)"
}
catch {
    Write-Error "Upcoming matches request failed: $_"
    return
}

# ── 2. Last finished match + goal events (football-data.org) ────────────────
$lastMatch       = $null
$lastOpponent    = "N/A"
$lastScore       = "N/A"
$lastMatchDate   = ""
$lastCompetition = ""
$lastGoalsJson   = "[]"

try {
    $finishedUri         = "https://api.football-data.org/v4/teams/$teamId/matches?season=$season&status=FINISHED"
    $finishedResponse    = Invoke-RestMethod -Uri $finishedUri -Headers $fdHeaders -Method Get -TimeoutSec 15
    $lastMatch           = $finishedResponse.matches | Sort-Object { [datetime]$_.utcDate } -Descending | Select-Object -First 1
    Write-Output "Last finished match found: $($lastMatch.id)"
}
catch {
    Write-Warning "Could not fetch finished matches: $_"
}

if ($lastMatch) {
    $lastIsHome      = ($lastMatch.homeTeam.id -eq $teamId)
    $lastOpponent    = if ($lastIsHome) { $lastMatch.awayTeam.name } else { $lastMatch.homeTeam.name }
    $muScore         = if ($lastIsHome) { $lastMatch.score.fullTime.home  } else { $lastMatch.score.fullTime.away }
    $oppScore        = if ($lastIsHome) { $lastMatch.score.fullTime.away  } else { $lastMatch.score.fullTime.home }
    $lastScore       = "$muScore-$oppScore"
    $lastMatchDate   = $lastMatch.utcDate
    $lastCompetition = $lastMatch.competition.name

    # Fetch individual goal events for the match
    try {
        $detailUri   = "https://api.football-data.org/v4/matches/$($lastMatch.id)"
        $matchDetail = Invoke-RestMethod -Uri $detailUri -Headers $fdHeaders -Method Get -TimeoutSec 15
        if ($matchDetail.goals) {
            $goalEvents  = $matchDetail.goals | ForEach-Object {
                @{
                    scorer = $_.scorer.name
                    minute = [int]($_.minute ?? 0)
                    isMU   = ($_.team.id -eq $teamId)
                    isOG   = ($_.type -eq "OWN_GOAL")
                }
            }
            $lastGoalsJson = $goalEvents | ConvertTo-Json -Compress
            Write-Output "Goal events fetched: $($matchDetail.goals.Count)"
        }
    }
    catch {
        Write-Warning "Could not fetch goal events: $_"
    }
}

# ── 3. PL top scorers (football-data.org) ───────────────────────────────────
$scorersResponse = $null
try {
    $scorersUri      = "https://api.football-data.org/v4/competitions/PL/scorers?limit=100"
    $scorersResponse = Invoke-RestMethod -Uri $scorersUri -Headers $fdHeaders -Method Get -TimeoutSec 15
    Write-Output "Scorers payload received."
}
catch {
    Write-Warning "Scorers fetch failed: $_"
}

# ── 4. UCL + UEL upcoming fixtures (API-Sports) ──────────────────────────────
$europeanFixtures    = @()
$nextMatchIsEuropean = $false
$nextEuropeanFixture = $null

if ($apiSportsKey) {
    $leagueMap = @{ 2 = "UEFA Champions League"; 3 = "UEFA Europa League" }
    foreach ($leagueId in @(2, 3)) {
        try {
            $euUri      = "https://v3.football.api-sports.io/fixtures?team=$apiSportsTeamId&season=$season&league=$leagueId&next=15"
            $euResponse = Invoke-RestMethod -Uri $euUri -Headers $asHeaders -Method Get -TimeoutSec 15
            if ($euResponse.response) {
                foreach ($fix in $euResponse.response) {
                    $isHome            = ($fix.teams.home.id -eq $apiSportsTeamId)
                    $europeanFixtures += @{
                        date        = $fix.fixture.date
                        status      = "SCHEDULED"
                        opponent    = if ($isHome) { $fix.teams.away.name } else { $fix.teams.home.name }
                        competition = $leagueMap[$leagueId]
                        isHome      = $isHome
                    }
                }
                Write-Output "$($leagueMap[$leagueId]): $($euResponse.response.Count) fixtures"
            }
        }
        catch {
            Write-Warning "API-Sports league $leagueId failed: $_"
        }
    }
}

# ── 5. Determine the true next match (domestic vs European) ──────────────────
$nextMatch    = $null
$isNextHome   = $true
$nextOpponent = "TBD"
$nextDate     = (Get-Date).ToString("o")
$nextComp     = ""
$venueName    = "Old Trafford"

# Earliest domestic upcoming
$domesticNext = $null
if ($matchesResponse.matches -and $matchesResponse.matches.Count -gt 0) {
    $domesticNext = $matchesResponse.matches | Sort-Object { [datetime]$_.utcDate } | Select-Object -First 1
}

# Earliest European upcoming
$europeanNext = $null
if ($europeanFixtures.Count -gt 0) {
    $europeanNext = $europeanFixtures | Sort-Object { [datetime]$_.date } | Select-Object -First 1
}

# Pick whichever is sooner
if ($domesticNext -and $europeanNext) {
    if ([datetime]$europeanNext.date -lt [datetime]$domesticNext.utcDate) {
        $nextMatchIsEuropean = $true
    }
    else {
        $nextMatch = $domesticNext
    }
}
elseif ($domesticNext) {
    $nextMatch = $domesticNext
}
elseif ($europeanNext) {
    $nextMatchIsEuropean = $true
}

if ($nextMatchIsEuropean -and $europeanNext) {
    $isNextHome   = $europeanNext.isHome
    $nextOpponent = $europeanNext.opponent
    $nextDate     = $europeanNext.date
    $nextComp     = $europeanNext.competition
    $venueName    = if ($isNextHome) { "Old Trafford" } else { "Away Stadium" }
}
elseif ($nextMatch) {
    $isNextHome   = ($nextMatch.homeTeam.id -eq $teamId)
    $nextOpponent = if ($isNextHome) { $nextMatch.awayTeam.name } else { $nextMatch.homeTeam.name }
    $nextDate     = $nextMatch.utcDate
    $nextComp     = $nextMatch.competition.name
    if ($isNextHome) {
        $venueName = "Old Trafford"
    }
    else {
        try {
            $awayTeamResponse = Invoke-RestMethod -Uri "https://api.football-data.org/v4/teams/$($nextMatch.homeTeam.id)" -Headers $fdHeaders -Method Get -TimeoutSec 15
            if ($awayTeamResponse.venue) { $venueName = $awayTeamResponse.venue }
            Write-Output "Away venue: $venueName"
        }
        catch { Write-Warning "Could not fetch away venue: $_" }
    }
}

# ── 6. Merge & sort all fixtures ─────────────────────────────────────────────
$allFixturesList = @()
if ($matchesResponse.matches) {
    foreach ($m in $matchesResponse.matches) {
        $isHome           = ($m.homeTeam.id -eq $teamId)
        $allFixturesList += @{
            date        = $m.utcDate
            status      = $m.status
            opponent    = if ($isHome) { $m.awayTeam.name } else { $m.homeTeam.name }
            competition = $m.competition.name
            isHome      = $isHome
        }
    }
}
$allFixturesList += $europeanFixtures
$fixturesJson = if ($allFixturesList.Count -gt 0) {
    ($allFixturesList | Sort-Object { [datetime]$_.date } | ConvertTo-Json -Compress)
} else { "[]" }

# ── 7. Player statistics ──────────────────────────────────────────────────────
$top5Scorers = @()
$top5Assists = @()
if ($scorersResponse -and $scorersResponse.scorers) {
    $muPlayers = $scorersResponse.scorers | Where-Object { $_.team.id -eq $teamId }
    if ($muPlayers) {
        $top5Scorers = $muPlayers | Sort-Object { [int]($_.goals   ?? 0) } -Descending | Select-Object -First 5 | ForEach-Object { @{ name = $_.player.name; count = [int]($_.goals ?? 0) } }
        $top5Assists = $muPlayers | Where-Object { $_.assists -ne $null } | Sort-Object { [int]$_.assists } -Descending | Select-Object -First 5 | ForEach-Object { @{ name = $_.player.name; count = [int]$_.assists } }
    }
}

# ── 8. Assemble row and push to Azure Table ───────────────────────────────────
$matchData = @{
    PartitionKey     = "NextMatch"
    RowKey           = "CurrentDashboardState"
    Opponent         = $nextOpponent
    MatchDate        = $nextDate
    Competition      = $nextComp
    IsHome           = $isNextHome.ToString()
    Venue            = $venueName
    LastOpponent     = $lastOpponent
    LastScore        = $lastScore
    LastMatchDate    = $lastMatchDate
    LastCompetition  = $lastCompetition
    LastGoalsJSON    = $lastGoalsJson
    TopScorersJSON   = if ($top5Scorers.Count -gt 0) { $top5Scorers | ConvertTo-Json -Compress } else { "[]" }
    TopAssistsJSON   = if ($top5Assists.Count -gt 0) { $top5Assists | ConvertTo-Json -Compress } else { "[]" }
    AllFixturesJSON  = $fixturesJson
}

Push-OutputBinding -Name tableOutput -Value $matchData
Write-Output "Dashboard data pushed to Azure Storage Table successfully."