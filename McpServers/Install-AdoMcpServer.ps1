<#
.SYNOPSIS
    Ensures Node.js is installed and registers the Azure DevOps MCP server in
    Claude Desktop's configuration file.

.DESCRIPTION
    1. Checks whether Node.js (and npx) is available and meets the minimum major
       version. If not, installs the LTS build via winget, falling back to a
       direct MSI download from nodejs.org.
    2. Merges an "ado" entry into the mcpServers section of
       claude_desktop_config.json, preserving any existing servers and settings.
       A timestamped backup is taken before the file is modified.

.PARAMETER Organization
    Azure DevOps organization name passed to @azure-devops/mcp. Default: astena

.PARAMETER ServerName
    Key used for this server inside mcpServers. Default: ado

.PARAMETER MinimumNodeMajorVersion
    Minimum acceptable Node.js major version. Default: 20

.PARAMETER ConfigPath
    Full path to claude_desktop_config.json. Auto-detected per OS if omitted.

.PARAMETER SkipNodeInstall
    Only update the config file; do not attempt to install Node.js.

.EXAMPLE
    .\Install-AdoMcpServer.ps1

.EXAMPLE
    .\Install-AdoMcpServer.ps1 -Organization contoso -ServerName ado-contoso

.NOTES
    Compatible with Windows PowerShell 5.1 and PowerShell 7+.
    The winget/MSI install path may prompt for elevation.
#>

#Requires -Version 5.1
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string] $Organization = 'astena',
    [string] $ServerName = 'ado',
    [int]    $MinimumNodeMajorVersion = 20,
    [string] $ConfigPath,
    [switch] $SkipNodeInstall
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

#region Helpers ---------------------------------------------------------------

function Write-Step {
    param([string] $Message)
    Write-Host "==> $Message" -ForegroundColor Cyan
}

function Get-PlatformId {
    <# Returns Windows, MacOS or Linux.

       $IsWindows/$IsMacOS/$IsLinux are automatic variables in PowerShell 6+
       only. Windows PowerShell 5.1 does not define them, and Set-StrictMode
       turns reading an undefined variable into a terminating error, so they are
       probed with Get-Variable instead of referenced directly. 5.1 only ever
       runs on Windows, so that case is answered without probing. #>
    if ($PSVersionTable.PSVersion.Major -lt 6) { return 'Windows' }
    if (Get-Variable -Name IsMacOS -ValueOnly -ErrorAction SilentlyContinue) { return 'MacOS' }
    if (Get-Variable -Name IsLinux -ValueOnly -ErrorAction SilentlyContinue) { return 'Linux' }
    return 'Windows'
}

function Test-IsWindowsPlatform {
    return ((Get-PlatformId) -eq 'Windows')
}

function Update-SessionPath {
    <# Re-reads Machine + User PATH so a freshly installed tool is found
       without restarting the console. Windows only. #>
    if (-not (Test-IsWindowsPlatform)) { return }
    $machine = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $user = [Environment]::GetEnvironmentVariable('Path', 'User')
    $env:Path = (@($machine, $user) | Where-Object { $_ }) -join ';'
}

function Get-NodeMajorVersion {
    <# Returns the installed Node major version, or $null if node is absent. #>
    Update-SessionPath
    $node = Get-Command node -ErrorAction SilentlyContinue
    if (-not $node) { return $null }

    try {
        $raw = & node --version 2>$null      # e.g. v20.11.1
    }
    catch {
        return $null
    }

    if ($raw -match '^v?(\d+)\.') { return [int] $Matches[1] }
    return $null
}

function Install-NodeWithWinget {
    $winget = Get-Command winget -ErrorAction SilentlyContinue
    if (-not $winget) {
        Write-Verbose 'winget not available on this machine.'
        return $false
    }

    Write-Step 'Installing Node.js LTS via winget...'
    $args = @(
        'install', '--id', 'OpenJS.NodeJS.LTS',
        '--exact', '--source', 'winget',
        '--accept-package-agreements', '--accept-source-agreements'
    )
    & winget @args
    # winget returns 0 on success; -1978335189 means "already installed"
    return ($LASTEXITCODE -eq 0 -or $LASTEXITCODE -eq -1978335189)
}

