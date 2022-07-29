# Script start parameter
param (
    [Parameter(Mandatory = $False)] $ConfigPath
)

function ExitHelper {
    if ($ConfigPath) {
        exit -1
    }

    Read-Host -Prompt "Press Enter to exit"
    exit -1
}

#-------------------------------------------
#----------- Global Variables --------------
#-------------------------------------------
#
# Version of this template.
# Version is part of the  HTTP Header-Attributes "User-Agent" and is sent with every request.
[String] $version = "1.0.0"


# Constructed User-agent value
[String] $userAgent = If ($Configuration.scriptName -eq "") { "dvelop-bo-toolkit_script/" + $version } Else { "dvelop-bo-toolkit_script_" + $Configuration.scriptName + "/" + $version }


# Script Config
$Configuration = New-Object -TypeName ScriptConfiguration

[STRING] $scriptConfigFilePath = "$PSScriptRoot\ScriptConfig.json" # Default value
[STRING] $configBasePath = $PSScriptRoot # Default value
if ($ConfigPath) {
    $scriptConfigFilePath = $ConfigPath
    $configBasePath = Split-Path -Path $scriptConfigFilePath
}

if (!(Test-Path $scriptConfigFilePath)) {
    Write-Host "Error while trying to initialize Configuration from ScriptConfig.json. Path $scriptConfigFilePath not found!"
    ExitHelper
}

$scriptConfigJson = Get-Content -Raw -Path $scriptConfigFilePath
try {
    # The implementation for parsing the config json is different in PS Version 5 and lower compared to that in PS version 5 and higher,
    # because the used library types are not present in all PS versions.
    if ($PSVersionTable.PSVersion.Major -gt 5) {
        # Using the .net json serializer and not 'ConvertFrom-Json' to enforce typing.
        # 'ConvertFrom-Json' does not enforce typing, but:
        # - parses boolean type based on truthy and falsy
        # - numbers, booleans are parsed as a string without an error
        # - ...
        $Configuration = [System.Text.Json.JsonSerializer]::Deserialize([STRING] $scriptConfigJson, [ScriptConfiguration])
    }
    else {
        [System.Reflection.Assembly]::LoadWithPartialName("System.Web.Extensions")
        $serializer = [System.Web.Script.Serialization.JavaScriptSerializer]::new()
        $Configuration = $serializer.Deserialize($scriptConfigJson, [ScriptConfiguration])
    }
}
catch {
    Write-Host "Could not parse json config file. Additional information: '$_'."
    ExitHelper
}

[System.Uri] $global:parsedBaseUri = ""

# Request-Rate-Limits related variables

$global:ReadLimits = New-Object -TypeName Limits
$global:ReadLimits.type = "read"

$global:WriteLimits = New-Object -TypeName Limits
$global:WriteLimits.type = "write"

[scriptblock] $global:MappingCode = $null;

#
#--------------------------------------------
#----------- Global Variables ---------------
#--------------------------------------------

#--------------------------------------------
#----------- Script Functions ---------------
#--------------------------------------------

function Main {
    CheckConfig($Configuration)
    $modelName = $Configuration.modelName + $(if ($Configuration.modelIsStaged) { "-staged" } else { "" })
    $businessobjectsUri = $global:parsedBaseUri.ToString() + "businessobjects/custom/" + $modelName + "/" + $Configuration.entityPluralName

    $authSessionID = IdpAuth
    if ($authSessionID -ne "") {
        if ($Configuration.dbType -eq "Oracle") {
            # Connection to Oracle DB
            # Library is deprecated https://docs.microsoft.com/en-us/dotnet/api/system.data.oracleclient?view=dotnet-plat-ext-6.0
            # Replace with the ODP.NET library in the future
            add-type -AssemblyName System.Data.OracleClient
            $connection = ConnectToOracleDB
        }
        elseif ($Configuration.dbType -eq "MSSQL") {
            # Connection to MSSQL DB
            $connection = ConnectToMSSQLDB
        }

        if (($connection.State -eq "Open") -or ($Configuration.DBType -eq "CSV")) {
            # Execute DB query
            if ($connection.State -eq "Open") {
                $dbEntityArray = ExecuteQuery -connection $connection -query $Configuration.query
            }
            elseif ($Configuration.DBType -eq "CSV") {
                $dbEntityArray = ReadCSVFile
            }

            if ($dbEntityArray.count -gt 0) {
                # For every row of the data source
                foreach ($row in $dbEntityArray) {
                    # Check if entity exists in business objects
                    $response = CheckIfEntityExists -authSessionID $authSessionID -key $row.($Configuration.entityKey)
                    if ($response) {
                        # If so -> update entity
                        Write-Log -level 3 -logtext ("Updating business objects entity: " + $row.($Configuration.entityKey))
                        $response = UpdateEntity -authSessionID $authSessionID -body $row -key $row.($Configuration.entityKey)
                    }
                    elseif (!$response) {
                        # If not -> create entity
                        Write-Log -level 3 -logtext ("Creating new business objects entity: " + $row)
                        $response = CreateEntity -authSessionID $authSessionID -body $row
                    }
                }

                # Delete entities that do not exist in the data source but in business objects
                if ($Configuration.deleteNonExistingEntities) {
                    Write-Log -level 3 -logtext ("Deleting non existing entities in business objects ...")

                    DeleteNonExistingEntities(GetEntities($authSessionID, $null))
                }

            }
            else {
                Write-Log -level 2 -logtext ("DBQuery returned no entities. Please check the DBQuery.")
            }
        }

        if ($connection.State -eq "Open") {
            Write-Log -level 3 -logtext ("Closing database connection.")
            $connection.close()
            Write-Log -level 3 -logtext ("Database connection was closed successfully.")
        }
    }
}

