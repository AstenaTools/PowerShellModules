#Requires -Version 5.1

Set-StrictMode -Version Latest

# Resource id of the Azure DevOps first-party app, used when asking the Azure CLI for an
# access token.
$script:AdoResourceId = '499b84ac-1321-427f-aa17-267ca6975798'

# The default view: identification, age, and the browser link to open the pull request.
# Everything else stays on the object for Select-Object/Export-Csv.
Update-TypeData -TypeName 'AzureDevOps.ActivePullRequest' -Force `
    -DefaultDisplayPropertySet Id, Project, Repository, Title, CreatedBy, AgeDays, IsDraft, WebUrl

# The default view: what was closed, by whom and when. AssignedTo and the browser link stay on
# the object.
Update-TypeData -TypeName 'AzureDevOps.ClosedWorkItem' -Force `
    -DefaultDisplayPropertySet Id, Project, WorkItemType, Title, State, ClosedBy, ClosedDate

# The default view: the headline count and its shape. Projects and WorkItemTypes carry the
# breakdown for anyone who asks for it.
Update-TypeData -TypeName 'AzureDevOps.ClosedWorkItemCount' -Force `
    -DefaultDisplayPropertySet ClosedBy, ClosedCount, Percent, ProjectCount, FirstClosed, LastClosed

function Get-JsonProperty {
    <#
        .SYNOPSIS
            Reads a property from a ConvertFrom-Json object, returning a default when it is absent.

        .DESCRIPTION
            Set-StrictMode -Version Latest turns a reference to a missing property into a terminating
            error, and Azure DevOps omits properties freely, so every payload access goes through
            the PSObject property bag instead.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)]
        $InputObject,

        [Parameter(Mandatory, Position = 1)]
        [string]$Name,

        [Parameter(Position = 2)]
        $Default = $null
    )

    if ($null -eq $InputObject) { return $Default }

    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value) { return $Default }

    return $property.Value
}

function Get-HttpHeaderValue {
    <#
        .SYNOPSIS
            Case-insensitive header lookup that works on both header collections.

        .DESCRIPTION
            Windows PowerShell 5.1 exposes Dictionary[string,string] and PowerShell 7+
            Dictionary[string,string[]], and indexing an absent key on the latter throws.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)]
        $Headers,

        [Parameter(Mandatory, Position = 1)]
        [string]$Name
    )

    if ($null -eq $Headers) { return $null }

    foreach ($key in $Headers.Keys) {
        if ($key -eq $Name) { return (@($Headers[$key]))[0] }
    }

    return $null
}

function New-BasicAuthValue {
    <#
        .SYNOPSIS
            Builds the Authorization header value for a personal access token.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string]$Pat
    )

    $bytes = [System.Text.Encoding]::ASCII.GetBytes(":$Pat")
    return 'Basic ' + [Convert]::ToBase64String($bytes)
}

function Get-AzCliToken {
    <#
        .SYNOPSIS
            Returns a bearer token from the current 'az login' session, or $null.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    if (-not (Get-Command az -ErrorAction SilentlyContinue)) { return $null }

    try {
        $token = & az account get-access-token `
            --resource $script:AdoResourceId `
            --query accessToken --output tsv 2>$null
    }
    catch {
        return $null
    }

    if ($LASTEXITCODE -ne 0) { return $null }
    if ([string]::IsNullOrWhiteSpace($token)) { return $null }

    return ([string]$token).Trim()
}

function Resolve-AuthorizationHeader {
    <#
        .SYNOPSIS
            Picks a credential and returns @{ Value = <header>; Source = <text> }.

        .DESCRIPTION
            Resolution order:
              1. -PersonalAccessToken
              2. $env:AZURE_DEVOPS_EXT_PAT      (the Azure CLI devops extension PAT)
              3. $env:AZURE_DEVOPS_PAT
              4. $env:SYSTEM_ACCESSTOKEN        (OAuth token inside a pipeline)
              5. az account get-access-token    (an existing 'az login' session)
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [string]$PersonalAccessToken
    )

    if ($PersonalAccessToken) {
        return @{ Value = (New-BasicAuthValue -Pat $PersonalAccessToken); Source = 'PAT (-PersonalAccessToken)' }
    }
    if ($env:AZURE_DEVOPS_EXT_PAT) {
        return @{ Value = (New-BasicAuthValue -Pat $env:AZURE_DEVOPS_EXT_PAT); Source = 'PAT (AZURE_DEVOPS_EXT_PAT)' }
    }
    if ($env:AZURE_DEVOPS_PAT) {
        return @{ Value = (New-BasicAuthValue -Pat $env:AZURE_DEVOPS_PAT); Source = 'PAT (AZURE_DEVOPS_PAT)' }
    }
    if ($env:SYSTEM_ACCESSTOKEN) {
        return @{ Value = "Bearer $($env:SYSTEM_ACCESSTOKEN)"; Source = 'pipeline OAuth token (SYSTEM_ACCESSTOKEN)' }
    }

    $token = Get-AzCliToken
    if ($token) {
        return @{ Value = "Bearer $token"; Source = 'Azure CLI (az login)' }
    }

    throw ("No Azure DevOps credential found. Do one of the following and re-run:`n" +
        "  * az login`n" +
        "  * `$env:AZURE_DEVOPS_EXT_PAT = '<pat>'`n" +
        "  * <cmdlet> -PersonalAccessToken '<pat>'`n" +
        'A PAT needs the "Code (read)" scope for pull requests, or "Work items (read)" for work items.')
}

