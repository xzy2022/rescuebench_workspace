[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('Probe', 'Run', 'Upload', 'Download')]
    [string]$Action,

    [ValidatePattern('^[A-Za-z0-9._-]+$')]
    [string]$Alias = 'autodl-t4',

    [string]$Command,

    [string]$LocalPath,

    [string]$RemotePath = '/root/autodl-tmp',

    [switch]$Recursive
)

$ErrorActionPreference = 'Stop'

function Require-Command {
    param([Parameter(Mandatory = $true)][string]$Name)

    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "Required command was not found: $Name"
    }
}

function Require-Value {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [AllowEmptyString()][string]$Value
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        throw "-$Name is required for action $Action."
    }
}

Require-Command -Name 'ssh'

$sshOptions = @(
    '-o', 'BatchMode=yes',
    '-o', 'PreferredAuthentications=publickey',
    '-o', 'PasswordAuthentication=no',
    '-o', 'KbdInteractiveAuthentication=no',
    '-o', 'ConnectTimeout=15',
    '-o', 'ServerAliveInterval=15',
    '-o', 'ServerAliveCountMax=3'
)

& ssh -G $Alias 2>$null | Out-Null
if ($LASTEXITCODE -ne 0) {
    throw "SSH alias '$Alias' is not valid. Check the local SSH config."
}

switch ($Action) {
    'Probe' {
        $probeCommand = 'echo AUTODL_CONNECTION_OK; whoami; hostname; date -Is; nvidia-smi --query-gpu=name,memory.total,memory.used,utilization.gpu --format=csv,noheader; df -hT /root/autodl-tmp; /root/miniconda3/bin/python --version'
        & ssh @sshOptions $Alias $probeCommand
        if ($LASTEXITCODE -ne 0) {
            throw "AutoDL probe failed with exit code $LASTEXITCODE."
        }
    }

    'Run' {
        Require-Value -Name 'Command' -Value $Command
        & ssh @sshOptions $Alias $Command
        if ($LASTEXITCODE -ne 0) {
            throw "Remote command failed with exit code $LASTEXITCODE."
        }
    }

    'Upload' {
        Require-Command -Name 'scp'
        Require-Value -Name 'LocalPath' -Value $LocalPath
        Require-Value -Name 'RemotePath' -Value $RemotePath

        $resolvedLocalPath = (Resolve-Path -LiteralPath $LocalPath).Path
        $scpOptions = @($sshOptions)
        if ((Get-Item -LiteralPath $resolvedLocalPath).PSIsContainer -or $Recursive) {
            $scpOptions += '-r'
        }

        $remoteDestination = "${Alias}:$RemotePath"
        & scp @scpOptions -- $resolvedLocalPath $remoteDestination
        if ($LASTEXITCODE -ne 0) {
            throw "Upload failed with exit code $LASTEXITCODE."
        }
    }

    'Download' {
        Require-Command -Name 'scp'
        Require-Value -Name 'RemotePath' -Value $RemotePath
        Require-Value -Name 'LocalPath' -Value $LocalPath

        $scpOptions = @($sshOptions)
        if ($Recursive) {
            $scpOptions += '-r'
        }

        $remoteSource = "${Alias}:$RemotePath"
        & scp @scpOptions -- $remoteSource $LocalPath
        if ($LASTEXITCODE -ne 0) {
            throw "Download failed with exit code $LASTEXITCODE."
        }
    }
}