#--------------
#IDP Authentication
function IdpAuth {
    Write-Log -level 3 -logtext ("Starting IdpAuth")
    try {
        $headers = New-Object "System.Collections.Generic.Dictionary[[String],[String]]"
        $headers.Add("Authorization", "Bearer " + $Configuration.apiKey)
        $headers.Add("Origin", $global:parsedBaseUri.Scheme + "://" + $global:parsedBaseUri.Host)
        $headers.Add("Accept", "application/hal+json")
        $headers.Add("Content-Type", "application/hal+json")

        $url = $global:parsedBaseUri.ToString() + "identityprovider/login"
        $url = [uri]::EscapeUriString($url)

        Write-Log -level 3 -logtext ("URL: $url")

        $response = Invoke-RestMethod $url -Method Get -Headers $headers -UserAgent $userAgent
        $token = $response.AuthSessionId

        return $token
    }
    catch {
        Write-Log -level 2 -logtext ("IDP Login failed: " + $_ + " Please check credentials.")
        ExitHelper
    }
}

#--------------
function DeleteNonExistingEntities($entities) {
    # If "$entities" is "null": condition evaluates to false (no runtime error)
    if ($entities.value.count -gt 0) {
        foreach ($businessobjectsEntity in $entities.value) {
            #Resetting $existsInDB for each business objects entity
            $existsInDB = $false

            $dbEntityResult = $dbEntityArray | Where-Object $Configuration.entityKey -eq $businessobjectsEntity.($Configuration.entityKey) | Select-Object { $_.($Configuration.entityKey) }
            if ($null -ne $dbEntityResult) {
                Write-Log -level 3 -logtext ("Business Objects entity with key: " + $businessobjectsEntity.($Configuration.entityKey) + " exists in Database")
                $existsInDB = $true
            }

            if (!$existsInDB) {
                Write-Log -level 3 -logtext ("Entity should be deleted. Key: " + $businessobjectsEntity.($Configuration.entityKey))
                DeleteEntity -authSessionID $authSessionID -entityKeyType $Configuration.entityKeyType -key $businessobjectsEntity.($Configuration.entityKey)
            }
        }
        # All entities in current page processed
        if ($null -ne $entities."@odata.nextLink") {
            Write-Log -level 3 -logtext ("Page processed. 'nextLink' attribute present, start retrieving next page: " + $entities."@odata.nextLink")
            DeleteNonExistingEntities(GetEntities -authSessionID $authSessionID -nextLink $entities."@odata.nextLink")
        }
        else {
            # No more entities, processing finished
            Write-Log -level 3 -logtext ("Page processed. No 'nextLink' attribute present, all entities processed")
        }
    }
    else {
        Write-Log -level 1 -logtext ("GetEntities returned no business objects entities.")
        return
    }
}

#--------------
function CheckIfEntityExists([STRING] $authSessionID, $key) {
    Write-Log -level 3 -logtext ("Starting CheckIfEntityExists with key: $key")

    $headers = New-Object "System.Collections.Generic.Dictionary[[String],[String]]"
    $headers.Add("Authorization", "Bearer $authSessionID")
    $headers.Add("Origin", $global:parsedBaseUri.Scheme + "://" + $global:parsedBaseUri.Host)
    $headers.Add("Content-Type", "application/json")
    $headers.Add("Accept", "application/json")


    if ($Configuration.entityKeyType -eq "String") {
        $url = "$businessobjectsUri('$key')"
    }
    elseif ($Configuration.entityKeyType -in ("Guid", "Int32", "Int64")) {
        $url = "$businessobjectsUri($key)"
    }
    else {
        Write-Log -level 2 -logtext ("The Entitykeytype is not configured correctly!")
    }
    $url = [uri]::EscapeUriString($url)

    Write-Log -level 3 -logtext ("URL: $url")

    $response = BusinessObjectsRequestHandler $url -Method "GET" -Headers $headers -Limits $global:ReadLimits -OverrideLimitsValue $Configuration.readRequestsLimit
    if ($response.StatusCode -eq 200) {
        #Entity exists
        Write-Log -level 3 -logtext ("Entity exists. key: $key")
        return $True
    }
    elseif ($response.StatusCode -eq 404) {
        Write-Log -level 3 -logtext ("Entity does not exist. key: $key")
        return $False
    }
    else {
        Write-Log -level 2 -logtext ("Checking if entity exists failed with statuscode: $($response.StatusCode). Further information: " + $($response.Body))
        if ($Configuration.failOnError) {
            ExitHelper
        }
    }
}