function Enable-Tls12 {
    <#
        .SYNOPSIS
            Adds TLS 1.2 to the process-wide protocol list on Windows PowerShell 5.1.

        .DESCRIPTION
            Invoke-WebRequest on 5.1 still defaults to protocols Azure DevOps refuses. TLS 1.2 is
            added to whatever is already enabled rather than replacing it, so calling into this
            module cannot take a protocol away from the rest of the session. PowerShell 7+ needs
            nothing.
    #>
    [CmdletBinding()]
    param()

    if ($PSVersionTable.PSEdition -eq 'Core') { return }

    [Net.ServicePointManager]::SecurityProtocol =
        [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
}

function Invoke-AdoApi {
    <#
        .SYNOPSIS
            Calls a REST endpoint and returns @{ Data = <parsed json>; Headers = ... }.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [string]$Uri,

        [Parameter(Mandatory)]
        [hashtable]$Headers,

        [ValidateSet('Get', 'Post')]
        [string]$Method = 'Get',

        $Body
    )

    Write-Verbose "$($Method.ToUpperInvariant()) $Uri"

    $arguments = @{
        Uri             = $Uri
        Headers         = $Headers
        Method          = $Method
        UseBasicParsing = $true
        ErrorAction     = 'Stop'
    }

    if ($null -ne $Body) {
        $json = if ($Body -is [string]) { $Body } else { $Body | ConvertTo-Json -Depth 10 -Compress }

        # Encoding the body by hand: Windows PowerShell 5.1 otherwise sends a string body as
        # ISO-8859-1, which mangles any non-ASCII character in a WIQL query.
        $arguments['Body'] = [System.Text.Encoding]::UTF8.GetBytes($json)
        $arguments['ContentType'] = 'application/json; charset=utf-8'
    }

    try {
        $response = Invoke-WebRequest @arguments
    }
    catch {
        # Held in a variable because switch rebinds $_ to the value being tested, which would
        # leave the branches below reaching for a property of $status.
        $failure = $_

        $status = $null
        $webResponse = Get-JsonProperty $failure.Exception 'Response'
        if ($null -ne $webResponse) {
            $code = Get-JsonProperty $webResponse 'StatusCode'
            if ($null -ne $code) { $status = [int]$code }
        }

        # The response body carries the Azure DevOps error code - VS402337 for a work item
        # query that overflows, and friends - which callers match on to recover. A bare 400
        # says nothing useful.
        $detail = [string](Get-JsonProperty (Get-JsonProperty $failure 'ErrorDetails') 'Message' '')
        if ($detail) {
            try { $detail = [string](Get-JsonProperty ($detail | ConvertFrom-Json) 'message' $detail) }
            catch { Write-Debug 'The error body was not JSON; using it as it came.' }
            $detail = ' ' + ([string]$detail).Trim()
        }

        switch ($status) {
            400 { throw "Azure DevOps rejected the request to '$Uri' (400).$detail" }
            401 { throw "Azure DevOps rejected the credential (401). Re-run 'az login' or supply a PAT with a read scope for the data being queried." }
            403 { throw "The credential is valid but lacks permission for '$Uri' (403)." }
            404 { throw "Not found: $Uri (404). Check the organization and project names." }
            default { throw "Request to '$Uri' failed: $($failure.Exception.Message)$detail" }
        }
    }

    $text = $response.Content
    if ($text -is [byte[]]) { $text = [System.Text.Encoding]::UTF8.GetString($text) }

    # An unauthenticated browser-style request is answered with a sign-in page carrying HTTP 200,
    # so a leading '<' means the credential never took.
    if ($text -match '^\s*<') {
        throw 'Azure DevOps returned an HTML sign-in page instead of JSON - the credential was not accepted. Re-run with a PAT that has a read scope for the data being queried.'
    }

    $data = $null
    if (-not [string]::IsNullOrWhiteSpace($text)) { $data = $text | ConvertFrom-Json }

    return @{ Data = $data; Headers = $response.Headers }
}

function Get-AdoProjectName {
    <#
        .SYNOPSIS
            The names of every well-formed project in the organization, following continuation tokens.

        .DESCRIPTION
            Private helper. Callers should wrap the result in @() - an organization with a single
            project would otherwise yield a scalar, and an empty one $null.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [hashtable]$Headers,

        [Parameter(Mandatory)]
        [string]$Organization,

        [Parameter(Mandatory)]
        [string]$ApiVersion
    )

    $continuation = $null

    do {
        $uri = 'https://dev.azure.com/{0}/_apis/projects?stateFilter=wellFormed&$top=200&api-version={1}' -f
            [uri]::EscapeDataString($Organization), $ApiVersion
        if ($continuation) {
            $uri += '&continuationToken=' + [uri]::EscapeDataString($continuation)
        }

        $result = Invoke-AdoApi -Uri $uri -Headers $Headers

        foreach ($item in @(Get-JsonProperty $result.Data 'value')) {
            $name = [string](Get-JsonProperty $item 'name' '')
            if ($name) { $name }
        }

        $continuation = Get-HttpHeaderValue $result.Headers 'x-ms-continuationtoken'
    } while ($continuation)
}

function Get-AdoActivePullRequest {
    <#
        .SYNOPSIS
            Active pull requests of one project, across every repository in it.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable]$Headers,

        [Parameter(Mandatory)]
        [string]$Organization,

        [Parameter(Mandatory)]
        [string]$ProjectName,

        [Parameter(Mandatory)]
        [string]$ApiVersion,

        [Parameter(Mandatory)]
        [int]$PageSize,

        [string]$TargetRefName
    )

    $found = [System.Collections.Generic.List[object]]::new()
    $skip = 0

    do {
        $uri = 'https://dev.azure.com/{0}/{1}/_apis/git/pullrequests?searchCriteria.status=active&$top={2}&$skip={3}&api-version={4}' -f
            [uri]::EscapeDataString($Organization),
            [uri]::EscapeDataString($ProjectName),
            $PageSize, $skip, $ApiVersion

        if ($TargetRefName) {
            $uri += '&searchCriteria.targetRefName=' + [uri]::EscapeDataString($TargetRefName)
        }

        $result = Invoke-AdoApi -Uri $uri -Headers $Headers
        $batch = @(Get-JsonProperty $result.Data 'value')
        foreach ($pr in $batch) { $found.Add($pr) }

        $skip += $PageSize
    } while ($batch.Count -eq $PageSize)

    return $found
}

