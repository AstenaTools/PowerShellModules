#Requires -Version 5.1

Set-StrictMode -Version Latest

function Assert-GhCli {
    <#
        .SYNOPSIS
            Throws if the GitHub CLI is missing or not authenticated.
    #>
    [CmdletBinding()]
    param()

    if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
        throw "The GitHub CLI ('gh') was not found on PATH. Install it from https://cli.github.com/ and run 'gh auth login'."
    }

    gh auth status *> $null
    if ($LASTEXITCODE -ne 0) {
        throw "The GitHub CLI is not authenticated. Run 'gh auth login' and try again."
    }
}

function Get-JsonProperty {
    <#
        .SYNOPSIS
            Reads a property from a ConvertFrom-Json object, returning a default when it is absent.

        .DESCRIPTION
            Set-StrictMode -Version Latest turns a reference to a missing property into a terminating
            error, and the shape of GitHub's JSON varies between endpoints and gh versions. This reads
            through the PSObject property bag instead, so an absent property yields the default.
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

function Get-GitHubRepositoryName {
    <#
        .SYNOPSIS
            Returns the 'owner/name' of every repository in an organization.

        .DESCRIPTION
            Private helper shared by the public functions. Callers should wrap the result in @() —
            an organization with no matching repositories emits nothing at all.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string]$Organization,

        [int]$Limit = 500,

        [switch]$IncludeArchived
    )

    $repoArgs = @(
        'repo', 'list', $Organization,
        '--limit', $Limit,
        '--json', 'nameWithOwner',
        '-q', '.[].nameWithOwner'
    )
    if (-not $IncludeArchived) { $repoArgs += '--no-archived' }

    Write-Verbose "gh $($repoArgs -join ' ')"

    $names = @(gh @repoArgs)
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to list repositories for organization '$Organization'. Check the name and your 'gh' permissions."
    }

    # Filter blanks so a trailing newline from gh cannot become a phantom repository.
    $names | Where-Object { $_ -and $_.Trim() }
}

