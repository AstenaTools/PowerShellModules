function Get-GitHubWorkflowStatus {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$wf,

        [Parameter(Mandatory)]
        [string]$org
    )

    $repos = gh repo list $org --limit 500 --no-archived --json nameWithOwner -q '.[].nameWithOwner'
    Write-Verbose "Found $($repos.Count) repos"

    foreach ($repo in $repos) {
        $json = (gh api "repos/$repo/actions/workflows/$wf/runs?per_page=1" 2>$null) -join "`n"

        if (-not $json) {
            [pscustomobject]@{ Repo=$repo; workflow = $wf; Status="no $wf"; Branch=""; When="" }
            continue
        }

        $runs = $json | ConvertFrom-Json
        if ($runs.total_count -eq 0) {
            [pscustomobject]@{ Repo=$repo; workflow = $wf; Status="never run"; Branch=""; When="" }
            continue
        }

        $r = $runs.workflow_runs[0]
        [pscustomobject]@{
            Repo   = $repo
            workflow = $wf
            Status = if ($r.conclusion) { $r.conclusion } else { $r.status }
            Branch = $r.head_branch
            When   = $r.updated_at
        }
    }
}