#---------------------
function CreateEntity([STRING] $authSessionID, $body) {
    Write-Log -level 3 -logtext ("Starting CreateEntity")

    $headers = New-Object "System.Collections.Generic.Dictionary[[String],[String]]"
    $headers.Add("Authorization", "Bearer $authSessionID")
    $headers.Add("Origin", $global:parsedBaseUri.Scheme + "://" + $global:parsedBaseUri.Host)
    $headers.Add("Content-Type", "application/json; charset=utf-8")
    $headers.Add("Accept", "application/json")

    $body = $body | convertTo-Json -Depth 1
    $url = [uri]::EscapeUriString($businessobjectsUri)

    Write-Log -level 3 -logtext ("URL: $url")
    Write-Log -level 3 -logtext ("Body: $body")

    $bytesBody = [System.Text.Encoding]::UTF8.GetBytes($body);

    $response = BusinessObjectsRequestHandler $url -Method "POST" -Headers $headers -Body $bytesBody -Limits $global:WriteLimits -OverrideLimitsValue $Configuration.writeRequestsLimit
    if ($response.StatusCode -ne 201) {
        Write-Log -level 2 -logtext ("Creating entity failed with statuscode: $($response.StatusCode). Further information: " + $($response.Body))
        if ($Configuration.failOnError) {
            ExitHelper
        }
    }
    else {
        Write-Log -level 0 -logtext ("Created new entity")
    }
}

#---------------------
function UpdateEntity([STRING] $authSessionID, $body, $key) {
    Write-Log -level 3 -logtext ("Starting UpdateEntity with key: $key")

    $headers = New-Object "System.Collections.Generic.Dictionary[[String],[String]]"
    $headers.Add("Authorization", "Bearer $authSessionID")
    $headers.Add("Origin", $global:parsedBaseUri.Scheme + "://" + $global:parsedBaseUri.Host)
    $headers.Add("Content-Type", "application/json; charset=utf-8")
    $headers.Add("Accept", "application/json")

    $body = $body | convertTo-Json -Depth 1

    if ($Configuration.entityKeyType -eq "String") {
        $url = "$businessobjectsUri('$key')"
    }
    elseif ($Configuration.entityKeyType -in ("Guid", "Int32", "Int64")) {
        $url = "$businessobjectsUri($key)"
    }
    else {
        Write-Log -level 2 -logtext ("The Entitykeytype is not configured correctly!")
    }
    $url = [uri]::EscapeUriString($url)

    Write-Log -level 3 -logtext ("URL: $url")
    Write-Log -level 3 -logtext ("Body: $body")
    $body = [System.Text.Encoding]::UTF8.GetBytes($body);

    $response = BusinessObjectsRequestHandler $url -Method "PUT" -Headers $headers -Body $body -Limits $global:WriteLimits -OverrideLimitsValue $Configuration.writeRequestsLimit
    if ($response.StatusCode -ne 204) {
        Write-Log -level 2 -logtext ("Updating entity failed with statuscode: $($response.StatusCode). Further information: " + $($response.Body))
        if ($Configuration.failOnError) {
            ExitHelper
        }
    }
    else {
        Write-Log -level 0 -logtext ("Entity was updated. key: $key")
    }
}

#---------------------
function DeleteEntity([STRING] $authSessionID, $entityKeyType, $key) {
    Write-Log -level 3 -logtext ("Starting DeleteEntity with key: $key")

    $headers = New-Object "System.Collections.Generic.Dictionary[[String],[String]]"
    $headers.Add("Authorization", "Bearer $authSessionID")
    $headers.Add("Origin", $global:parsedBaseUri.Scheme + "://" + $global:parsedBaseUri.Host)
    $headers.Add("Content-Type", "application/json")
    $headers.Add("Accept", "application/json")

    if ($entityKeyType -eq "String") {
        $url = "$businessobjectsUri('$key')"
    }
    elseif ($Configuration.entityKeyType -in ("Guid", "Int32", "Int64")) {
        $url = "$businessobjectsUri($key)"
    }
    else {
        Write-Log -level 2 -logtext ("The Entitykeytype is not configured correctly!")
    }
    $url = [uri]::EscapeUriString($url)

    Write-Log -level 3 -logtext ("URL: $url")

    Write-Log -level 3 -logtext ("Deleting entity with key: $key")

    # Attempt to delete an entity that does not exist returns the response code 204 and does not cause the WebRequest to throw an exception.
    $response = BusinessObjectsRequestHandler $url -Method "DELETE" -Headers $headers -Limits $global:WriteLimits -OverrideLimitsValue $Configuration.writeRequestsLimit
    if ($response.StatusCode -eq 200) {
        Write-Log -level 0 -logtext ("Entity was deleted successfully. key: $key")
    }
    else {
        Write-Log -level 2 -logtext ("Deleting entity failed with statuscode: $($response.StatusCode). Further information: " + $($response.Body))
        if ($Configuration.failOnError) {
            ExitHelper
        }
    }
}