function Get-GitHubWorkflowStatus {
    <#
        .SYNOPSIS
            Reports the most recent run of a given workflow across every repository in an organization.

        .DESCRIPTION
            Lists the non-archived repositories of an organization via the GitHub CLI and, for each one,
            queries the latest run of the named workflow.

            By default one object per repository is emitted, so the result can be sorted, filtered,
            exported or formatted by the caller. Use -Format to have the function render a ready-made
            table or list instead.

            Repositories where the workflow does not exist are reported with a status of "not found";
            repositories where it exists but has never run are reported as "never run".

        .PARAMETER wf
            The workflow file name or ID, e.g. 'ci.yml' or 'Generic_Build.yml'.

        .PARAMETER org
            The GitHub organization (or user) whose repositories are inspected.

        .PARAMETER Format
            How to render the result.

            Object  Emit one object per repository (default). Fully pipeable.
            Table   Render as a table, equivalent to piping to Format-Table -AutoSize.
            List    Render as a list, one property per line, equivalent to piping to Format-List.

            Table and List produce display output rather than data: the result cannot be piped into
            Where-Object, Sort-Object or Export-Csv afterwards. Leave -Format off when you need to
            keep processing the result.

        .PARAMETER Limit
            Maximum number of repositories to retrieve. Defaults to 500.

        .PARAMETER IncludeArchived
            Include archived repositories, which are excluded by default.

        .EXAMPLE
            Get-GitHubWorkflowStatus -wf 'ci.yml' -org 'OxygenTools' -Format Table

            Print a compact table of every repository and the outcome of its latest 'ci.yml' run.

        .EXAMPLE
            Get-GitHubWorkflowStatus -wf 'ci.yml' -org 'OxygenTools' -Format List

            Print the same information vertically, one property per line.

        .EXAMPLE
            Get-GitHubWorkflowStatus -wf 'Generic_Build.yml' -org 'OxygenTools' |
                Where-Object Status -eq 'failure' |
                Sort-Object When -Descending

            Omit -Format to keep the objects pipeable, and report only the failing builds.

        .EXAMPLE
            Get-GitHubWorkflowStatus -wf 'ci.yml' -org 'OxygenTools' |
                Export-Csv .\workflow-status.csv -NoTypeInformation

        .OUTPUTS
            PSCustomObject with the properties Repo, Workflow, Status, Branch and When.
            With -Format Table or -Format List, formatting objects for display instead.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string]$wf,

        [Parameter(Mandatory, Position = 1)]
        [ValidateNotNullOrEmpty()]
        [string]$org,

        [ValidateSet('Object', 'Table', 'List')]
        [string]$Format = 'Object',

        [ValidateRange(1, 1000)]
        [int]$Limit = 500,

        [switch]$IncludeArchived
    )

    begin {
        Assert-GhCli

        # -AutoSize needs every row before it can size the columns, so formatted output is
        # buffered. Plain object output stays streaming, which matters over 500 repositories.
        # Assign in two steps: '$buffer = if (...) { [List[object]]::new() }' would send the
        # empty list through the output stream, which enumerates it away to $null.
        $buffer = $null
        if ($Format -ne 'Object') {
            $buffer = [System.Collections.Generic.List[object]]::new()
        }
    }

    process {
        $repos = @(Get-GitHubRepositoryName -Organization $org -Limit $Limit -IncludeArchived:$IncludeArchived)
        Write-Verbose "Found $($repos.Count) repositories in '$org'."

        $i = 0
        foreach ($repo in $repos) {
            $i++
            Write-Progress -Activity "Checking '$wf'" -Status $repo -PercentComplete ($i / [Math]::Max($repos.Count, 1) * 100)

            $json = (gh api "repos/$repo/actions/workflows/$wf/runs?per_page=1" 2>$null) -join "`n"

            if ($LASTEXITCODE -ne 0 -or -not $json) {
                $status = 'not found'
                $branch = ''
                $when   = $null
            }
            else {
                $runs = $null
                try { $runs = $json | ConvertFrom-Json } catch { }

                # Read through Get-JsonProperty: under Set-StrictMode -Version Latest a missing
                # property is a terminating error, and a non-JSON body would take out the whole run.
                $workflowRuns = @(Get-JsonProperty $runs 'workflow_runs' @())

                if ($workflowRuns.Count -eq 0) {
                    $status = 'never run'
                    $branch = ''
                    $when   = $null
                }
                else {
                    $run    = $workflowRuns[0]
                    $status = Get-JsonProperty $run 'conclusion'
                    if (-not $status) { $status = Get-JsonProperty $run 'status' 'unknown' }
                    $branch = Get-JsonProperty $run 'head_branch' ''
                    $when   = Get-JsonProperty $run 'updated_at'
                    $when   = if ($when) { $when -as [datetime] } else { $null }
                }
            }

            $record = [pscustomobject]@{
                Repo     = $repo
                Workflow = $wf
                Status   = $status
                Branch   = $branch
                When     = $when
            }

            if ($null -eq $buffer) { $record } else { $buffer.Add($record) }
        }

        Write-Progress -Activity "Checking '$wf'" -Completed
    }

    end {
        if ($null -eq $buffer) { return }

        switch ($Format) {
            'Table' { $buffer | Format-Table -AutoSize }
            'List'  { $buffer | Format-List }
        }
    }
}