function Install-NodeWithMsi {
    Write-Step 'Falling back to MSI download from nodejs.org...'

    # Modern TLS for Invoke-RestMethod on Windows PowerShell 5.1
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

    $index = Invoke-RestMethod -Uri 'https://nodejs.org/dist/index.json' -UseBasicParsing
    $lts = $index | Where-Object { $_.lts } | Select-Object -First 1
    if (-not $lts) { throw 'Could not determine the current Node.js LTS release.' }

    $arch = if ([Environment]::Is64BitOperatingSystem) { 'x64' } else { 'x86' }
    $file = "node-$($lts.version)-$arch.msi"
    $url = "https://nodejs.org/dist/$($lts.version)/$file"
    $msi = Join-Path $env:TEMP $file

    Write-Host "    Downloading $url"
    Invoke-WebRequest -Uri $url -OutFile $msi -UseBasicParsing

    Write-Host '    Running installer (may prompt for elevation)...'
    $proc = Start-Process msiexec.exe -ArgumentList @('/i', "`"$msi`"", '/qn', '/norestart') -Wait -PassThru
    Remove-Item $msi -Force -ErrorAction SilentlyContinue

    if ($proc.ExitCode -ne 0) {
        throw "msiexec failed with exit code $($proc.ExitCode)."
    }
    return $true
}

function Resolve-ClaudeConfigPath {
    if ($ConfigPath) { return $ConfigPath }

    switch (Get-PlatformId) {
        'MacOS' { return Join-Path $HOME 'Library/Application Support/Claude/claude_desktop_config.json' }
        'Linux' { return Join-Path $HOME '.config/Claude/claude_desktop_config.json' }
        default { return Join-Path $env:APPDATA 'Claude\claude_desktop_config.json' }
    }
}

function Test-JsonProperty {
    <# Returns $true when $InputObject carries a property called $Name.

       Deliberately indexes the member collection instead of testing
       "$InputObject.PSObject.Properties.Name -contains $Name": that form relies
       on member enumeration, which throws PropertyNotFoundStrict under
       Set-StrictMode when the object has no properties at all - exactly the case
       for a freshly created config. Indexing returns $null instead. #>
    param(
        [Parameter(Mandatory)] $InputObject,
        [Parameter(Mandatory)] [string] $Name
    )
    return ($null -ne $InputObject.PSObject.Properties[$Name])
}

function Set-JsonProperty {
    <# Adds or overwrites a property on a PSCustomObject (PS 5.1 friendly). #>
    param(
        [Parameter(Mandatory)] $InputObject,
        [Parameter(Mandatory)] [string] $Name,
        [Parameter(Mandatory)] $Value
    )
    if (Test-JsonProperty -InputObject $InputObject -Name $Name) {
        $InputObject.$Name = $Value
    }
    else {
        $InputObject | Add-Member -MemberType NoteProperty -Name $Name -Value $Value
    }
}

function ConvertTo-JsonString {
    <# Quotes and escapes one JSON string value. #>
    param([Parameter(Mandatory)] [AllowEmptyString()] [string] $Text)

    $sb = New-Object System.Text.StringBuilder
    [void] $sb.Append('"')

    foreach ($ch in $Text.ToCharArray()) {
        switch ($ch) {
            '"'  { [void] $sb.Append('\"'); continue }
            '\'  { [void] $sb.Append('\\'); continue }
            "`b" { [void] $sb.Append('\b'); continue }
            "`f" { [void] $sb.Append('\f'); continue }
            "`n" { [void] $sb.Append('\n'); continue }
            "`r" { [void] $sb.Append('\r'); continue }
            "`t" { [void] $sb.Append('\t'); continue }
            default {
                if ([int] $ch -lt 0x20) {
                    [void] $sb.Append(('\u{0:x4}' -f [int] $ch))
                }
                else {
                    [void] $sb.Append($ch)
                }
            }
        }
    }

    [void] $sb.Append('"')
    return $sb.ToString()
}