function ConvertTo-DateTimeValue {
    <#
        .SYNOPSIS
            Parses a REST date, which arrives as DateTime on PS7 and as a string on 5.1.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)]
        $Value
    )

    if ($null -eq $Value) { return $null }
    if ($Value -is [datetime]) { return $Value }

    try {
        return [datetime]::Parse([string]$Value, [cultureinfo]::InvariantCulture,
            [System.Globalization.DateTimeStyles]::RoundtripKind)
    }
    catch {
        return $null
    }
}

function Get-ShortBranchName {
    <#
        .SYNOPSIS
            Strips the refs/heads/ prefix off a branch ref.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Position = 0)]
        [string]$RefName
    )

    if (-not $RefName) { return $null }
    return ($RefName -replace '^refs/heads/', '')
}

function Resolve-TargetRefName {
    <#
        .SYNOPSIS
            Expands a branch name to a full ref, leaving an already-qualified ref alone.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Position = 0)]
        [string]$Branch
    )

    if (-not $Branch) { return $null }
    if ($Branch -like 'refs/*') { return $Branch }
    return "refs/heads/$Branch"
}

function ConvertTo-PullRequestInfo {
    <#
        .SYNOPSIS
            Flattens one REST pull request into a reporting object.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        $PullRequest,

        [Parameter(Mandatory)]
        [string]$Organization,

        [Parameter(Mandatory)]
        [datetime]$Now
    )

    $repository = Get-JsonProperty $PullRequest 'repository'
    $repoProject = Get-JsonProperty $repository 'project'
    $author = Get-JsonProperty $PullRequest 'createdBy'
    $created = ConvertTo-DateTimeValue (Get-JsonProperty $PullRequest 'creationDate')

    $reviewers = @(Get-JsonProperty $PullRequest 'reviewers')
    $votes = @($reviewers | ForEach-Object { [int](Get-JsonProperty $_ 'vote' 0) })

    $projectName = [string](Get-JsonProperty $repoProject 'name' '')
    $repoName = [string](Get-JsonProperty $repository 'name' '')
    $id = Get-JsonProperty $PullRequest 'pullRequestId'

    $webUrl = 'https://dev.azure.com/{0}/{1}/_git/{2}/pullrequest/{3}' -f
        [uri]::EscapeDataString($Organization),
        [uri]::EscapeDataString($projectName),
        [uri]::EscapeDataString($repoName),
        $id

    $ageDays = $null
    if ($created) { $ageDays = [math]::Round(($Now - $created).TotalDays, 1) }

    $info = [pscustomobject]@{
        Id               = $id
        Project          = $projectName
        Repository       = $repoName
        Title            = [string](Get-JsonProperty $PullRequest 'title' '')
        CreatedBy        = [string](Get-JsonProperty $author 'displayName' '')
        AgeDays          = $ageDays
        IsDraft          = [bool](Get-JsonProperty $PullRequest 'isDraft' $false)
        SourceBranch     = Get-ShortBranchName ([string](Get-JsonProperty $PullRequest 'sourceRefName' ''))
        TargetBranch     = Get-ShortBranchName ([string](Get-JsonProperty $PullRequest 'targetRefName' ''))
        Approvals        = @($votes | Where-Object { $_ -ge 5 }).Count
        WaitingForAuthor = @($votes | Where-Object { $_ -eq -5 }).Count
        Rejections       = @($votes | Where-Object { $_ -eq -10 }).Count
        ReviewerCount    = $reviewers.Count
        MergeStatus      = [string](Get-JsonProperty $PullRequest 'mergeStatus' '')
        CreationDate     = $created
        CreatedByEmail   = [string](Get-JsonProperty $author 'uniqueName' '')
        WebUrl           = $webUrl
    }

    $info.PSObject.TypeNames.Insert(0, 'AzureDevOps.ActivePullRequest')
    return $info
}

