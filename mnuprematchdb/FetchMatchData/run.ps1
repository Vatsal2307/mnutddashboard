# run.ps1
param($Timer)

# 1. Fetch Environment Settings
# These env variables will be safely stored in Azure Function App Settings later
$apiKey = $env:API_FOOTBALL_KEY
$storageConnectionString = $env:AzureWebJobsStorage
$tableName = "manutdfixtures"
$teamId = 33 # Manchester United official ID

$headers = @{
    "x-apisports-key" = $apiKey
}

Write-Output "Starting Manchester United Matchday fetcher..."

# 2. Query the External API for the next 1 upcoming fixture
$uri = "https://v3.football.api-sports.io/fixtures?team=$teamId&next=1"
try {
    $response = Invoke-RestMethod -Uri $uri -Headers $headers -Method Get -TimeoutSec 15
} catch {
    Write-Error "Failed to reach API-Football: $_"
    return
}

# 3. Process the Payload
if ($response.response -and $response.response.Count -gt 0) {
    $fixture = $response.response[0]
    
    # Check if United is Home or Away to correctly identify the opponent
    $opponent = if ($fixture.teams.away.name -eq "Manchester United") { $fixture.teams.home.name } else { $fixture.teams.away.name }
    $isHome = if ($fixture.teams.home.name -eq "Manchester United") { $true } else { $false }
    
    # 4. Construct the Azure Table Storage Entity object
    # PartitionKey and RowKey are required by Azure Tables for indexing
    $matchData = @{
        PartitionKey = "NextMatch"
        RowKey       = "1" # We overwrite RowKey 1 so we always store only the latest single record
        FixtureId    = $fixture.fixture.id.ToString()
        MatchDate    = $fixture.fixture.date
        Opponent     = $opponent
        Venue        = $fixture.fixture.venue.name
        Competition  = $fixture.league.name
        IsHomeMatch  = $isHome
        LastUpdated  = (Get-Date).ToString("o")
    }

    Write-Output "Successfully parsed match vs $opponent on $($fixture.fixture.date)"

    # 5. Write to Azure Table Storage using the Az.Storage module
    # The Azure Function environment pre-loads this module for us
    try {
        $ctx = New-AzStorageContext -ConnectionString $storageConnectionString
        $table = Get-AzStorageTable -Name $tableName -Context $ctx -ErrorAction SilentlyContinue
        
        # Create table if it doesn't exist yet
        if (-not $table) {
            $table = New-AzStorageTable -Name $tableName -Context $ctx
            Write-Output "Created new Azure Storage Table: $tableName"
        }
        
        # Save or update the record in the table
        Add-AzTableRow -Table $table -partitionKey $matchData.PartitionKey -rowKey $matchData.RowKey -property $matchData
        Write-Output "Successfully updated Azure Storage Table with the latest match data."
    } catch {
        Write-Error "Failed to write data to Azure Table Storage: $_"
    }
} else {
    Write-Warning "No upcoming fixtures found for Manchester United or API limit reached."
}