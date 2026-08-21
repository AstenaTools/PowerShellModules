@{
    RootModule        = 'AzureDevOpsTools.psm1'
    ModuleVersion     = '0.1.0'
    GUID              = '71e4805f-29dc-4cc1-b415-9d93968bdaca'
    Author            = 'Soren Klemmensen'
    CompanyName       = 'Astena'
    Copyright         = '(c) Astena. All rights reserved.'
    Description       = 'Helper cmdlets for reporting on Azure DevOps pull requests across an organization, built on the Azure DevOps REST API.'

    PowerShellVersion = '5.1'

    FunctionsToExport = @('Get-AzureDevOpsPullRequest')
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()

    FileList = @(
        'AzureDevOpsTools.psd1',
        'AzureDevOpsTools.psm1'
    )

    PrivateData = @{
        PSData = @{
            Tags       = @('AzureDevOps', 'PullRequest', 'REST', 'DevOps', 'CI')
            ProjectUri = 'https://github.com/AstenaTools/PowerShellModules'
        }
    }
}