function ConvertTo-JsonText {
    <# Serialises $Value as JSON with two-space indentation and LF newlines.

       ConvertTo-Json is deliberately not used for the document. Windows
       PowerShell 5.1 pads every value into an aligned column, which is valid
       JSON but looks nothing like the file PowerShell 7 or Claude Desktop
       itself writes, so the config ended up formatted differently depending on
       which shell ran the installer. This emitter produces identical output on
       every supported version. #>
    param(
        $Value,
        [int] $Level = 0
    )

    $nl = "`n"
    $indent = '  ' * $Level
    $inner = '  ' * ($Level + 1)

    if ($null -eq $Value) { return 'null' }

    if ($Value -is [bool]) {
        if ($Value) { return 'true' }
        return 'false'
    }

    if ($Value -is [string] -or $Value -is [char]) {
        return (ConvertTo-JsonString -Text ([string] $Value))
    }

    # [short] is not a type accelerator in Windows PowerShell 5.1 - use [int16].
    if ($Value -is [int] -or $Value -is [long] -or $Value -is [int16] -or $Value -is [byte] -or
        $Value -is [uint32] -or $Value -is [uint64] -or
        $Value -is [double] -or $Value -is [single] -or $Value -is [decimal]) {
        return [string]::Format([cultureinfo]::InvariantCulture, '{0}', $Value)
    }

    if ($Value -is [System.Collections.IDictionary]) {
        $keys = @($Value.Keys)
        if ($keys.Count -eq 0) { return '{}' }
        $parts = foreach ($key in $keys) {
            '{0}{1}: {2}' -f $inner,
                             (ConvertTo-JsonString -Text ([string] $key)),
                             (ConvertTo-JsonText -Value $Value[$key] -Level ($Level + 1))
        }
        return '{' + $nl + ($parts -join (',' + $nl)) + $nl + $indent + '}'
    }

    # Checked after [string], which is itself IEnumerable.
    if ($Value -is [System.Collections.IEnumerable]) {
        $items = @($Value)
        if ($items.Count -eq 0) { return '[]' }
        $parts = foreach ($item in $items) {
            $inner + (ConvertTo-JsonText -Value $item -Level ($Level + 1))
        }
        return '[' + $nl + ($parts -join (',' + $nl)) + $nl + $indent + ']'
    }

    $props = @($Value.PSObject.Properties)
    if ($props.Count -eq 0) { return '{}' }
    $parts = foreach ($prop in $props) {
        '{0}{1}: {2}' -f $inner,
                         (ConvertTo-JsonString -Text $prop.Name),
                         (ConvertTo-JsonText -Value $prop.Value -Level ($Level + 1))
    }
    return '{' + $nl + ($parts -join (',' + $nl)) + $nl + $indent + '}'
}

function Write-JsonFile {
    <# Writes UTF-8 without BOM, which Claude Desktop parses reliably. #>
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [string] $Content
    )
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Content, $utf8NoBom)
}

#endregion --------------------------------------------------------------------

#region 1. Node.js ------------------------------------------------------------

$major = Get-NodeMajorVersion

