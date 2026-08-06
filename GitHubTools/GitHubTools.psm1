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
            queries the latest run of the named workflow. Emits one object per repository so the result
            can be sorted, filtered, exported or formatted by the caller.

            Repositories where the workflow does not exist are reported with a status of "not found";
            repositories where it exists but has never run are reported as "never run".

        .PARAMETER wf
            The workflow file name or ID, e.g. 'ci.yml' or 'Generic_Build.yml'.

        .PARAMETER org
            The GitHub organization (or user) whose repositories are inspected.

        .PARAMETER Limit
            Maximum number of repositories to retrieve. Defaults to 500.

        .PARAMETER IncludeArchived
            Include archived repositories, which are excluded by default.

        .EXAMPLE
            Get-GitHubWorkflowStatus -wf 'ci.yml' -org 'AstenaAcademy' | Format-Table -AutoSize

        .EXAMPLE
            Get-GitHubWorkflowStatus -wf 'Generic_Build.yml' -org 'AstenaAcademy' |
                Where-Object Status -eq 'failure'

            Show only the repositories whose latest build failed.

        .OUTPUTS
            PSCustomObject with the properties Repo, Workflow, Status, Branch and When.
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

        [ValidateRange(1, 1000)]
        [int]$Limit = 500,

        [switch]$IncludeArchived
    )

    begin {
        Assert-GhCli
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
                [pscustomobject]@{
                    Repo     = $repo
                    Workflow = $wf
                    Status   = 'not found'
                    Branch   = ''
                    When     = $null
                }
                continue
            }

            $runs = $json | ConvertFrom-Json
            if ($runs.total_count -eq 0) {
                [pscustomobject]@{
                    Repo     = $repo
                    Workflow = $wf
                    Status   = 'never run'
                    Branch   = ''
                    When     = $null
                }
                continue
            }

            $run = $runs.workflow_runs[0]
            [pscustomobject]@{
                Repo     = $repo
                Workflow = $wf
                Status   = if ($run.conclusion) { $run.conclusion } else { $run.status }
                Branch   = $run.head_branch
                When     = $run.updated_at -as [datetime]
            }
        }

        Write-Progress -Activity "Checking '$wf'" -Completed
    }
}

Export-ModuleMember -Function Get-GitHubWorkflowStatus
