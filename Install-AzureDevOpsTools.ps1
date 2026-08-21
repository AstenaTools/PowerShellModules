#Requires -Version 5.1
<#
    .SYNOPSIS
        Downloads the AzureDevOpsTools module from the AstenaTools/PowerShellModules repository and imports it.

    .DESCRIPTION
        Fetches the module files straight from GitHub - no git clone and no PowerShell Gallery needed - and
        then imports the module into the current session.

        The ref is resolved to the commit it currently points at, and the files are downloaded from that
        commit rather than from the branch name. This matters: raw.githubusercontent.com serves a branch
        ref with a five-minute cache, so downloading 'main' straight after a push can quietly hand back
        the previous content. A commit URL is immutable, so whatever the cache holds for it is correct.
        When the commit cannot be resolved - no network for the API, a rate limit, or a private repository
        without a token - the download falls back to the branch ref and asks the CDN not to serve a
        cached copy.

        With -Scope CurrentUser (the default) the module is installed under the user's module directory, so
        every future session can 'Import-Module AzureDevOpsTools' without re-downloading. With -Scope Session
        the module is staged in a temporary directory and imported from there instead, touching nothing under
        the module path - the staging folder has to outlive the script for the import to keep working, so it
        is left for the operating system to clean up with the rest of the temp directory.

        The module itself talks to the Azure DevOps REST API and needs a credential of its own at run time -
        an 'az login' session, or a PAT with the Code (read) scope in AZURE_DEVOPS_EXT_PAT. That is separate
        from the -Token used here, which only reads this repository.

    .PARAMETER Ref
        The branch, tag or commit SHA to download. Defaults to 'main', whose current tip is resolved and
        used. Pass a tag or a commit SHA for a reproducible install.

    .PARAMETER Scope
        CurrentUser  Install into the user module path so it persists across sessions (default).
        Session      Stage into a temporary folder and import for this session only.

    .PARAMETER Token
        A GitHub personal access token, required only while the repository is private.
        Falls back to the GITHUB_TOKEN or GH_TOKEN environment variable when not supplied.

    .PARAMETER Force
        Overwrite an existing installation of the same module version without prompting.

    .PARAMETER RemoveOldVersion
        After a successful install, delete the other installed versions of this module. Without it they are
        left alone and only reported: PowerShell imports the highest version it can find, so an old copy is
        usually harmless, but it still answers Import-Module -RequiredVersion and shows up in
        Get-Module -ListAvailable.

    .PARAMETER PassThru
        Emit the imported module object.

    .EXAMPLE
        .\Install-AzureDevOpsTools.ps1

        Install for the current user from 'main' and import it.

    .EXAMPLE
        .\Install-AzureDevOpsTools.ps1 -Scope Session -Ref '65ecff7'

        Load a pinned commit for this session only, installing nothing.

    .EXAMPLE
        .\Install-AzureDevOpsTools.ps1 -RemoveOldVersion

        Install the current tip of main and clear out the versions it supersedes.

    .EXAMPLE
        $s = 'https://raw.githubusercontent.com/AstenaTools/PowerShellModules/main/Install-AzureDevOpsTools.ps1'
        Invoke-Expression (Invoke-RestMethod $s)

        One-liner bootstrap on a machine that does not have the repository cloned. Uses all defaults.

    .LINK
        https://github.com/AstenaTools/PowerShellModules
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$Ref = 'main',

    [ValidateSet('CurrentUser', 'Session')]
    [string]$Scope = 'CurrentUser',

    [string]$Token,

    [switch]$Force,

    [switch]$RemoveOldVersion,

    [switch]$PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Owner      = 'AstenaTools'
$Repository = 'PowerShellModules'
$ModuleName = 'AzureDevOpsTools'

# TLS 1.2 is not the default on stock Windows PowerShell 5.1 and GitHub requires it.
if ($PSVersionTable.PSEdition -eq 'Desktop') {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
}

if (-not $Token) {
    $Token = if ($env:GITHUB_TOKEN) { $env:GITHUB_TOKEN } else { $env:GH_TOKEN }
}

$headers = @{ 'User-Agent' = "$ModuleName-installer" }
if ($Token) { $headers['Authorization'] = "Bearer $Token" }

# What is already installed, so the summary at the end can say what changed.
$userModuleRoot = if ($PSVersionTable.PSEdition -eq 'Core') {
    Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'PowerShell\Modules'
}
else {
    Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'WindowsPowerShell\Modules'
}
$moduleRoot = Join-Path $userModuleRoot $ModuleName
$installedBefore = @()
if (Test-Path $moduleRoot) {
    $installedBefore = @(Get-ChildItem -Path $moduleRoot -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -as [version] } |
            ForEach-Object { $_.Name -as [version] } | Sort-Object)
}