if ($null -ne $major -and $major -ge $MinimumNodeMajorVersion) {
    Write-Step "Node.js v$major detected - OK."
}
elseif ($SkipNodeInstall) {
    Write-Warning "Node.js missing or older than v$MinimumNodeMajorVersion, but -SkipNodeInstall was specified."
}
else {
    if ($null -eq $major) {
        Write-Step 'Node.js not found. Installing...'
    }
    else {
        Write-Step "Node.js v$major is below the required v$MinimumNodeMajorVersion. Upgrading..."
    }

    if ($PSCmdlet.ShouldProcess('Node.js LTS', 'Install')) {
        $installed = $false
        try {
            $installed = Install-NodeWithWinget
        }
        catch {
            Write-Warning "winget install failed: $($_.Exception.Message)"
        }

        if (-not $installed) {
            if (Test-IsWindowsPlatform) {
                $installed = Install-NodeWithMsi
            }
            else {
                throw 'Automatic Node.js installation is only supported on Windows. Install Node.js manually from https://nodejs.org and re-run.'
            }
        }

        $major = Get-NodeMajorVersion
        if ($null -eq $major) {
            throw 'Node.js still not detected after installation. Open a new terminal and re-run this script.'
        }
        Write-Step "Node.js v$major installed."
    }
}

if (-not (Get-Command npx -ErrorAction SilentlyContinue)) {
    Write-Warning 'npx was not found on PATH. Open a new terminal session and verify with: npx --version'
}

#endregion --------------------------------------------------------------------

#region 2. Claude Desktop config ----------------------------------------------

$configFile = Resolve-ClaudeConfigPath
$configDir = Split-Path -Parent $configFile

Write-Step "Config file: $configFile"

if (-not (Test-Path -LiteralPath $configDir)) {
    New-Item -ItemType Directory -Path $configDir -Force | Out-Null
    Write-Host "    Created $configDir"
}

# Load existing config, or start a fresh one.
if (Test-Path -LiteralPath $configFile) {
    # Read via .NET, not Get-Content: Windows PowerShell 5.1 decodes a BOM-less
    # file using the system ANSI codepage, which corrupts any non-ASCII value in
    # the config and writes it back double-encoded. ReadAllText assumes UTF-8 and
    # still honours a BOM if one is present.
    $rawJson = [System.IO.File]::ReadAllText($configFile)

    if ([string]::IsNullOrWhiteSpace($rawJson)) {
        $config = [pscustomobject]@{}
    }
    else {
        try {
            $config = $rawJson | ConvertFrom-Json
        }
        catch {
            throw "Existing config is not valid JSON: $($_.Exception.Message). Fix or remove '$configFile' and re-run."
        }
    }

    $backup = "$configFile.$(Get-Date -Format 'yyyyMMdd-HHmmss').bak"
    Copy-Item -LiteralPath $configFile -Destination $backup -Force
    Write-Host "    Backup written to $backup"
}
else {
    $config = [pscustomobject]@{}
    Write-Host '    No existing config found - creating a new one.'
}

# Ensure mcpServers exists.
if (-not (Test-JsonProperty -InputObject $config -Name 'mcpServers') -or $null -eq $config.mcpServers) {
    Set-JsonProperty -InputObject $config -Name 'mcpServers' -Value ([pscustomobject]@{})
}

# The server definition we want in place.
$adoServer = [pscustomobject]@{
    command = 'npx'
    args    = @('-y', '@azure-devops/mcp', $Organization)
}

if (Test-JsonProperty -InputObject $config.mcpServers -Name $ServerName) {
    Write-Warning "'$ServerName' already exists in mcpServers - it will be overwritten."
}

if ($PSCmdlet.ShouldProcess($configFile, "Add/update mcpServers.$ServerName")) {
    Set-JsonProperty -InputObject $config.mcpServers -Name $ServerName -Value $adoServer

    $json = ConvertTo-JsonText -Value $config
    Write-JsonFile -Path $configFile -Content $json

    Write-Step "Registered MCP server '$ServerName' for organization '$Organization'."
    Write-Host ''
    Write-Host '--- resulting configuration ---' -ForegroundColor DarkGray
    Write-Host $json
    Write-Host ''
}

#endregion --------------------------------------------------------------------

Write-Host 'Done. Restart Claude Desktop for the changes to take effect.' -ForegroundColor Green
Write-Host "If the server fails to start, sign in with 'az login' - @azure-devops/mcp uses your Azure CLI credentials." -ForegroundColor DarkGray