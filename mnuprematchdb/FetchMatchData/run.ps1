param($Timer)

# ── Azure Table upsert via pre-generated SAS token (no HMAC signing needed) ───
function Invoke-TableUpsert {
    param([string]$TableName, [hashtable]$Entity)

    $sas = $env:STORAGE_TABLE_SAS
    if (-not $sas) { throw "STORAGE_TABLE_SAS app setting is not set" }

    $connStr = $env:AzureWebJobsStorage
    if ($connStr -match 'AccountName=([^;]+)') { $accountName = $matches[1] } else { throw "No AccountName in connection string" }

    $pk   = $Entity['PartitionKey']
    $rk   = $Entity['RowKey']

    # InsertOrMerge entity URL with SAS token — no Authorization header needed
    $url  = "https://$accountName.table.core.windows.net/$TableName(PartitionKey='$pk',RowKey='$rk')?$sas"

    $headers = @{
        'x-ms-version' = '2019-02-02'
        'Accept'       = 'application/json;odata=nometadata'
    }

    # MERGE without If-Match = InsertOrMerge (true upsert)
    $body = $Entity | ConvertTo-Json -Compress -Depth 5
    Invoke-RestMethod -Uri $url -Method MERGE -Headers $headers -Body $body -ContentType 'application/json'
    Write-Output "Table entity upserted via SAS: $pk / $rk"
}

# ── API credentials & team IDs ──────────────────────────────────────────────
$apiKey          = $env:API_FOOTBALL_KEY
$apiSportsKey    = $env:API_SPORTS_KEY
$teamId          = 66
$apiSportsTeamId = 33

$fdHeaders = @{ "X-Auth-Token"    = $apiKey }
$asHeaders = @{ "x-apisports-key" = $apiSportsKey }

Write-Output "Starting Manchester United Dashboard Aggregator..."

# Current football season (seasons start in August)
$season   = (Get-Date).Year
if ((Get-Date).Month -lt 7) { $season = $season - 1 }
$dateFrom = (Get-Date -Format "yyyy-MM-dd")

# ── 1. All domestic fixtures for the season (football-data.org) ─────────────
# NOTE: dateFrom requires dateTo - use no date filter and split in code instead
$matchesResponse = $null
try {
    $allMatchesUri   = "https://api.football-data.org/v4/teams/$teamId/matches?season=$season"
    $matchesResponse = Invoke-RestMethod -Uri $allMatchesUri -Headers $fdHeaders -Method Get -TimeoutSec 15
    Write-Output "Season matches fetched: $($matchesResponse.matches.Count)"
}
catch {
    Write-Error "Matches request failed: $_"
    return
}

# ── 2. Last finished match + goal events ────────────────────────────────────
$lastMatch       = $null
$lastOpponent    = "N/A"
$lastScore       = "N/A"
$lastMatchDate   = ""
$lastCompetition = ""
$lastGoalsJson   = "[]"

$lastMatch = $matchesResponse.matches |
    Where-Object { $_.status -eq "FINISHED" } |
    Sort-Object { [datetime]$_.utcDate } -Descending |
    Select-Object -First 1
if ($lastMatch) { Write-Output "Last finished match: $($lastMatch.id) vs $($lastMatch.awayTeam.name)" }

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

# Earliest domestic upcoming (utcDate >= today)
$nowUtc = (Get-Date).ToUniversalTime()
$domesticNext = $null
if ($matchesResponse.matches -and $matchesResponse.matches.Count -gt 0) {
    $domesticNext = $matchesResponse.matches |
        Where-Object { [datetime]$_.utcDate -ge $nowUtc } |
        Sort-Object { [datetime]$_.utcDate } |
        Select-Object -First 1
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

# Write directly via REST (InsertOrMerge upsert — bypasses broken output binding)
try {
    Invoke-TableUpsert -TableName "manutdfixtures" -Entity $matchData
    Write-Output "Dashboard data upserted to Azure Storage Table successfully."
}
catch {
    Write-Error "Table upsert failed: $_"
}