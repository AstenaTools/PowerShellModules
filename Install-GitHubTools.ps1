#Requires -Version 5.1
<#
    .SYNOPSIS
        Downloads the GitHubTools module from the OxygenTools/GitHubPowerShellModules repository and imports it.

    .DESCRIPTION
        Fetches the module files straight from GitHub — no git clone and no PowerShell Gallery needed — and
        then imports the module into the current session.

        With -Scope CurrentUser (the default) the module is installed under the user's module directory, so
        every future session can 'Import-Module GitHubTools' without re-downloading. With -Scope Session the
        module is staged in a temporary directory instead and leaves nothing behind permanently.

    .PARAMETER Ref
        The branch, tag or commit SHA to download. Defaults to 'main'. Pin this to a tag for reproducibility.

    .PARAMETER Scope
        CurrentUser  Install into the user module path so it persists across sessions (default).
        Session      Stage into a temporary folder and import for this session only.

    .PARAMETER Token
        A GitHub personal access token, required only while the repository is private.
        Falls back to the GITHUB_TOKEN or GH_TOKEN environment variable when not supplied.

    .PARAMETER Force
        Overwrite an existing installation of the same module version without prompting.

    .PARAMETER PassThru
        Emit the imported module object.

    .EXAMPLE
        .\Install-GitHubTools.ps1

        Install for the current user from 'main' and import it.

    .EXAMPLE
        .\Install-GitHubTools.ps1 -Scope Session -Ref 'v0.1.0'

        Load a pinned version for this session only, installing nothing.

    .EXAMPLE
        $s = 'https://raw.githubusercontent.com/OxygenTools/GitHubPowerShellModules/main/Install-GitHubTools.ps1'
        Invoke-Expression (Invoke-RestMethod $s)

        One-liner bootstrap on a machine that does not have the repository cloned. Uses all defaults.

    .LINK
        https://github.com/OxygenTools/GitHubPowerShellModules
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$Ref = 'main',

    [ValidateSet('CurrentUser', 'Session')]
    [string]$Scope = 'CurrentUser',

    [string]$Token,

    [switch]$Force,

    [switch]$PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Owner      = 'OxygenTools'
$Repository = 'GitHubPowerShellModules'
$ModuleName = 'GitHubTools'
$ModuleFiles = @("$ModuleName.psd1", "$ModuleName.psm1")

# TLS 1.2 is not the default on stock Windows PowerShell 5.1 and GitHub requires it.
if ($PSVersionTable.PSEdition -eq 'Desktop') {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
}

if (-not $Token) {
    $Token = if ($env:GITHUB_TOKEN) { $env:GITHUB_TOKEN } else { $env:GH_TOKEN }
}

$headers = @{ 'User-Agent' = "$ModuleName-installer" }
if ($Token) { $headers['Authorization'] = "Bearer $Token" }

# Stage the download somewhere temporary first, so a failure halfway through never
# leaves a half-written module behind in the destination.
$staging = Join-Path ([IO.Path]::GetTempPath()) "$ModuleName-$([guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $staging -Force | Out-Null

try {
    foreach ($file in $ModuleFiles) {
        $uri = "https://raw.githubusercontent.com/$Owner/$Repository/$Ref/$ModuleName/$file"
        Write-Verbose "Downloading $uri"

        try {
            Invoke-WebRequest -Uri $uri -Headers $headers -OutFile (Join-Path $staging $file) -UseBasicParsing
        }
        catch {
            $status = $null
            if ($_.Exception.PSObject.Properties.Name -contains 'Response' -and $_.Exception.Response) {
                $status = [int]$_.Exception.Response.StatusCode
            }

            $hint = switch ($status) {
                404     { "Check that the ref '$Ref' exists. If the repository is private, supply -Token." }
                401     { 'The supplied token was rejected. Check that it is valid and has repo read access.' }
                403     { 'Access denied or rate limited. Supply a -Token with repo read access.' }
                default { $null }
            }

            throw "Failed to download '$file' from ref '$Ref'. $hint`n$($_.Exception.Message)"
        }
    }

    $manifestPath = Join-Path $staging "$ModuleName.psd1"
    $version = (Import-PowerShellDataFile -Path $manifestPath).ModuleVersion
    Write-Verbose "Downloaded $ModuleName $version (ref '$Ref')."

    if ($Scope -eq 'Session') {
        $destination = $staging
        Write-Verbose "Session scope: importing from the staging folder '$destination'."
    }
    else {
        $userModuleRoot = if ($PSVersionTable.PSEdition -eq 'Core') {
            Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'PowerShell\Modules'
        }
        else {
            Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'WindowsPowerShell\Modules'
        }

        $destination = Join-Path $userModuleRoot "$ModuleName\$version"

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
            Write-Host "Installed $ModuleName $version to '$destination'."
        }
        else {
            return
        }
    }

    Remove-Module $ModuleName -Force -ErrorAction SilentlyContinue
    $module = Import-Module (Join-Path $destination "$ModuleName.psd1") -Force -PassThru -Global

    Write-Host "Imported $($module.Name) $($module.Version). Available commands:"
    Get-Command -Module $ModuleName | ForEach-Object { Write-Host "  $($_.Name)" }

    if ($PassThru) { $module }
}
finally {
    # A Session-scope import runs from the staging folder, so it has to survive this script.
    if ($Scope -ne 'Session' -and (Test-Path $staging)) {
        Remove-Item -Path $staging -Recurse -Force -ErrorAction SilentlyContinue
    }
}
