[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('Probe', 'Run', 'StartJob', 'JobStatus', 'Upload', 'Download')]
    [string]$Action,

    [ValidatePattern('^[A-Za-z0-9._-]+$')]
    [string]$Alias = 'autodl-t4',

    [string]$Command,

    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$')]
    [string]$SessionName,

    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$')]
    [string]$ProjectName,

    [string]$WorkingDirectory = '/root/autodl-tmp',

    [string]$LogPath,

    [ValidateRange(1, 10000)]
    [int]$TailLines = 100,

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

function Require-AbsoluteRemotePath {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [AllowEmptyString()][string]$Value
    )

    Require-Value -Name $Name -Value $Value
    if (-not $Value.StartsWith('/')) {
        throw "-$Name must be an absolute remote path beginning with '/'."
    }
    if ($Value.Contains([char]0)) {
        throw "-$Name may not contain a NUL character."
    }
}

function ConvertTo-Utf8Base64 {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Value)

    $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes($Value)
    return [Convert]::ToBase64String($bytes)
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

    'StartJob' {
        Require-Value -Name 'Command' -Value $Command
        Require-Value -Name 'SessionName' -Value $SessionName
        Require-Value -Name 'ProjectName' -Value $ProjectName
        Require-AbsoluteRemotePath -Name 'WorkingDirectory' -Value $WorkingDirectory

        if (-not [string]::IsNullOrWhiteSpace($LogPath)) {
            throw '-LogPath may not be supplied for StartJob. The canonical remote log path is generated automatically.'
        }

        $canonicalLogRoot = '/root/autodl-tmp/logs'
        $startedAtUtc = [DateTimeOffset]::UtcNow
        $datePath = $startedAtUtc.ToString('yyyy/MM/dd', [System.Globalization.CultureInfo]::InvariantCulture)
        $timestamp = $startedAtUtc.ToString("yyyyMMdd'T'HHmmssfff'Z'", [System.Globalization.CultureInfo]::InvariantCulture)
        $runId = [Guid]::NewGuid().ToString('N')
        $LogPath = "$canonicalLogRoot/$ProjectName/$datePath/${timestamp}_${SessionName}_${runId}.log"

        $commandBase64 = ConvertTo-Utf8Base64 -Value $Command
        $workingDirectoryBase64 = ConvertTo-Utf8Base64 -Value $WorkingDirectory
        $logPathBase64 = ConvertTo-Utf8Base64 -Value $LogPath

        $jobScript = @'
set +e
working_dir="$(printf '%s' '__WORKING_DIRECTORY_BASE64__' | base64 -d)"
log_path="$(printf '%s' '__LOG_PATH_BASE64__' | base64 -d)"
run_command="$(printf '%s' '__COMMAND_BASE64__' | base64 -d)"

exec >>"$log_path" 2>&1
printf '__AUTODL_JOB_SHELL_STARTED__=%s\n' "$(date -Is)"
export PYTHONUNBUFFERED="${PYTHONUNBUFFERED:-1}"

cd "$working_dir"
cd_rc=$?
if [ "$cd_rc" -ne 0 ]; then
    printf '__AUTODL_JOB_EXIT_CODE__=%s\n' "$cd_rc"
    printf '__AUTODL_JOB_FINISHED__=%s\n' "$(date -Is)"
    exit "$cd_rc"
fi

bash -lc "$run_command"
job_rc=$?
printf '__AUTODL_JOB_EXIT_CODE__=%s\n' "$job_rc"
printf '__AUTODL_JOB_FINISHED__=%s\n' "$(date -Is)"
exit "$job_rc"
'@
        $jobScript = $jobScript.Replace('__WORKING_DIRECTORY_BASE64__', $workingDirectoryBase64)
        $jobScript = $jobScript.Replace('__LOG_PATH_BASE64__', $logPathBase64)
        $jobScript = $jobScript.Replace('__COMMAND_BASE64__', $commandBase64)
        $jobScriptBase64 = ConvertTo-Utf8Base64 -Value $jobScript

        $remoteScript = @'
set -u
session_name='__SESSION_NAME__'
project_name='__PROJECT_NAME__'
run_id='__RUN_ID__'
working_dir="$(printf '%s' '__WORKING_DIRECTORY_BASE64__' | base64 -d)"
log_path="$(printf '%s' '__LOG_PATH_BASE64__' | base64 -d)"
job_script_base64='__JOB_SCRIPT_BASE64__'

command -v screen >/dev/null 2>&1 || {
    echo "Required remote command was not found: screen" >&2
    exit 80
}
command -v base64 >/dev/null 2>&1 || {
    echo "Required remote command was not found: base64" >&2
    exit 81
}
test -d "$working_dir" || {
    echo "Remote working directory does not exist: $working_dir" >&2
    exit 82
}

if screen -ls 2>/dev/null | awk -v target="$session_name" '
    $1 ~ /^[0-9]+\./ {
        name = $1
        sub(/^[0-9]+\./, "", name)
        if (name == target) {
            found = 1
        }
    }
    END { exit(found ? 0 : 1) }
'; then
    echo "A screen session with this name already exists: $session_name" >&2
    exit 83
fi

log_dir="$(dirname -- "$log_path")"
mkdir -p -- "$log_dir" || {
    echo "Could not create remote log directory: $log_dir" >&2
    exit 84
}
if [ -e "$log_path" ]; then
    echo "Refusing to overwrite existing remote log: $log_path" >&2
    exit 85
fi

{
    printf 'timestamp=%s\n' "$(date -Is)"
    printf 'project=%s\n' "$project_name"
    printf 'session=%s\n' "$session_name"
    printf 'run_id=%s\n' "$run_id"
    printf 'working_directory=%s\n' "$working_dir"
    printf '%s\n' '--- job output ---'
} >"$log_path"

screen -dmS "$session_name" bash -lc "printf '%s' '$job_script_base64' | base64 -d | bash"
launch_rc=$?
if [ "$launch_rc" -ne 0 ]; then
    printf '__AUTODL_SCREEN_LAUNCH_EXIT_CODE__=%s\n' "$launch_rc" >>"$log_path"
    echo "Could not start screen session '$session_name' (exit $launch_rc)." >&2
    exit "$launch_rc"
fi

printf '__AUTODL_PROJECT__=%s\n' "$project_name"
printf '__AUTODL_SESSION__=%s\n' "$session_name"
printf '__AUTODL_RUN_ID__=%s\n' "$run_id"
printf '__AUTODL_LOG_PATH__=%s\n' "$log_path"
printf '__AUTODL_LAUNCH_STATUS__=started\n'
'@
        $remoteScript = $remoteScript.Replace('__SESSION_NAME__', $SessionName)
        $remoteScript = $remoteScript.Replace('__PROJECT_NAME__', $ProjectName)
        $remoteScript = $remoteScript.Replace('__RUN_ID__', $runId)
        $remoteScript = $remoteScript.Replace('__WORKING_DIRECTORY_BASE64__', $workingDirectoryBase64)
        $remoteScript = $remoteScript.Replace('__LOG_PATH_BASE64__', $logPathBase64)
        $remoteScript = $remoteScript.Replace('__JOB_SCRIPT_BASE64__', $jobScriptBase64)

        $remoteScriptBase64 = ConvertTo-Utf8Base64 -Value $remoteScript
        $remoteLauncher = "printf '%s' '$remoteScriptBase64' | base64 -d | bash"

        & ssh @sshOptions $Alias $remoteLauncher
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to start remote job with exit code $LASTEXITCODE."
        }
    }

    'JobStatus' {
        Require-Value -Name 'SessionName' -Value $SessionName
        Require-AbsoluteRemotePath -Name 'LogPath' -Value $LogPath

        $logPathBase64 = ConvertTo-Utf8Base64 -Value $LogPath
        $remoteScript = @'
set -u
session_name='__SESSION_NAME__'
log_path="$(printf '%s' '__LOG_PATH_BASE64__' | base64 -d)"
tail_lines=__TAIL_LINES__

if screen -ls 2>/dev/null | awk -v target="$session_name" '
    $1 ~ /^[0-9]+\./ {
        name = $1
        sub(/^[0-9]+\./, "", name)
        if (name == target) {
            found = 1
        }
    }
    END { exit(found ? 0 : 1) }
'; then
    printf '__AUTODL_JOB_RUNNING__=true\n'
else
    printf '__AUTODL_JOB_RUNNING__=false\n'
fi

printf '__AUTODL_LOG_PATH__=%s\n' "$log_path"
if [ -f "$log_path" ]; then
    printf '%s\n' '--- log tail ---'
    tail -n "$tail_lines" -- "$log_path"
else
    printf '__AUTODL_LOG_EXISTS__=false\n'
fi
'@
        $remoteScript = $remoteScript.Replace('__SESSION_NAME__', $SessionName)
        $remoteScript = $remoteScript.Replace('__LOG_PATH_BASE64__', $logPathBase64)
        $remoteScript = $remoteScript.Replace('__TAIL_LINES__', $TailLines.ToString())

        $remoteScriptBase64 = ConvertTo-Utf8Base64 -Value $remoteScript
        $remoteLauncher = "printf '%s' '$remoteScriptBase64' | base64 -d | bash"

        & ssh @sshOptions $Alias $remoteLauncher
        if ($LASTEXITCODE -ne 0) {
            throw "Could not inspect remote job with exit code $LASTEXITCODE."
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
