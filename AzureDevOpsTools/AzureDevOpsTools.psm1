#Requires -Version 5.1

Set-StrictMode -Version Latest

# Resource id of the Azure DevOps first-party app, used when asking the Azure CLI for an
# access token.
$script:AdoResourceId = '499b84ac-1321-427f-aa17-267ca6975798'

# The default view: identification, age, and the browser link to open the pull request.
# Everything else stays on the object for Select-Object/Export-Csv.
Update-TypeData -TypeName 'AzureDevOps.ActivePullRequest' -Force `
    -DefaultDisplayPropertySet Id, Project, Repository, Title, CreatedBy, AgeDays, IsDraft, WebUrl

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
        "  * Get-AzureDevOpsPullRequest -PersonalAccessToken '<pat>'`n" +
        'A PAT needs the "Code (read)" scope.')
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
            GETs a REST endpoint and returns @{ Data = <parsed json>; Headers = ... }.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [string]$Uri,

        [Parameter(Mandatory)]
        [hashtable]$Headers
    )

    Write-Verbose "GET $Uri"

    try {
        $response = Invoke-WebRequest -Uri $Uri -Headers $Headers -Method Get -UseBasicParsing -ErrorAction Stop
    }
    catch {
        $status = $null
        $webResponse = Get-JsonProperty $_.Exception 'Response'
        if ($null -ne $webResponse) {
            $code = Get-JsonProperty $webResponse 'StatusCode'
            if ($null -ne $code) { $status = [int]$code }
        }

        switch ($status) {
            401 { throw "Azure DevOps rejected the credential (401). Re-run 'az login' or supply a PAT with the Code (read) scope." }
            403 { throw "The credential is valid but lacks permission for '$Uri' (403)." }
            404 { throw "Not found: $Uri (404). Check the organization and project names." }
            default { throw "Request to '$Uri' failed: $($_.Exception.Message)" }
        }
    }

    $text = $response.Content
    if ($text -is [byte[]]) { $text = [System.Text.Encoding]::UTF8.GetString($text) }

    # An unauthenticated browser-style request is answered with a sign-in page carrying HTTP 200,
    # so a leading '<' means the credential never took.
    if ($text -match '^\s*<') {
        throw 'Azure DevOps returned an HTML sign-in page instead of JSON - the credential was not accepted. Re-run with a PAT that has the Code (read) scope.'
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

Export-ModuleMember -Function 'Get-AzureDevOpsPullRequest'