function Get-GitHubPullRequest {
    <#
        .SYNOPSIS
            Lists pull requests across every repository in a GitHub organization.

        .DESCRIPTION
            Queries the GitHub search API through the GitHub CLI to return the pull requests of an
            organization in a single round trip, rather than walking each repository in turn.

            By default only open pull requests are returned, newest-updated first. Use -State to widen
            that, and -Author, -Label or -Repository to narrow it.

            One object per pull request is emitted so the result can be sorted, filtered and exported.
            Use -Format to have the function render a ready-made table or list instead.

        .PARAMETER org
            The GitHub organization (or user) whose pull requests are listed.

        .PARAMETER State
            Which pull requests to return.

            Open    Only open pull requests (default).
            Closed  Only closed pull requests, whether merged or not.
            Merged  Only merged pull requests.
            All     Open and closed alike.

        .PARAMETER Repository
            Restrict the search to one repository, given as 'owner/name'.

        .PARAMETER Author
            Restrict the search to pull requests opened by this GitHub login.

        .PARAMETER Label
            Restrict the search to pull requests carrying all of these labels.

        .PARAMETER ExcludeDrafts
            Omit draft pull requests.

        .PARAMETER Limit
            Maximum number of pull requests to return. Defaults to 100, and the GitHub search API
            caps this at 1000. A warning is written when the result reaches the limit, because the
            list is then almost certainly truncated — narrow the search or raise -Limit.

        .PARAMETER Format
            How to render the result.

            Object  Emit one object per pull request (default). Fully pipeable.
            Table   Render as a table of the most useful columns, omitting Labels and Url for width.
            List    Render as a list, one property per line, showing every property.

            Table and List produce display output rather than data: the result cannot be piped into
            Where-Object, Sort-Object or Export-Csv afterwards. Leave -Format off when you need to
            keep processing the result.

        .EXAMPLE
            Get-GitHubPullRequest -org 'OxygenTools' -Format Table

            Every open pull request in the organization, as a table.

        .EXAMPLE
            Get-GitHubPullRequest -org 'OxygenTools' -ExcludeDrafts |
                Where-Object AgeDays -gt 14 |
                Sort-Object AgeDays -Descending

            Ready-for-review pull requests that have been open longer than two weeks.

        .EXAMPLE
            Get-GitHubPullRequest -org 'OxygenTools' -State Merged -Limit 500 |
                Group-Object Author |
                Sort-Object Count -Descending

            Who merged the most pull requests.

        .EXAMPLE
            Get-GitHubPullRequest -org 'OxygenTools' |
                Export-Csv .\open-prs.csv -NoTypeInformation

        .OUTPUTS
            PSCustomObject with the properties Repo, Number, Title, Author, State, Draft, AgeDays,
            Created, Updated, Comments, Labels and Url.
            With -Format Table or -Format List, formatting objects for display instead.

        .LINK
            Get-GitHubWorkflowStatus
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string]$org,

        [ValidateSet('Open', 'Closed', 'Merged', 'All')]
        [string]$State = 'Open',

        [ValidateNotNullOrEmpty()]
        [string]$Repository,

        [ValidateNotNullOrEmpty()]
        [string]$Author,

        [string[]]$Label,

        [switch]$ExcludeDrafts,

        [ValidateRange(1, 1000)]
        [int]$Limit = 100,

        [ValidateSet('Object', 'Table', 'List')]
        [string]$Format = 'Object'
    )

    begin {
        Assert-GhCli
    }

    process {
        $fields = @(
            'number', 'title', 'repository', 'author', 'state', 'isDraft',
            'createdAt', 'updatedAt', 'url', 'labels', 'commentsCount'
        )

        $searchArgs = @(
            'search', 'prs',
            '--owner', $org,
            '--limit', $Limit,
            '--sort', 'updated',
            '--order', 'desc',
            '--json', ($fields -join ',')
        )

        switch ($State) {
            'Open'   { $searchArgs += @('--state', 'open') }
            'Closed' { $searchArgs += @('--state', 'closed') }
            'Merged' { $searchArgs += '--merged' }
            'All'    { }
        }

        if ($Repository)    { $searchArgs += @('--repo', $Repository) }
        if ($Author)        { $searchArgs += @('--author', $Author) }
        if ($ExcludeDrafts) { $searchArgs += '--draft=false' }

        foreach ($name in $Label) {
            $searchArgs += @('--label', $name)
        }

        $command = "gh $($searchArgs -join ' ')"
        Write-Verbose $command

        $raw        = $null
        $exitCode   = 0
        $stderr     = ''
        $stderrFile = [IO.Path]::GetTempFileName()

        try {
            # stderr goes to a file rather than being merged in with 2>&1. gh writes update
            # notices and auth warnings to stderr, and merging those into stdout corrupts the
            # JSON payload.
            $raw = & gh @searchArgs 2>$stderrFile
            $exitCode = $LASTEXITCODE
            $stderr = (Get-Content -LiteralPath $stderrFile -Raw -ErrorAction SilentlyContinue)
        }
        finally {
            Remove-Item -LiteralPath $stderrFile -Force -ErrorAction SilentlyContinue
        }

        if ($exitCode -ne 0) {
            throw "gh exited with code $exitCode while searching pull requests in '$org'. Check the organization name and your 'gh' permissions.`nCommand: $command`n$stderr"
        }

        $output = ($raw -join "`n").Trim()

        if ($stderr) { Write-Verbose "gh stderr: $stderr" }

        # Report an unusable response instead of quietly treating it as an empty result set.
        if (-not $output) {
            throw "gh returned no output while searching pull requests in '$org'.`nCommand: $command`n$stderr"
        }

        try {
            $parsed = $output | ConvertFrom-Json
        }
        catch {
            $snippet = if ($output.Length -gt 400) { $output.Substring(0, 400) + '...' } else { $output }
            throw "gh returned output that is not valid JSON while searching pull requests in '$org'.`nCommand: $command`nOutput: $snippet`n$stderr"
        }

        # ConvertFrom-Json yields $null for a 'null' payload, and @($null) is a ONE-element
        # array, which would surface as a row of empty properties. Drop those entries so an
        # empty result set really is empty.
        $found = @($parsed | Where-Object { $null -ne $_ })
        Write-Verbose "Found $($found.Count) pull request(s) in '$org'."

        if ($found.Count -ge $Limit) {
            Write-Warning "The result reached the -Limit of $Limit and is probably truncated. Narrow the search or raise -Limit (max 1000)."
        }

        # Formatted output is buffered so -AutoSize can size its columns; see the note in
        # Get-GitHubWorkflowStatus. Object output stays streaming.
        $buffer = $null
        if ($Format -ne 'Object') {
            $buffer = [System.Collections.Generic.List[object]]::new()
        }

        $now = Get-Date

        foreach ($pr in $found) {
            $repo = Get-JsonProperty $pr 'repository'
            $repoName = Get-JsonProperty $repo 'nameWithOwner'
            if (-not $repoName) {
                # Older gh versions return only the bare name on this endpoint.
                $repoName = Get-JsonProperty $repo 'name' ''
            }

            $created = Get-JsonProperty $pr 'createdAt'
            $created = if ($created) { $created -as [datetime] } else { $null }

            $updated = Get-JsonProperty $pr 'updatedAt'
            $updated = if ($updated) { $updated -as [datetime] } else { $null }

            $labels = @(Get-JsonProperty $pr 'labels' @() | ForEach-Object { Get-JsonProperty $_ 'name' })

            $record = [pscustomobject]@{
                Repo     = $repoName
                Number   = Get-JsonProperty $pr 'number'
                Title    = Get-JsonProperty $pr 'title' ''
                Author   = Get-JsonProperty (Get-JsonProperty $pr 'author') 'login' ''
                State    = Get-JsonProperty $pr 'state' ''
                Draft    = [bool](Get-JsonProperty $pr 'isDraft' $false)
                AgeDays  = if ($created) { [int][Math]::Round(($now - $created).TotalDays) } else { $null }
                Created  = $created
                Updated  = $updated
                Comments = Get-JsonProperty $pr 'commentsCount' 0
                Labels   = ($labels -join ', ')
                Url      = Get-JsonProperty $pr 'url' ''
            }

            if ($null -eq $buffer) { $record } else { $buffer.Add($record) }
        }

        if ($null -eq $buffer) { return }

        switch ($Format) {
            'Table' {
                $buffer | Format-Table -Property Repo, Number, Title, Author, State, Draft, AgeDays, Updated -AutoSize
            }
            'List' {
                $buffer | Format-List
            }
        }
    }
}