#---------------------
function GetEntities([STRING] $authSessionID, $nextLink) {
    Write-Log -level 3 -logtext ("Starting GetEntities")

    $headers = New-Object "System.Collections.Generic.Dictionary[[String],[String]]"
    $headers.Add("Authorization", "Bearer $authSessionID")
    $headers.Add("Origin", $global:parsedBaseUri.Scheme + "://" + $global:parsedBaseUri.Host)
    $headers.Add("Content-Type", "application/json")
    $headers.Add("Accept", "application/json")

    # No nextLink present
    if ($null -eq $nextLink) {
        Write-Log -level 3 -logtext ("No NextLink attribute provided.")
        $url = [uri]::EscapeUriString($businessobjectsUri)
    }
    else {
        Write-Log -level 3 -logtext ("NextLink attribute provided: $nextLink")
        $url = [uri]::EscapeUriString($nextLink)
    }

    Write-Log -level 3 -logtext ("URL: $url")

    $response = BusinessObjectsRequestHandler $url -Method "GET" -Headers $headers -Limits $global:ReadLimits -OverrideLimitsValue $Configuration.readRequestsLimit
    if ($response.StatusCode -eq 200) {
        try {
            $resultJson = ConvertFrom-Json $([String]::new($response.Body))
            Write-Log -level 3 -logtext ("Business objects entities returned: " + $resultJson.value.count )
            return $resultJson
        }
        catch {
            Write-Log -level 2 -logtext ("Getting all entities failed: converting business objects response to json failed.")
            if ($Configuration.failOnError) {
                ExitHelper
            }
        }
    }
    else {
        Write-Log -level 2 -logtext ("Getting all entities failed with statuscode: $($response.StatusCode). Further information: " + $($response.Body))
        if ($Configuration.failOnError) {
            ExitHelper
        }
    }
}

function BusinessObjectsRequestHandler {
    param( [Parameter()] $Url, [Parameter()] $Method, [Parameter()] $Headers, [Parameter()] $Body, [Parameter()] $Limits, [Parameter()] $OverrideLimitsValue)

    # If server does not support limits
    if ($Limits) {
        return BusinessObjectsRequestHandlerLimits $Url -Method $Method -Headers $Headers -Body $Body -Limits $Limits -OverrideLimitsValue $OverrideLimitsValue
    }
    else {
        return BusinessObjectsRequestHandlerNoLimits $Url -Method $Method -Headers $Headers -Body $Body
    }
}