# Resolve the ref to the commit it points at. Downloading a branch name goes through a five-minute
# CDN cache, so a push followed straight away by an install can hand back the previous content; a
# commit URL cannot go stale.
$downloadRef = $Ref
$resolvedSha = $null
if ($Ref -notmatch '^[0-9a-f]{40}$') {
    try {
        $commitUri = "https://api.github.com/repos/$Owner/$Repository/commits/$Ref"
        Write-Verbose "Resolving '$Ref' via $commitUri"

        $apiHeaders = $headers.Clone()
        $apiHeaders['Accept'] = 'application/vnd.github.sha'

        $resolvedSha = (Invoke-WebRequest -Uri $commitUri -Headers $apiHeaders -UseBasicParsing).Content
        if ($resolvedSha -is [byte[]]) { $resolvedSha = [System.Text.Encoding]::UTF8.GetString($resolvedSha) }
        $resolvedSha = ([string]$resolvedSha).Trim()

        if ($resolvedSha -notmatch '^[0-9a-f]{40}$') { throw "unexpected response '$resolvedSha'" }

        $downloadRef = $resolvedSha
        Write-Verbose "'$Ref' is at commit $resolvedSha."
    }
    catch {
        # Not fatal: the branch ref still works, it just has to be fetched past the cache.
        Write-Warning ("Could not resolve '$Ref' to a commit ($($_.Exception.Message)). " +
            'Falling back to the branch ref with caching disabled.')
        $resolvedSha = $null
        $downloadRef = $Ref
    }
}

# Belt and braces for the fallback path, and harmless on a commit URL.
$headers['Cache-Control'] = 'no-cache'
$headers['Pragma'] = 'no-cache'

function Get-RepositoryFile {
    <#
        .SYNOPSIS
            Downloads one file of the module from the resolved ref into the staging folder.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$File
    )

    $relative = $File -replace '\\', '/'
    $uri = "https://raw.githubusercontent.com/$Owner/$Repository/$downloadRef/$ModuleName/$relative"
    $target = Join-Path $staging $File

    $targetDirectory = Split-Path -Path $target -Parent
    if ($targetDirectory -and -not (Test-Path $targetDirectory)) {
        New-Item -ItemType Directory -Path $targetDirectory -Force -WhatIf:$false | Out-Null
    }

    Write-Verbose "Downloading $uri"

    try {
        Invoke-WebRequest -Uri $uri -Headers $headers -OutFile $target -UseBasicParsing
    }
    catch {
        $status = $null
        if ($_.Exception.PSObject.Properties.Name -contains 'Response' -and $_.Exception.Response) {
            $status = [int]$_.Exception.Response.StatusCode
        }

        $hint = switch ($status) {
            404 { "Check that the ref '$Ref' exists and contains '$File'. If the repository is private, supply -Token." }
            401 { 'The supplied token was rejected. Check that it is valid and has repo read access.' }
            403 { 'Access denied or rate limited. Supply a -Token with repo read access.' }
            default { $null }
        }

        throw "Failed to download '$File' from ref '$Ref'. $hint`n$($_.Exception.Message)"
    }
}

# Stage the download somewhere temporary first, so a failure halfway through never
# leaves a half-written module behind in the destination.
$staging = Join-Path ([IO.Path]::GetTempPath()) "$ModuleName-$([guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $staging -Force -WhatIf:$false | Out-Null

