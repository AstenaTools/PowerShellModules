@{
    RootModule        = 'AzureDevOpsTools.psm1'
    ModuleVersion     = '0.5.0'
    GUID              = '71e4805f-29dc-4cc1-b415-9d93968bdaca'
    Author            = 'Soren Klemmensen'
    CompanyName       = 'Astena'
    Copyright         = '(c) Astena. All rights reserved.'
    Description       = 'Helper cmdlets for reporting on Azure DevOps pull requests and closed work items across an organization, built on the Azure DevOps REST API.'

    PowerShellVersion = '5.1'

    FunctionsToExport = @(
        'Get-AzureDevOpsPullRequest'
        'Get-AzureDevOpsPullRequestCount'
        'Get-AzureDevOpsClosedWorkItem'
        'Get-AzureDevOpsClosedWorkItemCount'
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()

    # The installer downloads exactly what this lists, so a new file must be added here.
    FileList = @(
        'AzureDevOpsTools.psd1',
        'AzureDevOpsTools.psm1',
        'AzureDevOpsTools.format.ps1xml'
    )

    PrivateData = @{
        PSData = @{
            Tags       = @('AzureDevOps', 'PullRequest', 'WorkItem', 'Reporting', 'REST', 'DevOps', 'CI')
            ProjectUri = 'https://github.com/AstenaTools/PowerShellModules'
        }
    }
}