function Invoke-GitHubWorkflow {
    <#
        .SYNOPSIS
            Runs a workflow in every repository of an organization that has it.

        .DESCRIPTION
            Walks the repositories of an organization, checks whether the named workflow exists and is
            active, and dispatches it where it does. Repositories without the workflow are skipped
            rather than treated as failures.

            No workflow inputs are supplied, so every input takes the default value declared in the
            workflow YAML. A workflow with a required input that has no default cannot be dispatched
            this way and is reported as Failed with the reason returned by GitHub.

            This function CHANGES STATE — it starts real CI runs, potentially hundreds of them — so it
            supports -WhatIf and prompts for confirmation by default. Use -WhatIf first to see the
            target list, and -Force to dispatch without prompting.

            The workflow must declare a 'workflow_dispatch' trigger, otherwise GitHub refuses the
            dispatch and the repository is reported as Failed.

        .PARAMETER wf
            The workflow file name or ID to run, e.g. 'ci.yml'. Aliased as -Workflow.

        .PARAMETER org
            The GitHub organization (or user) whose repositories are targeted. Aliased as -Organization.

        .PARAMETER Ref
            The branch or tag to run the workflow on. Defaults to each repository's own default branch,
            which is usually what you want across an organization where branch names differ.

        .PARAMETER Repository
            Only consider these repositories, given as 'owner/name'. Useful for a trial run against
            one or two repositories before dispatching to the whole organization.

        .PARAMETER Limit
            Maximum number of repositories to enumerate. Defaults to 500.

        .PARAMETER IncludeArchived
            Include archived repositories, which are excluded by default. Archived repositories cannot
            run workflows, so this is rarely useful.

        .PARAMETER DelayMilliseconds
            Pause between dispatches, 200 ms by default. GitHub applies secondary rate limits to
            write operations, and dispatching to a few hundred repositories without a pause can trip
            them. Set to 0 to disable.

        .PARAMETER Force
            Dispatch without prompting for confirmation. Equivalent to -Confirm:$false.

        .PARAMETER Format
            How to render the result.

            Object  Emit one object per repository (default). Fully pipeable.
            Table   Render as a table, equivalent to piping to Format-Table -AutoSize.
            List    Render as a list, one property per line.

            Table and List produce display output rather than data: the result cannot be piped into
            Where-Object, Sort-Object or Export-Csv afterwards.

        .EXAMPLE
            Invoke-GitHubWorkflow -wf 'ci.yml' -org 'OxygenTools' -WhatIf

            Show which repositories would have 'ci.yml' dispatched, without starting anything.
            Always worth running first.

        .EXAMPLE
            Invoke-GitHubWorkflow -wf 'ci.yml' -org 'OxygenTools' -Format Table

            Dispatch after confirming, and print the outcome per repository.

        .EXAMPLE
            Invoke-GitHubWorkflow -wf 'ci.yml' -org 'OxygenTools' -Repository 'OxygenTools/AppA' -Force

            Trial run against a single repository with no prompt.

        .EXAMPLE
            Invoke-GitHubWorkflow -wf 'ci.yml' -org 'OxygenTools' -Force |
                Where-Object Action -eq 'Failed'

            Dispatch everywhere and report only the repositories that refused.

        .OUTPUTS
            PSCustomObject with the properties Repo, Workflow, Action, Ref and Reason.
            Action is one of Dispatched, Skipped, Failed or WhatIf.

        .LINK
            Get-GitHubWorkflowStatus
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [Alias('Workflow')]
        [string]$wf,

        [Parameter(Mandatory, Position = 1)]
        [ValidateNotNullOrEmpty()]
        [Alias('Organization')]
        [string]$org,

        [ValidateNotNullOrEmpty()]
        [Alias('Branch')]
        [string]$Ref,

        [string[]]$Repository,

        [ValidateRange(1, 1000)]
        [int]$Limit = 500,

        [switch]$IncludeArchived,

        [ValidateRange(0, 60000)]
        [int]$DelayMilliseconds = 200,

        [switch]$Force,

        [ValidateSet('Object', 'Table', 'List')]
        [string]$Format = 'Object'
    )

    begin {
        Assert-GhCli

        # -Force implies -Confirm:$false, but never overrides an explicit -Confirm.
        if ($Force -and -not $PSBoundParameters.ContainsKey('Confirm')) {
            $ConfirmPreference = 'None'
        }

        $buffer = $null
        if ($Format -ne 'Object') {
            $buffer = [System.Collections.Generic.List[object]]::new()
        }
    }

    process {
        if ($Repository) {
            $repos = @($Repository)
            Write-Verbose "Targeting $($repos.Count) explicitly named repositories."
        }
        else {
            $repos = @(Get-GitHubRepositoryName -Organization $org -Limit $Limit -IncludeArchived:$IncludeArchived)
            Write-Verbose "Found $($repos.Count) repositories in '$org'."
        }

        if ($repos.Count -eq 0) {
            Write-Warning "No repositories found for organization '$org'."
            return
        }

        $i = 0
        foreach ($repo in $repos) {
            $i++
            Write-Progress -Activity "Dispatching '$wf'" -Status $repo -PercentComplete ($i / [Math]::Max($repos.Count, 1) * 100)

            $action = 'Skipped'
            $reason = ''

            # Look the workflow up first, so a repository that simply does not have it is skipped
            # quietly instead of counting as a failure.
            $lookup = (gh api "repos/$repo/actions/workflows/$wf" 2>$null) -join "`n"

            if ($LASTEXITCODE -ne 0 -or -not $lookup) {
                $reason = "workflow '$wf' not found"
            }
            else {
                $definition = $null
                try { $definition = $lookup | ConvertFrom-Json } catch { }

                $state = Get-JsonProperty $definition 'state' ''

                if (-not $state) {
                    $reason = 'could not read the workflow definition'
                }
                elseif ($state -ne 'active') {
                    # A disabled workflow accepts no dispatch; saying so beats a raw API error.
                    $reason = "workflow is '$state', not active"
                }
                elseif (-not $PSCmdlet.ShouldProcess($repo, "Run workflow '$wf'$(if ($Ref) { " on ref '$Ref'" })")) {
                    $action = 'WhatIf'
                    $reason = 'not dispatched'
                }
                else {
                    $runArgs = @('workflow', 'run', $wf, '--repo', $repo)
                    if ($Ref) { $runArgs += @('--ref', $Ref) }

                    # '--json' with an empty object on stdin keeps gh non-interactive: without it gh
                    # prompts for any declared input, which would hang a run across many repositories.
                    # An empty object also means every input keeps its declared default.
                    $runArgs += '--json'

                    Write-Verbose "gh $($runArgs -join ' ')"

                    $stderr     = ''
                    $exitCode   = 0
                    $stderrFile = [IO.Path]::GetTempFileName()

                    try {
                        '{}' | & gh @runArgs 2>$stderrFile | Out-Null
                        $exitCode = $LASTEXITCODE
                        $stderr = (Get-Content -LiteralPath $stderrFile -Raw -ErrorAction SilentlyContinue)
                    }
                    finally {
                        Remove-Item -LiteralPath $stderrFile -Force -ErrorAction SilentlyContinue
                    }

                    if ($exitCode -eq 0) {
                        $action = 'Dispatched'
                        $reason = ''
                    }
                    else {
                        $action = 'Failed'
                        $reason = if ($stderr) {
                            (($stderr -split "`r?`n") | Where-Object { $_.Trim() } | Select-Object -First 1).Trim()
                        }
                        else {
                            "gh exited with code $exitCode"
                        }
                    }

                    if ($DelayMilliseconds -gt 0) {
                        Start-Sleep -Milliseconds $DelayMilliseconds
                    }
                }
            }

            $record = [pscustomobject]@{
                Repo     = $repo
                Workflow = $wf
                Action   = $action
                Ref      = if ($Ref) { $Ref } else { '(default branch)' }
                Reason   = $reason
            }

            if ($null -eq $buffer) { $record } else { $buffer.Add($record) }
        }

        Write-Progress -Activity "Dispatching '$wf'" -Completed
    }

    end {
        if ($null -eq $buffer) { return }

        switch ($Format) {
            'Table' { $buffer | Format-Table -AutoSize }
            'List'  { $buffer | Format-List }
        }
    }
}

Export-ModuleMember -Function 'Get-GitHubWorkflowStatus', 'Get-GitHubPullRequest', 'Invoke-GitHubWorkflow'