function Get-AzureDevOpsPullRequest {
    <#
        .SYNOPSIS
            Retrieves every active pull request across all projects in an Azure DevOps organization.

        .DESCRIPTION
            Enumerates the projects of the organization, then queries each project's Git pull
            requests with status "active" and emits one object per pull request. Because the query is
            project-scoped rather than repository-scoped, a whole organization is covered in a
            handful of REST calls.

            Authentication is resolved in this order:
              1. -PersonalAccessToken
              2. $env:AZURE_DEVOPS_EXT_PAT      (the Azure CLI devops extension PAT)
              3. $env:AZURE_DEVOPS_PAT
              4. $env:SYSTEM_ACCESSTOKEN        (OAuth token inside a pipeline)
              5. az account get-access-token    (an existing 'az login' session)

            Results are objects, so they can be piped to Format-Table, Export-Csv, Where-Object and
            friends. The default view shows Id, Project, Repository, Title, CreatedBy, AgeDays,
            IsDraft and WebUrl; the remaining properties stay on the object for Select-Object.

            Oldest first: age is what makes a stale pull request worth looking at. Drafts are
            included unless -ExcludeDrafts is used.

            A project without the Git service, or one the credential cannot read, produces a warning
            and is skipped rather than aborting the whole scan. Progress on the scan, the credential
            source in use and the per-project counts are written to the verbose stream - run with
            -Verbose to see them.

        .PARAMETER Organization
            Azure DevOps organization name. Default: astena

        .PARAMETER Project
            Limit the scan to these projects (name or id). Omit to scan all of them.

        .PARAMETER CreatedBy
            Only return pull requests whose author display name or sign-in name contains this text.

        .PARAMETER TargetBranch
            Only return pull requests targeting this branch, e.g. main or refs/heads/release/1.0.

        .PARAMETER ExcludeDrafts
            Leave draft pull requests out of the result.

        .PARAMETER PersonalAccessToken
            Azure DevOps PAT with Code (read) scope. Overrides every other credential source.

        .PARAMETER ApiVersion
            REST API version. Default: 7.1

        .PARAMETER PageSize
            Pull requests fetched per request, 1-1000. Default: 100

        .PARAMETER Format
            How to render the result.

            Object  Emit one object per pull request (default). Fully pipeable.
            Table   Render as a table, equivalent to piping to Format-Table -AutoSize.
            List    Render as a list, one property per line, showing every property.

            Table and List produce display output rather than data: the result cannot be piped into
            Where-Object, Sort-Object or Export-Csv afterwards. Leave -Format off when you need to
            keep processing the result.

        .EXAMPLE
            Get-AzureDevOpsPullRequest

            All active pull requests in the astena organization, oldest first.

        .EXAMPLE
            Get-AzureDevOpsPullRequest -Format Table

        .EXAMPLE
            Get-AzureDevOpsPullRequest -Project 'Business Central' -ExcludeDrafts

        .EXAMPLE
            Get-AzureDevOpsPullRequest -CreatedBy 'Klemmensen' | Select-Object Title, AgeDays, WebUrl

        .EXAMPLE
            Get-AzureDevOpsPullRequest | Export-Csv .\active-prs.csv -NoTypeInformation

        .OUTPUTS
            AzureDevOps.ActivePullRequest objects carrying Id, Project, Repository, Title, CreatedBy,
            AgeDays, IsDraft, SourceBranch, TargetBranch, Approvals, WaitingForAuthor, Rejections,
            ReviewerCount, MergeStatus, CreationDate, CreatedByEmail and WebUrl.
            With -Format Table or -Format List, formatting objects for display instead.

        .NOTES
            Compatible with Windows PowerShell 5.1 and PowerShell 7+.
            A PAT needs only the "Code (read)" scope.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [ValidateNotNullOrEmpty()]
        [string]$Organization = 'astena',

        [string[]]$Project,

        [string]$CreatedBy,

        [string]$TargetBranch,

        [switch]$ExcludeDrafts,

        [string]$PersonalAccessToken,

        [ValidateNotNullOrEmpty()]
        [string]$ApiVersion = '7.1',

        [ValidateRange(1, 1000)]
        [int]$PageSize = 100,

        [ValidateSet('Object', 'Table', 'List')]
        [string]$Format = 'Object'
    )

    begin {
        Enable-Tls12
    }

    process {
        $auth = Resolve-AuthorizationHeader -PersonalAccessToken $PersonalAccessToken
        $restHeaders = @{
            Authorization = $auth.Value
            Accept        = 'application/json'
        }

        Write-Verbose "Organization '$Organization' - authenticating with $($auth.Source)."

        $targetRef = Resolve-TargetRefName $TargetBranch

        if ($Project) {
            $projectNames = @($Project)
            Write-Verbose "Scanning $($projectNames.Count) requested project(s)."
        }
        else {
            $projectNames = @(Get-AdoProjectName -Headers $restHeaders -Organization $Organization -ApiVersion $ApiVersion)
            Write-Verbose "Found $($projectNames.Count) project(s)."
        }

        $now = Get-Date
        $pullRequests = [System.Collections.Generic.List[object]]::new()
        $index = 0

        foreach ($projectName in $projectNames) {
            $index++
            Write-Progress -Activity 'Collecting active pull requests' -Status $projectName `
                -PercentComplete (100 * $index / [math]::Max($projectNames.Count, 1))

            try {
                $raw = @(Get-AdoActivePullRequest -Headers $restHeaders -Organization $Organization `
                        -ProjectName $projectName -ApiVersion $ApiVersion -PageSize $PageSize `
                        -TargetRefName $targetRef)
            }
            catch {
                # A project without the Git service, or one the credential cannot read, must not
                # abort the whole scan.
                Write-Warning "Skipped project '$projectName': $($_.Exception.Message)"
                continue
            }

            foreach ($pr in $raw) {
                $pullRequests.Add((ConvertTo-PullRequestInfo -PullRequest $pr -Organization $Organization -Now $now))
            }
            Write-Verbose "$projectName -> $($raw.Count) active pull request(s)."
        }

        Write-Progress -Activity 'Collecting active pull requests' -Completed

        $results = $pullRequests

        if ($ExcludeDrafts) {
            $results = @($results | Where-Object { -not $_.IsDraft })
        }
        if ($CreatedBy) {
            $results = @($results | Where-Object {
                    $_.CreatedBy -like "*$CreatedBy*" -or $_.CreatedByEmail -like "*$CreatedBy*"
                })
        }

        # Oldest first: age is what makes a stale pull request worth looking at.
        $results = @($results | Sort-Object -Property @{ Expression = 'AgeDays'; Descending = $true })

        $draftCount = @($results | Where-Object { $_.IsDraft }).Count
        Write-Verbose "$($results.Count) active pull request(s), $draftCount of them draft."

        switch ($Format) {
            'Table' { $results | Format-Table -AutoSize }
            'List'  { $results | Format-List }
            default { $results }
        }
    }
}

function Format-WiqlDate {
    <#
        .SYNOPSIS
            Renders a date as the UTC ISO 8601 literal a WIQL comparison expects.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory, Position = 0)]
        [datetime]$Value
    )

    # The 's' format is culture-invariant and second-precise; WIQL needs the trailing Z to read it
    # as UTC rather than as the caller's local time.
    return $Value.ToUniversalTime().ToString('s') + 'Z'
}

function ConvertTo-IdentityInfo {
    <#
        .SYNOPSIS
            Normalizes an Azure DevOps identity field to @{ DisplayName = ...; UniqueName = ... }.

        .DESCRIPTION
            Identity fields arrive as an IdentityRef object on current API versions and as a
            "Display Name <sign-in>" string on older ones, so both shapes are handled.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Position = 0)]
        $Value
    )

    if ($null -eq $Value) { return @{ DisplayName = ''; UniqueName = '' } }

    if ($Value -is [string]) {
        $text = ([string]$Value).Trim()
        if ($text -match '^(?<name>.*?)\s*<(?<mail>[^>]+)>$') {
            return @{ DisplayName = $Matches['name'].Trim(); UniqueName = $Matches['mail'].Trim() }
        }
        return @{ DisplayName = $text; UniqueName = '' }
    }

    return @{
        DisplayName = [string](Get-JsonProperty $Value 'displayName' '')
        UniqueName  = [string](Get-JsonProperty $Value 'uniqueName' '')
    }
}

function Get-AdoClosedWorkItemId {
    <#
        .SYNOPSIS
            Ids of the work items whose ClosedDate falls in [Since, Until).

        .DESCRIPTION
            Private helper. Closing a work item is what stamps Microsoft.VSTS.Common.ClosedDate, so
            querying that field covers Closed, Done and Completed alike without having to know which
            process template a project uses.

            The query is organization-wide and scopes itself with a System.TeamProject condition,
            because putting a project in the WIQL route does not restrict the result set: a query
            with no TeamProject condition answers with every project the credential can read, no
            matter which project the route names.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)]
        [hashtable]$Headers,

        [Parameter(Mandatory)]
        [string]$Organization,

        [Parameter(Mandatory)]
        [string]$ApiVersion,

        [Parameter(Mandatory)]
        [datetime]$Since,

        [Parameter(Mandatory)]
        [datetime]$Until,

        [string[]]$Project,

        [string[]]$WorkItemType
    )

    # timePrecision belongs in the query string, not the body - sent in the body it is ignored
    # and the query is then rejected for comparing a date field against a value carrying a time.
    $uri = 'https://dev.azure.com/{0}/_apis/wit/wiql?timePrecision=true&api-version={1}' -f
        [uri]::EscapeDataString($Organization), $ApiVersion

    $conditions = [System.Collections.Generic.List[string]]::new()
    $conditions.Add("[Microsoft.VSTS.Common.ClosedDate] >= '$(Format-WiqlDate $Since)'")
    $conditions.Add("[Microsoft.VSTS.Common.ClosedDate] < '$(Format-WiqlDate $Until)'")
    if ($Project) {
        $names = @($Project | ForEach-Object { "'" + ($_ -replace "'", "''") + "'" }) -join ', '
        $conditions.Add("[System.TeamProject] IN ($names)")
    }
    if ($WorkItemType) {
        $types = @($WorkItemType | ForEach-Object { "'" + ($_ -replace "'", "''") + "'" }) -join ', '
        $conditions.Add("[System.WorkItemType] IN ($types)")
    }

    $wiql = @{ query = 'SELECT [System.Id] FROM WorkItems WHERE ' + ($conditions -join ' AND ') }

    try {
        $result = Invoke-AdoApi -Uri $uri -Headers $Headers -Method Post -Body $wiql
    }
    catch {
        if ($_.Exception.Message -notmatch 'VS402337|exceeds the size limit') { throw }

        # VS402337: the range matched more than the 20000 work items a WIQL query will return.
        # Halving the window and asking twice keeps the count complete - passing $top instead
        # would truncate silently, which is the one thing a count must never do.
        $hours = ($Until - $Since).TotalHours
        if ($hours -le 24) {
            throw ("more than 20000 work items were closed on $($Since.ToString('yyyy-MM-dd')) alone, " +
                'which is more than a WIQL query returns. Narrow the scan with -Project or -WorkItemType.')
        }

        $middle = $Since.AddHours([math]::Floor($hours / 2))
        Write-Verbose "Over the WIQL result limit, splitting the window at $middle."

        Get-AdoClosedWorkItemId -Headers $Headers -Organization $Organization -ApiVersion $ApiVersion `
            -Since $Since -Until $middle -Project $Project -WorkItemType $WorkItemType
        Get-AdoClosedWorkItemId -Headers $Headers -Organization $Organization -ApiVersion $ApiVersion `
            -Since $middle -Until $Until -Project $Project -WorkItemType $WorkItemType
        return
    }

    foreach ($item in @(Get-JsonProperty $result.Data 'workItems')) {
        $id = Get-JsonProperty $item 'id'
        if ($null -ne $id) { [int]$id }
    }
}

function Get-AdoWorkItemDetail {
    <#
        .SYNOPSIS
            Fetches the requested fields for a list of work item ids, in batches.

        .DESCRIPTION
            Private helper. A WIQL query answers with ids only, and the batch endpoint accepts at
            most 200 of them per call, so the list is chunked. errorPolicy 'omit' makes an item the
            credential cannot read arrive as a null entry instead of failing the whole batch.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable]$Headers,

        [Parameter(Mandatory)]
        [string]$Organization,

        [Parameter(Mandatory)]
        [string]$ApiVersion,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [int[]]$Id,

        [Parameter(Mandatory)]
        [string[]]$Field,

        [ValidateRange(1, 200)]
        [int]$BatchSize = 200
    )

    if ($Id.Count -eq 0) { return }

    $uri = 'https://dev.azure.com/{0}/_apis/wit/workitemsbatch?api-version={1}' -f
        [uri]::EscapeDataString($Organization), $ApiVersion

    for ($offset = 0; $offset -lt $Id.Count; $offset += $BatchSize) {
        $last = [math]::Min($offset + $BatchSize, $Id.Count) - 1

        Write-Progress -Activity 'Reading closed work items' -Status "$($last + 1) of $($Id.Count)" `
            -PercentComplete (100 * ($last + 1) / $Id.Count)

        $body = @{
            ids         = @($Id[$offset..$last])
            fields      = $Field
            errorPolicy = 'omit'
        }

        $result = Invoke-AdoApi -Uri $uri -Headers $Headers -Method Post -Body $body

        foreach ($item in @(Get-JsonProperty $result.Data 'value')) {
            if ($null -ne $item) { $item }
        }
    }

    Write-Progress -Activity 'Reading closed work items' -Completed
}

