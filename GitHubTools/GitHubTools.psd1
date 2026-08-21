@{
    RootModule        = 'GitHubTools.psm1'
    ModuleVersion     = '0.1.0'
    GUID              = '4c1705e6-bb98-45c6-8d49-9bf0a0939455'
    Author            = 'Soren Klemmensen'
    CompanyName       = 'Astena'
    Copyright         = '(c) Astena. All rights reserved.'
    Description       = 'Helper cmdlets for reporting on GitHub Actions workflows across an organization, built on the GitHub CLI (gh).'

    PowerShellVersion = '5.1'

    FunctionsToExport = @('Get-GitHubWorkflowStatus', 'Get-GitHubPullRequest', 'Invoke-GitHubWorkflow')
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()

    FileList = @(
        'GitHubTools.psd1',
        'GitHubTools.psm1'
    )

    PrivateData = @{
        PSData = @{
            Tags       = @('GitHub', 'Actions', 'Workflow', 'gh', 'CI')
            ProjectUri = 'https://github.com/AstenaTools/PowerShellModules'
        }
    }
}