try {
    # The manifest is fetched first and its own FileList drives the rest of the download. A file
    # added to the module therefore cannot be left out of an install by a stale list in here -
    # which would install a manifest referencing a file that is not there, and fail on import.
    $manifestName = "$ModuleName.psd1"
    Get-RepositoryFile -File $manifestName

    $manifestPath = Join-Path $staging $manifestName
    $manifest = Import-PowerShellDataFile -Path $manifestPath
    $version = $manifest.ModuleVersion

    $companions = @()
    if ($manifest.Contains('FileList')) {
        $companions = @($manifest.FileList |
                Where-Object { $_ -and (Split-Path $_ -Leaf) -ne $manifestName })
    }
    if (-not $companions.Count) {
        Write-Verbose 'The manifest carries no FileList; falling back to its RootModule alone.'
        $companions = @($manifest.RootModule)
    }

    Write-Verbose "The manifest asks for $($companions.Count) further file(s): $($companions -join ', ')."
    foreach ($file in $companions) { Get-RepositoryFile -File $file }

    $refDescription = if ($resolvedSha) { "ref '$Ref' at commit $($resolvedSha.Substring(0, 7))" } else { "ref '$Ref'" }
    Write-Verbose "Downloaded $ModuleName $version ($refDescription)."

    if ($Scope -eq 'Session') {
        $destination = $staging
        Write-Verbose "Session scope: importing from the staging folder '$destination'."
    }
    else {
        $destination = Join-Path $moduleRoot $version

        if ((Test-Path $destination) -and -not $Force) {
            $existing = Get-ChildItem -Path $destination -Filter '*.ps*1' -ErrorAction SilentlyContinue
            if ($existing) {
                Write-Warning "$ModuleName $version is already installed at '$destination'. Overwriting; use -Force to suppress this warning."
            }
        }

        if ($PSCmdlet.ShouldProcess($destination, "Install $ModuleName $version")) {
            New-Item -ItemType Directory -Path $destination -Force | Out-Null

            # The module may be loaded from a previous run and would lock the files.
            Remove-Module $ModuleName -Force -ErrorAction SilentlyContinue

            Copy-Item -Path (Join-Path $staging '*') -Destination $destination -Force
            Write-Host "Installed $ModuleName $version ($refDescription) to '$destination'."
        }
        else {
            return
        }
    }

    Remove-Module $ModuleName -Force -ErrorAction SilentlyContinue
    $module = Import-Module (Join-Path $destination "$ModuleName.psd1") -Force -PassThru -Global

    Write-Host "Imported $($module.Name) $($module.Version). Available commands:"
    Get-Command -Module $ModuleName | ForEach-Object { Write-Host "  $($_.Name)" }

    if ($Scope -ne 'Session') {
        # Say plainly what changed. "It still runs the old code" is nearly always a stale install
        # rather than a bad download, so the answer belongs in the output rather than in a guess.
        $newVersion = [version]$version
        $superseded = @($installedBefore | Where-Object { $_ -ne $newVersion })

        if ($installedBefore -contains $newVersion) {
            Write-Host "$ModuleName $version was already installed; its files were refreshed from $refDescription."
        }
        elseif ($installedBefore.Count) {
            $previous = @($installedBefore | Sort-Object -Descending)[0]
            Write-Host "Upgraded $ModuleName from $previous to $version."
        }

        if ($superseded.Count) {
            $others = @($superseded | Sort-Object -Descending) -join ', '

            if ($RemoveOldVersion) {
                foreach ($old in $superseded) {
                    $oldPath = Join-Path $moduleRoot $old
                    if ($PSCmdlet.ShouldProcess($oldPath, "Remove superseded $ModuleName $old")) {
                        Remove-Item -Path $oldPath -Recurse -Force -ErrorAction SilentlyContinue
                        if (Test-Path $oldPath) {
                            Write-Warning "Could not remove '$oldPath' - another session may have it loaded."
                        }
                        else {
                            Write-Host "Removed superseded version $old."
                        }
                    }
                }
            }
            else {
                Write-Warning ("Older versions are still installed: $others. Import-Module $ModuleName " +
                    "resolves to $version because it is the highest, but -RequiredVersion can still reach " +
                    'an old one. Re-run with -RemoveOldVersion to delete them.')
            }
        }

        # PowerShell 7 and Windows PowerShell read different user module directories, so installing
        # under one host leaves the other on whatever it had.
        $otherEdition = if ($PSVersionTable.PSEdition -eq 'Core') { 'Windows PowerShell' } else { 'PowerShell 7+' }
        $otherLeaf = if ($PSVersionTable.PSEdition -eq 'Core') { 'WindowsPowerShell\Modules' } else { 'PowerShell\Modules' }
        $otherRoot = Join-Path (Join-Path ([Environment]::GetFolderPath('MyDocuments')) $otherLeaf) $ModuleName

        if (Test-Path $otherRoot) {
            $otherVersions = @(Get-ChildItem -Path $otherRoot -Directory -ErrorAction SilentlyContinue |
                    Where-Object { $_.Name -as [version] } |
                    ForEach-Object { $_.Name -as [version] } | Sort-Object -Descending)

            if ($otherVersions.Count -and $otherVersions[0] -lt $newVersion) {
                Write-Warning ("$otherEdition has $ModuleName $($otherVersions[0]) installed separately. " +
                    "Run this script from $otherEdition too if you use the module there.")
            }
        }
    }

    if ($PassThru) { $module }
}
finally {
    # A Session-scope import runs from the staging folder, so it has to survive this script.
    if ($Scope -ne 'Session' -and (Test-Path $staging)) {
        Remove-Item -Path $staging -Recurse -Force -WhatIf:$false -ErrorAction SilentlyContinue
    }
}