function ConvertTo-ClosedWorkItemInfo {
    <#
        .SYNOPSIS
            Flattens one REST work item into a reporting object.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        $WorkItem,

        [Parameter(Mandatory)]
        [string]$Organization
    )

    $fields = Get-JsonProperty $WorkItem 'fields'
    $closedBy = ConvertTo-IdentityInfo (Get-JsonProperty $fields 'Microsoft.VSTS.Common.ClosedBy')
    $assignedTo = ConvertTo-IdentityInfo (Get-JsonProperty $fields 'System.AssignedTo')

    $id = Get-JsonProperty $WorkItem 'id'
    $projectName = [string](Get-JsonProperty $fields 'System.TeamProject' '')

    $webUrl = 'https://dev.azure.com/{0}/{1}/_workitems/edit/{2}' -f
        [uri]::EscapeDataString($Organization),
        [uri]::EscapeDataString($projectName),
        $id

    $info = [pscustomobject]@{
        Id              = $id
        Project         = $projectName
        WorkItemType    = [string](Get-JsonProperty $fields 'System.WorkItemType' '')
        Title           = [string](Get-JsonProperty $fields 'System.Title' '')
        State           = [string](Get-JsonProperty $fields 'System.State' '')
        ClosedBy        = $closedBy.DisplayName
        ClosedByEmail   = $closedBy.UniqueName
        ClosedDate      = ConvertTo-DateTimeValue (Get-JsonProperty $fields 'Microsoft.VSTS.Common.ClosedDate')
        AssignedTo      = $assignedTo.DisplayName
        AssignedToEmail = $assignedTo.UniqueName
        WebUrl          = $webUrl
    }

    $info.PSObject.TypeNames.Insert(0, 'AzureDevOps.ClosedWorkItem')
    return $info
}

