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
        $repoArgs = @('repo', 'list', $org, '--limit', $Limit, '--json', 'nameWithOwner', '-q', '.[].nameWithOwner')
        if (-not $IncludeArchived) { $repoArgs += '--no-archived' }

        $repos = @(gh @repoArgs)
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to list repositories for organization '$org'. Check the name and your 'gh' permissions."
        }

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
                $runs = $json | ConvertFrom-Json

                if ($runs.total_count -eq 0) {
                    $status = 'never run'
                    $branch = ''
                    $when   = $null
                }
                else {
                    $run    = $runs.workflow_runs[0]
                    $status = if ($run.conclusion) { $run.conclusion } else { $run.status }
                    $branch = $run.head_branch
                    $when   = $run.updated_at -as [datetime]
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

Export-ModuleMember -Function Get-GitHubWorkflowStatus