function BusinessObjectsRequestHandlerLimits {
    param( [Parameter()] $Url, [Parameter()] $Method, [Parameter()] $Headers, [Parameter()] $Body, [Parameter()] $Limits, [Parameter()] $OverrideLimitsValue)

    $milliSecondsBetweenRequests = $null
    if ($OverrideLimitsValue) {
        $milliSecondsBetweenRequests = [int](60000 / $(If ($OverrideLimitsValue) { $OverrideLimitsValue } Else { 1 } ))
    }
    else {
        $milliSecondsBetweenRequests = [int]($Limits.timeUnitAsMilliseconds / $(If ($Limits.remainingNumberOfRequests) { $Limits.remainingNumberOfRequests } Else { 1 } ))
    }

    Write-Log -level 3 -logtext ("MilliSecondsBetweenRequests: $milliSecondsBetweenRequests")
    $elapsedTime = ([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()) - ($Limits.timeStampLastRequest)

    $waitTime = $([math]::max(0l, ($milliSecondsBetweenRequests - $elapsedTime)))
    Write-Log -level 3 -logtext ("Waiting: $waitTime milliseconds")
    Start-Sleep -Milliseconds $waitTime

    $responseHeader = $null
    $statusCode = $null
    $responseBody = $null
    try {
        $Limits.timeStampLastRequest = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()

        $response = Invoke-WebRequest $Url -Method $Method -body $Body -Headers $Headers -UserAgent $UserAgent

        $statusCode = $response.StatusCode
        $responseBody = $response.Content
        $responseHeader = $response.Headers
    }
    catch {
        $statusCode = $_.Exception.Response.StatusCode.value__
        $responseHeader = $_.Exception.Response.Headers

        if ($statusCode -eq 429) {
            $retryAfterInSeconds = [int](HeaderValueByNameOrNull -Header $responseHeader -Name "Retry-After")
            Write-Log -level 1 -logtext ("Reached $($Limits.type) request rate limits. Retrying in $retryAfterInSeconds seconds")

            Start-Sleep -Seconds $retryAfterInSeconds

            # Recursive call
            return BusinessObjectsRequestHandler $Url -Method $Method -Headers $Headers -Body $Body -Limits $Limits
        }

        $responseBody = RetrieveResponseBodyFromFailedWebRequest($_)
    }

    $remaingRequests = HeaderValueByNameOrNull -Header $responseHeader -Name "X-RateLimit-Remaining"
    if (-not ($null -eq $remaingRequests)) {
        $Limits.remainingNumberOfRequests = $remaingRequests
    }

    # Check if limits are not yet set but the corresponding header field is present -> If so, this request if the first one for that limit type (read or write).
    # If the limits are not yet set and the header field is not present disable the limits.
    if (-not $Limits.totalNumberOfRequests -and $(-not $null -eq $(HeaderValueByNameOrNull -Header $responseHeader -Name "X-RateLimit-Limit"))) {
        ParseLimitHeader -Limits $Limits -LimitsHeader $(HeaderValueByNameOrNull -Header $responseHeader -Name "X-RateLimit-Limit")
    }
    elseif (-not $Limits.totalNumberOfRequests) {
        # Set limits to null so signalise that the business objects instance has limits disabled and the 'BusinessObjectsRequestHandlerNoLimits'
        # function will be used for future requests for this limit type.
        if ($Limits.Type -eq "write") {
            $global:WriteLimits = $null;
        }
        elseif ($Limits.Type -eq "read") {
            $global:ReadLimits = $null
        }
    }

    Write-Log -level 3 -logtext ("Updated Limits: remaining $($Limits.type) requests: $($Limits.remainingNumberOfRequests)")

    return [PSCustomObject]@{
        StatusCode = $statusCode
        Body       = $responseBody
    }
}

function BusinessObjectsRequestHandlerNoLimits {
    param( [Parameter()] $Url, [Parameter()] $Method, [Parameter()] $Headers, [Parameter()] $Body )

    $statusCode = $null
    $responseBody = $null
    try {
        $response = Invoke-WebRequest $Url -Method $Method -body $Body -Headers $Headers -UserAgent $UserAgent
        $statusCode = $response.StatusCode
        $responseBody = $response.Content
    }
    catch {
        $statusCode = $_.Exception.Response.StatusCode.value__
        $responseBody = RetrieveResponseBodyFromFailedWebRequest($_)
    }

    return [PSCustomObject]@{
        StatusCode = $statusCode
        Body       = $responseBody
    }
}

#---------------------
function ParseLimitHeader {
    param([Parameter()] $Limits, [Parameter()] $LimitsHeader)

    # ----- NOTE Format can change! -----

    $headerComponents = $Limitsheader.Split(" ")

    # Read the maximum number od requests per time unit
    $Limits.totalNumberOfRequests = $headerComponents[0] -as [int]

    # Read the time unit
    # Replace new line needed because for some reason powershell inserts a newline after the last splitted element
    $timeUnit = $null
    # If is needed since PS5 does not support '?' for null checks
    if (-not $null -eq $headerComponents[3]) {
        $timeUnit = $headerComponents[3].replace("`n", "").replace("`r", "")
    }
    if ($timeUnit -eq "minute") {
        $Limits.timeUnitAsMilliseconds = 60 * 1000
    }
    elseif ($timeUnit -eq "hour") {
        $Limits.timeUnitAsMilliseconds = 60 * 60 * 1000
    }

    # If header can not be parsed log and exit script
    if (-not $Limits.totalNumberOfRequests -or (-not $Limits.timeUnitAsMilliseconds)) {
        Write-Log -level 2 -logtext ("Limits header 'X-RateLimit-Limit' is set '$LimitsHeader' but its value cloud not be parsed. You are probably using an old version of this script. Exiting ...")
        ExitHelper
    }
}

#---------------------
function ConnectToMSSQLDB {
    Write-Log -level 3 -logtext ("Starting ConnectToMSSQLDB")
    try {
        $connectionString = $("Server=$($Configuration.dbServer);Database=$($Configuration.databaseName);User Id=$($Configuration.user);Password=$($Configuration.password)");
        $connection = New-Object System.Data.SqlClient.SqlConnection
        $connection.ConnectionString = $connectionString
        $connection.Open()

        Write-Log -level 3 -logtext ("Connection to MSSQL DB was successfull.")

        return $connection
    }
    catch {
        Write-Log -level 2 -logtext ("Connection to MSSQL DB failed. " + $_)
        ExitHelper
    }
}


#---------------------
function ConnectToOracleDB {
    Write-Log -level 3 -logtext ("Starting ConnectToOracleDB")
    try {
        $connectionString = "User Id=$($Configuration.user);Password=$($Configuration.password);Data Source=$($Configuration.dataSource)"
        $connection = New-Object System.Data.OracleClient.OracleConnection($connectionString)
        $connection.Open()

        Write-Log -level 3 -logtext ("Connection to Oracle DB was successfull.")

        return $connection
    }
    catch {
        Write-Log -level 2 -logtext ("Connection to Oracle DB failed. " + $_)
        ExitHelper
    }
}

#--------------------
function ReadCSVFile {
    if ($Configuration.csvHeader) {
        $csv = Import-Csv -Path $(PathHelper($Configuration.csvPath)) -Header $Configuration.csvHeader -Delimiter $Configuration.csvFileDelimiter

        $result = $csv | Select-Object -Skip 1 | ForEach-Object {
            $row = $_;

            & $MappingCode
        }

        return $result;
    }
    else {
        $csv = Import-Csv -Path $(PathHelper($Configuration.csvPath)) -Delimiter $Configuration.csvFileDelimiter

        $result = $csv | Select-Object | ForEach-Object {
            $row = $_;

            & $MappingCode
        }

        return $result;
    }
}

#--------------------
function ExecuteQuery($connection, $query) {
    Write-Log -level 3 -logtext ("Starting ExecuteQuery")
    Write-Log -level 3 -logtext ("Query: " + $query)
    try {
        $command = $connection.CreateCommand()
        $command.CommandText = $query
        $reader = $command.ExecuteReader()

        $result = @()
        $row = $reader;
        while ($row.read()) {
            $temp = & $MappingCode
            $result = $result + $temp;
        }

        Write-Log -level 3 -logtext ("Closing database connection")
        $connection.Close()
        Write-Log -level 3 -logtext ("Database connection closed")
        return $result

    }
    catch {
        Write-Log -level 2 -logtext ("Executing Database query failed " + $_.Exception.ToString())
        ExitHelper
    }
    finally {
        if ($connection.State -eq "Open") {
            $connection.close()
        }
    }
}

#--------------------
# Helper method to determine
function HeaderValueByNameOrNull {
    param ( [Parameter()] $Header, [Parameter()] $Name )

    if (!$Header) {
        return $null;
    }

    if ($Header.GetType().ToString() -eq "System.Net.Http.Headers.HttpResponseHeaders" -or $Header.GetType().ToString() -eq "System.Net.WebHeaderCollection") {
        if ($Header.Contains($Name)) {
            return ($Header.GetValues($Name) | Out-String)
        }
    }
    else {
        return $Header[$Name]
    }
}

#--------------------
function RetrieveResponseBodyFromFailedWebRequest($exception) {
    # The following operations are not needed with PowerShell version greater than 5.x.x
    if (($PSVersionTable.PSVersion.Major -lt 6) -and ($null -ne $exception.Exception.Response)) {
        $reader = New-Object System.IO.StreamReader($exception.Exception.Response.GetResponseStream())
        $reader.BaseStream.Position = 0
        $reader.DiscardBufferedData()
        $responseBody = $reader.ReadToEnd()

        return $responseBody
    }
    return $exception
}

#--------------------
function PathHelper($path) {
    if ([System.IO.Path]::IsPathRooted($path)) {
        return $path
    }
    return $(Join-Path -Path $configBasePath -ChildPath $path)
}

#--------------------
function CheckConfig($Configuration) {
    Write-Host "Checking Config.."

    # Logging Config check
    # If 'logDir' is set it must be a valid path
    if ($Configuration.logDir) {
        if (!(Test-Path $(PathHelper($Configuration.logDir)))) {
            Write-Host "Log Directory does not exist! Exiting..." -ForegroundColor Red
            ExitHelper
        }
        Write-Log -level 0 -logtext ("Logging to log file")
    }
    else {
        Write-Log -level 0 -logtext ("Logging to console")
    }

    # If 'deleteOldLogs' is set it must be a positive integer value
    if ($Configuration.deleteOldLogs -And $Configuration.deleteOldLogs -lt 0) {
        Write-Log -level 2 -logtext ("deleteOldLogs must be a positive value! Exiting...")
        ExitHelper
    }

    #  Config check
    if (![System.Uri]::TryCreate($Configuration.baseUri, 'Absolute', [ref]$global:parsedBaseUri)) {
        Write-Log -level 2 -logtext ("The BaseUri '$($Configuration.baseUri)' is not valid! Exiting...")
        ExitHelper
    }

    if (-Not $Configuration.apiKey) {
        Write-Log -level 2 -logtext ("The API Key is not configured! Exiting...")
        Write-Log -level 0 -logtext ("Did you rename the API key property name? It has been renamed: 'apikey' -> 'apiKey'.")
        ExitHelper
    }

    if (-Not $Configuration.modelName) {
        Write-Log -level 2 -logtext ("The Modelname is not configured! Exiting...")
        ExitHelper
    }
    elseif ($Configuration.modelName -like "*-staged") {
        Write-Log -level 2 -logtext (
            "The Modelname contains a '-staged'. Please configure staged models by setting the 'modelIsStaged' parameter to 'true' and not by appending '-staged' to the model name. Exiting..."
        )
        ExitHelper
    }

    if (-Not $Configuration.entityPluralName) {
        Write-Log -level 2 -logtext ("The entityPluralName is not configured! Exiting...")
        ExitHelper
    }

    if (-Not $Configuration.entityKey) {
        Write-Log -level 2 -logtext ("The Entitykey is not configured! Exiting...")
        ExitHelper
    }

    if (!($Configuration.entityKeyType -in ("Guid", "Int32", "Int64", "String"))) {
        Write-Log -level 2 -logtext ("The Entitykeytype is not configured correctly! Exiting...")
        ExitHelper
    }

    if ($Configuration.writeRequestsLimit -lt 0) {
        Write-Log -level 2 -logtext ("The WriteRequestLimit is negative! Exiting...")
        ExitHelper
    }

    if ($Configuration.readRequestsLimit -lt 0) {
        Write-Log -level 2 -logtext ("The ReadRequestLimit is negative! Exiting...")
        ExitHelper
    }

    # Database Config check
    if ($Configuration.dbType -eq "Oracle") {
        if ($Configuration.dataSource -eq "") {
            Write-Log -level 2 -logtext ("The Datasource is not configured! Exiting...")
            ExitHelper
        }

        if ($Configuration.user -eq "") {
            Write-Log -level 2 -logtext ("The Databaseuser is not configured! Exiting...")
            ExitHelper
        }

        if ($Configuration.password -eq "") {
            Write-Log -level 2 -logtext ("The Databasepassword is not configured! Exiting...")
            ExitHelper
        }
    }
    elseif ($Configuration.dbType -eq "MSSQL") {
        if ($Configuration.dbServer -eq "") {
            Write-Log -level 2 -logtext ("The Databaseserver is not configured! Exiting...")
            ExitHelper
        }

        if ($Configuration.databaseName -eq "") {
            Write-Log -level 2 -logtext ("The Databasename is not configured! Exiting...")
            ExitHelper
        }

        if ($Configuration.user -eq "") {
            Write-Log -level 2 -logtext ("The Databaseuser is not configured! Exiting...")
            ExitHelper
        }

        if ($Configuration.password -eq "") {
            Write-Log -level 2 -logtext ("The Databasepassword is not configured! Exiting...")
            ExitHelper
        }
    }
    elseif ($Configuration.dbType -eq "CSV") {
        if ($Configuration.csvPath -eq "") {
            Write-Log -level 2 -logtext ("The CSV-Path is not configured! Exiting...")
            ExitHelper
        }

        if (!(Test-Path $(PathHelper($Configuration.csvPath)) -PathType Leaf)) {
            Write-Host "CSV-Path '$(PathHelper($Configuration.csvPath))' does not exist! Exiting..." -ForegroundColor Red
            ExitHelper
        }
        elseif ([System.IO.Path]::GetExtension($(PathHelper($Configuration.csvPath))).ToLower() -ne ".csv") {
            Write-Host "Configured CSV file at '$($Configuration.csvPath)' is not a valid CSV file! Exiting..." -ForegroundColor Red
            ExitHelper
        }

        if (-Not $Configuration.csvFileDelimiter) {
            Write-Log -level 2 -logtext ("The csvFileDelimiter is not configured! Exiting...")
            ExitHelper
        }
    }
    else {
        Write-Log -level 2 -logtext ("The Database Type is not configured correctly! Exiting..." )
        ExitHelper
    }

    if ($Configuration.query -eq "") {
        Write-Log -level 2 -logtext ("The Databasequery is not configured! Exiting...")
        ExitHelper
    }

    # If 'importIntervalTime' is set it must be a valid integer
    if ($Configuration.importIntervalTime) {
        if (-Not ($Configuration.importIntervalTime -is [int])) {
            Write-Log -level 2 -logtext ("The value of importIntervalTime is not numeric! Exiting...")
            ExitHelper
        }
        # If the value of 'importIntervalTime' is below "60" and grater "0", throw an error
        elseif ($Configuration.importIntervalTime -lt 60 -And $Configuration.importIntervalTime -ne 0) {
            Write-Log -level 2 -logtext ("The value of importIntervalTime is below 60, which is the minimum value (exception: the value 0 to disable regular imports) Exiting...")
            ExitHelper
        }
    }
    # Check if configs use the old property 'loopExecution'. If that is the case print a hint and exit.
    if ($Configuration.loopExecution) {
        Write-Log -level 2 -logtext ("Old property 'loopExecution' detected. It has been renamed: 'loopExecution' -> 'importIntervalTime'. Exiting...")
        ExitHelper
    }

    # Version Variable Config check
    if ($version -eq "") {
        Write-Log -level 2 -logtext ("Version is not configured! Exiting...")
        ExitHelper
    }

    # Check if the provided value of the 'mapping' value is valid powershell code
    if (-Not $Configuration.mapping) {
        Write-Log -level 2 -logtext ("Mapping is not defined! Exiting...")
        ExitHelper
    }
    else {
        # Convert the powershell code defined as string in the mapping attribute
        # into executable powershell code
        try {
            $codeAsSingleString = "";
            $Configuration.mapping | ForEach-Object {
                $codeAsSingleString += "$_;";
            }
            $rawCode = 'new-object psObject -Property @{' + $codeAsSingleString + '}'
            $global:MappingCode = [scriptblock]::Create($rawCode)
        }
        catch {
            Write-Log -level 2 -logtext ("Mapping is defined, but contains no valid PowerShell code. Additional information: $_")
            ExitHelper
        }
    }
}

#-------------------------------------------
#----------- Script Functions --------------
#-------------------------------------------

#-------------------------------------------
#---------------- Logging ------------------
#-------------------------------------------

function Write-Log([string]$logtext, [int]$level = 0) {
    # If 'logDir' is empty log to console
    if (!$Configuration.logDir) {
        Write-Host $logtext
        return;
    }

    $date = get-date -format "yyyy-MM-dd"
    $file = ("Log_" + $date + ".log")
    $logfile = $(PathHelper($Configuration.logDir)) + "\" + $file

    $logdate = get-date -format "yyyy-MM-dd HH:mm:ss"
    if ($level -eq 0) {
        $logtext = "[INFO] " + $logtext
        $text = "[" + $logdate + "] - " + $logtext
        Write-Host $text
        $text | Out-File $logfile -Append
    }
    if ($level -eq 1) {
        $logtext = "[WARNING] " + $logtext
        $text = "[" + $logdate + "] - " + $logtext
        Write-Host $text -ForegroundColor Yellow
        $text | Out-File $logfile -Append
    }
    if ($level -eq 2) {
        $logtext = "[ERROR] " + $logtext
        $text = "[" + $logdate + "] - " + $logtext
        Write-Host $text -ForegroundColor Red
        $text | Out-File $logfile -Append
    }

    # DEBUG Log
    if (($level -eq 3) -and ($Configuration.debugLog)) {
        $logtext = "[DEBUG] " + $logtext
        $text = "[" + $logdate + "] - " + $logtext
        Write-Host $text -ForegroundColor Green
        $text | Out-File $logfile -Append
    }
}

# Deletes log files that are older than "X" days
function DeleteOldLogs() {
    Write-Log -level 3 -logtext ("Starting DeleteOldLogs")
    $filter = $(PathHelper($Configuration.logDir)) + "\*"

    Get-ChildItem -Path $filter -Include "*.log" | Where-Object LastWriteTime -LT (Get-Date).AddDays($Configuration.deleteOldLogs * (-1)) | Remove-Item -Force
}

#-------------------------------------------
#---------------- Logging ------------------
#-------------------------------------------

#-------------------------------------------
#---------------- Script -------------------
#-------------------------------------------

do {
    Write-Host "Start BusinessObjectsUpload.ps1. Script name: '$($Configuration.scriptName)'"
    Main
    if ($Configuration.deleteOldLogs -And $Configuration.logDir) {
        DeleteOldLogs
    }
    Write-Host "End BusinessObjectsUpload.ps1. Script name: '$($Configuration.scriptName)'"

    if ($Configuration.importIntervalTime) {
        Write-Host "Sleeping for " + $Configuration.importIntervalTime + " seconds"
        Start-Sleep -Seconds $Configuration.importIntervalTime
    }
} while ($Configuration.importIntervalTime)

#-------------------------------------------
#---------------- Script -------------------
#-------------------------------------------

# Script-Configuration
class ScriptConfiguration {
    [STRING] $scriptName;
    [BOOL] $failOnError;

    [BOOL] $deleteNonExistingEntities;
    [INT] $importIntervalTime;
    [INT] $loopExecution;

    [STRING] $logDir;
    [BOOL] $debugLog;
    [INT] $deleteOldLogs;

    [INT] $writeRequestsLimit;
    [INT] $readRequestsLimit;

    # business objects related configuration
    [STRING] $baseUri;
    [STRING] $apiKey;
    [STRING] $modelName;
    [BOOL] $modelIsStaged;
    [STRING] $entityPluralName;
    [STRING] $entityKey;
    [String] $entityKeyType;

    # Data source configuration
    [STRING] $dbType;

    # CSV configuration
    [STRING] $csvPath;
    [STRING[]] $csvHeader;
    [STRING] $csvFileDelimiter;

    # SQL database related configuration
    [STRING] $user;
    [STRING] $password;
    [STRING] $query;

    # Oracle database related configuration
    [STRING] $dataSource;

    # MSSQL database related configuration
    [STRING] $dbServer;
    [STRING] $databaseName;

    # Array, that contains the mapping expressions
    [STRING[]] $mapping;
}

class Limits {
    [LONG] $timeStampLastRequest;
    [INT] $totalNumberOfRequests;
    [INT] $remainingNumberOfRequests;
    [STRING] $type;
    [INT] $timeUnitAsMilliseconds
}