function Get-AzureDevOpsClosedWorkItem {
    <#
        .SYNOPSIS
            Retrieves the work items closed in a period across an Azure DevOps organization.

        .DESCRIPTION
            Asks the organization for the work items whose Microsoft.VSTS.Common.ClosedDate falls in
            the requested window, then fetches the fields that say who closed each item and when.

            Closing a work item is what stamps ClosedDate, so the query covers Closed, Done and
            Completed alike without needing to know which process template a project uses.

            One organization-wide query covers every project the credential can read, so the whole
            organization costs a single WIQL call plus one read per 200 items found. Should a window
            match more than the 20000 work items WIQL will return, it is halved and re-queried until
            each part fits, which keeps the result complete rather than truncated.

            Authentication is resolved in this order:
              1. -PersonalAccessToken
              2. $env:AZURE_DEVOPS_EXT_PAT      (the Azure CLI devops extension PAT)
              3. $env:AZURE_DEVOPS_PAT
              4. $env:SYSTEM_ACCESSTOKEN        (OAuth token inside a pipeline)
              5. az account get-access-token    (an existing 'az login' session)

            Use Get-AzureDevOpsClosedWorkItemCount for the per-person totals; this cmdlet is the
            item-level detail behind them.

        .PARAMETER Organization
            Azure DevOps organization name. Default: astena

        .PARAMETER Project
            Limit the scan to these projects, by name. Omit to scan all of them. Applied inside the
            query rather than afterwards, so naming a project also makes the scan cheaper.

        .PARAMETER Days
            Size of the window ending now, in days. Default: 365. Ignored when -Since is used.

        .PARAMETER Since
            Start of the window, inclusive. Overrides -Days.

        .PARAMETER Until
            End of the window, exclusive. Default: now.

        .PARAMETER WorkItemType
            Only return these work item types, e.g. Bug, Task, 'User Story'.

        .PARAMETER ClosedBy
            Only return items whose closing user's display name or sign-in name contains this text.

        .PARAMETER PersonalAccessToken
            Azure DevOps PAT with the Work items (read) scope. Overrides every other credential source.

        .PARAMETER ApiVersion
            REST API version. Default: 7.1

        .PARAMETER BatchSize
            Work items fetched per detail request, 1-200. Default: 200

        .PARAMETER Format
            How to render the result.

            Object  Emit one object per work item (default). Fully pipeable.
            Table   Render as a table, equivalent to piping to Format-Table -AutoSize.
            List    Render as a list, one property per line, showing every property.

            Table and List produce display output rather than data: the result cannot be piped into
            Where-Object, Sort-Object or Export-Csv afterwards. Leave -Format off when you need to
            keep processing the result.

        .EXAMPLE
            Get-AzureDevOpsClosedWorkItem

            Every work item closed in the astena organization over the last year, newest first.

        .EXAMPLE
            Get-AzureDevOpsClosedWorkItem -Days 30 -WorkItemType Bug -Format Table

        .EXAMPLE
            Get-AzureDevOpsClosedWorkItem -ClosedBy 'Klemmensen' |
                Group-Object Project | Select-Object Name, Count

        .OUTPUTS
            AzureDevOps.ClosedWorkItem objects carrying Id, Project, WorkItemType, Title, State,
            ClosedBy, ClosedByEmail, ClosedDate, AssignedTo, AssignedToEmail and WebUrl.
            With -Format Table or -Format List, formatting objects for display instead.

        .NOTES
            Compatible with Windows PowerShell 5.1 and PowerShell 7+.
            A PAT needs only the "Work items (read)" scope.

            An item is in scope because it carries a ClosedDate inside the window. A work item
            moved back out of a closed state can keep that stamp, so State is reported on every
            item for anyone who needs to exclude those.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [ValidateNotNullOrEmpty()]
        [string]$Organization = 'astena',

        [string[]]$Project,

        [ValidateRange(1, 3650)]
        [int]$Days = 365,

        [Nullable[datetime]]$Since,

        [Nullable[datetime]]$Until,

        [string[]]$WorkItemType,

        [string]$ClosedBy,

        [string]$PersonalAccessToken,

        [ValidateNotNullOrEmpty()]
        [string]$ApiVersion = '7.1',

        [ValidateRange(1, 200)]
        [int]$BatchSize = 200,

        [ValidateSet('Object', 'Table', 'List')]
        [string]$Format = 'Object'
    )

    begin {
        Enable-Tls12
    }

    process {
        # A [Nullable[datetime]] parameter holds an unwrapped DateTime, so it is cast rather than
        # unwrapped with .Value - which does not exist on DateTime and would trip Set-StrictMode.
        $rangeEnd = if ($null -ne $Until) { [datetime]$Until } else { Get-Date }
        $rangeStart = if ($null -ne $Since) { [datetime]$Since } else { $rangeEnd.AddDays(-$Days) }

        if ($rangeStart -ge $rangeEnd) {
            throw "The requested window is empty: Since '$rangeStart' is not before Until '$rangeEnd'."
        }

        $auth = Resolve-AuthorizationHeader -PersonalAccessToken $PersonalAccessToken
        $restHeaders = @{
            Authorization = $auth.Value
            Accept        = 'application/json'
        }

        Write-Verbose "Organization '$Organization' - authenticating with $($auth.Source)."
        Write-Verbose "Window $($rangeStart.ToString('u')) .. $($rangeEnd.ToString('u'))."

        if ($Project) {
            Write-Verbose "Restricted to project(s): $($Project -join ', ')."
        }

        $fields = @(
            'System.TeamProject'
            'System.WorkItemType'
            'System.Title'
            'System.State'
            'System.AssignedTo'
            'Microsoft.VSTS.Common.ClosedDate'
            'Microsoft.VSTS.Common.ClosedBy'
        )

        $ids = @(Get-AdoClosedWorkItemId -Headers $restHeaders -Organization $Organization `
                -ApiVersion $ApiVersion -Since $rangeStart -Until $rangeEnd `
                -Project $Project -WorkItemType $WorkItemType)

        Write-Verbose "$($ids.Count) work item(s) closed in the window."

        $workItems = [System.Collections.Generic.List[object]]::new()
        foreach ($item in Get-AdoWorkItemDetail -Headers $restHeaders -Organization $Organization `
                -ApiVersion $ApiVersion -Id $ids -Field $fields -BatchSize $BatchSize) {
            $workItems.Add((ConvertTo-ClosedWorkItemInfo -WorkItem $item -Organization $Organization))
        }

        $results = $workItems

        if ($ClosedBy) {
            $results = @($results | Where-Object {
                    $_.ClosedBy -like "*$ClosedBy*" -or $_.ClosedByEmail -like "*$ClosedBy*"
                })
        }

        # Newest first: the recent closures are the ones being asked about.
        $results = @($results | Sort-Object -Property @{ Expression = 'ClosedDate'; Descending = $true })

        $unattributed = @($results | Where-Object { -not $_.ClosedBy -and -not $_.ClosedByEmail }).Count
        Write-Verbose "$($results.Count) closed work item(s), $unattributed of them without a ClosedBy value."

        switch ($Format) {
            'Table' { $results | Format-Table -AutoSize }
            'List'  { $results | Format-List }
            default { $results }
        }
    }
}

function Get-AzureDevOpsClosedWorkItemCount {
    <#
        .SYNOPSIS
            Counts the work items closed per person over a period, across an Azure DevOps organization.

        .DESCRIPTION
            Collects the work items closed in the requested window with
            Get-AzureDevOpsClosedWorkItem, then aggregates them by the person who closed each one -
            Microsoft.VSTS.Common.ClosedBy, not the assignee - and emits one row per person, busiest
            first. The default window is the last 365 days.

            People are matched on sign-in name where Azure DevOps supplies one and on display name
            otherwise, so a display name change does not split one person across two rows. Items
            with no ClosedBy value at all are grouped under '(unknown)' rather than dropped, so the
            counts still add up to the total.

            Authentication is resolved in this order:
              1. -PersonalAccessToken
              2. $env:AZURE_DEVOPS_EXT_PAT      (the Azure CLI devops extension PAT)
              3. $env:AZURE_DEVOPS_PAT
              4. $env:SYSTEM_ACCESSTOKEN        (OAuth token inside a pipeline)
              5. az account get-access-token    (an existing 'az login' session)

        .PARAMETER Organization
            Azure DevOps organization name. Default: astena

        .PARAMETER Project
            Limit the scan to these projects, by name. Omit to scan all of them. Applied inside the
            query rather than afterwards, so naming a project also makes the scan cheaper.

        .PARAMETER Days
            Size of the window ending now, in days. Default: 365, the last year. Ignored when
            -Since is used.

        .PARAMETER Since
            Start of the window, inclusive. Overrides -Days.

        .PARAMETER Until
            End of the window, exclusive. Default: now.

        .PARAMETER WorkItemType
            Only count these work item types, e.g. Bug, Task, 'User Story'.

        .PARAMETER ClosedBy
            Only count items whose closing user's display name or sign-in name contains this text.

        .PARAMETER PersonalAccessToken
            Azure DevOps PAT with the Work items (read) scope. Overrides every other credential source.

        .PARAMETER ApiVersion
            REST API version. Default: 7.1

        .PARAMETER Format
            How to render the result.

            Object  Emit one object per person (default). Fully pipeable.
            Table   Render as a table, equivalent to piping to Format-Table -AutoSize.
            List    Render as a list, one property per line, showing every property.

            Table and List produce display output rather than data: the result cannot be piped into
            Where-Object, Sort-Object or Export-Csv afterwards.

        .EXAMPLE
            Get-AzureDevOpsClosedWorkItemCount

            Work items closed per person over the last year in the astena organization, busiest first.

        .EXAMPLE
            Get-AzureDevOpsClosedWorkItemCount -Format Table

        .EXAMPLE
            Get-AzureDevOpsClosedWorkItemCount -Days 90 -WorkItemType Bug, Task

            Bugs and tasks closed per person over the last quarter.

        .EXAMPLE
            Get-AzureDevOpsClosedWorkItemCount -Since '2025-01-01' -Until '2026-01-01' |
                Export-Csv .\closed-2025.csv -NoTypeInformation

            A calendar-year report, written to CSV.

        .EXAMPLE
            Get-AzureDevOpsClosedWorkItemCount -Project 'Business Central' |
                Select-Object -First 10 ClosedBy, ClosedCount, WorkItemTypes

        .OUTPUTS
            AzureDevOps.ClosedWorkItemCount objects carrying ClosedBy, ClosedByEmail, ClosedCount,
            Percent, ProjectCount, Projects, WorkItemTypes, FirstClosed and LastClosed.
            With -Format Table or -Format List, formatting objects for display instead.

        .NOTES
            Compatible with Windows PowerShell 5.1 and PowerShell 7+.
            A PAT needs only the "Work items (read)" scope.

            The count is of who moved an item into a closed state, which is not always who did the
            work: a lead closing a batch of items shows up as the closer of all of them. And an
            item is in scope because it carries a ClosedDate inside the window - a work item moved
            back out of a closed state can keep that stamp, so a handful of rows may count items
            that are open again today. Get-AzureDevOpsClosedWorkItem reports State per item when
            that distinction matters.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [ValidateNotNullOrEmpty()]
        [string]$Organization = 'astena',

        [string[]]$Project,

        [ValidateRange(1, 3650)]
        [int]$Days = 365,

        [Nullable[datetime]]$Since,

        [Nullable[datetime]]$Until,

        [string[]]$WorkItemType,

        [string]$ClosedBy,

        [string]$PersonalAccessToken,

        [ValidateNotNullOrEmpty()]
        [string]$ApiVersion = '7.1',

        [ValidateSet('Object', 'Table', 'List')]
        [string]$Format = 'Object'
    )

    process {
        $items = @(Get-AzureDevOpsClosedWorkItem -Organization $Organization -Project $Project `
                -Days $Days -Since $Since -Until $Until -WorkItemType $WorkItemType `
                -ClosedBy $ClosedBy -PersonalAccessToken $PersonalAccessToken -ApiVersion $ApiVersion)

        $total = $items.Count
        if ($total -eq 0) {
            Write-Verbose 'No closed work items in the requested window.'
            return
        }

        # Group on the sign-in name where there is one: a display name change would otherwise split
        # one person across two rows.
        $groups = $items | Group-Object -Property {
            if ($_.ClosedByEmail) { $_.ClosedByEmail.ToLowerInvariant() }
            elseif ($_.ClosedBy) { $_.ClosedBy.ToLowerInvariant() }
            else { '' }
        }

        $summaries = [System.Collections.Generic.List[object]]::new()

        foreach ($group in $groups) {
            $members = @($group.Group)
            $dates = @($members | ForEach-Object { $_.ClosedDate } | Where-Object { $null -ne $_ } | Sort-Object)
            $projects = @($members | ForEach-Object { $_.Project } | Where-Object { $_ } | Sort-Object -Unique)

            $names = @($members | ForEach-Object { $_.ClosedBy } | Where-Object { $_ })
            $emails = @($members | ForEach-Object { $_.ClosedByEmail } | Where-Object { $_ })

            $types = @($members | Group-Object -Property WorkItemType |
                    Sort-Object -Property @{ Expression = 'Count'; Descending = $true }, 'Name' |
                    ForEach-Object { "$($_.Name)=$($_.Count)" }) -join ', '

            $summary = [pscustomobject]@{
                ClosedBy      = if ($names.Count) { [string]$names[0] } else { '(unknown)' }
                ClosedByEmail = if ($emails.Count) { [string]$emails[0] } else { '' }
                ClosedCount   = $members.Count
                Percent       = [math]::Round(100 * $members.Count / $total, 1)
                ProjectCount  = $projects.Count
                Projects      = ($projects -join ', ')
                WorkItemTypes = $types
                FirstClosed   = if ($dates.Count) { $dates[0] } else { $null }
                LastClosed    = if ($dates.Count) { $dates[$dates.Count - 1] } else { $null }
            }

            $summary.PSObject.TypeNames.Insert(0, 'AzureDevOps.ClosedWorkItemCount')
            $summaries.Add($summary)
        }

        # Busiest first, then by name so equal counts come out in a stable order.
        $results = @($summaries | Sort-Object -Property @{ Expression = 'ClosedCount'; Descending = $true }, 'ClosedBy')

        Write-Verbose "$total closed work item(s) across $($results.Count) person(s)."

        switch ($Format) {
            'Table' { $results | Format-Table -AutoSize }
            'List'  { $results | Format-List }
            default { $results }
        }
    }
}

Export-ModuleMember -Function @(
    'Get-AzureDevOpsPullRequest'
    'Get-AzureDevOpsClosedWorkItem'
    'Get-AzureDevOpsClosedWorkItemCount'
)
