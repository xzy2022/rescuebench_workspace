[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$RepositoryPath,

    [Parameter(Mandatory = $true)]
    [ValidateSet(
        "Probe",
        "Scope",
        "CheckChanged",
        "FixExplicit",
        "VerifyCommitted",
        "FullWorkspaceAudit"
    )]
    [string]$Action,

    [string[]]$PythonFile = @(),

    [string]$BaseRevision,

    [switch]$FullAuditAuthorized
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$script:PrimaryRepositoryRoot = "D:\Workspace\00_MyRepo\Rescubench"
$script:EnvironmentName = "rescuebench-local"
$script:RepositoryRoot = [System.IO.Path]::GetFullPath($RepositoryPath).TrimEnd("\")
$script:ConfigPath = Join-Path $script:RepositoryRoot "pyproject.toml"
$script:TestPathPattern = '(^|/)(tests?|test)(/|$)|(^|/)test_[^/]*\.py$'
$script:GitExecutable = (Get-Command git.exe -ErrorAction Stop).Source
$script:CondaExecutable = $null

function Set-Utf8Environment {
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [Console]::InputEncoding = $utf8NoBom
    [Console]::OutputEncoding = $utf8NoBom
    $global:OutputEncoding = $utf8NoBom
    $env:PYTHONUTF8 = "1"
    $env:PYTHONIOENCODING = "utf-8"
    chcp 65001 > $null
}

function ConvertTo-NativeArgument {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Value
    )

    if ($Value -and $Value -notmatch '[\s"]') {
        return $Value
    }

    $quoted = New-Object System.Text.StringBuilder
    [void]$quoted.Append('"')
    $backslashCount = 0
    foreach ($character in $Value.ToCharArray()) {
        if ($character -eq [char]92) {
            $backslashCount += 1
            continue
        }
        if ($character -eq '"') {
            [void]$quoted.Append([char]92, (($backslashCount * 2) + 1))
            [void]$quoted.Append('"')
            $backslashCount = 0
            continue
        }
        if ($backslashCount -gt 0) {
            [void]$quoted.Append([char]92, $backslashCount)
            $backslashCount = 0
        }
        [void]$quoted.Append($character)
    }
    if ($backslashCount -gt 0) {
        [void]$quoted.Append([char]92, ($backslashCount * 2))
    }
    [void]$quoted.Append('"')

    return $quoted.ToString()
}

function Invoke-NativeCapture {
    param(
        [Parameter(Mandatory = $true)]
        [string]$FilePath,

        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [string[]]$ArgumentList,

        [string]$WorkingDirectory
    )

    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $FilePath
    $startInfo.Arguments = (
        $ArgumentList |
            ForEach-Object { ConvertTo-NativeArgument -Value $_ }
    ) -join " "
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    if ($WorkingDirectory) {
        $startInfo.WorkingDirectory = $WorkingDirectory
    }
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    $startInfo.StandardOutputEncoding = $utf8NoBom
    $startInfo.StandardErrorEncoding = $utf8NoBom

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo
    try {
        if (-not $process.Start()) {
            throw "Failed to start process: $FilePath"
        }
        $standardOutputTask = $process.StandardOutput.ReadToEndAsync()
        $standardErrorTask = $process.StandardError.ReadToEndAsync()
        $process.WaitForExit()
        $standardOutput = $standardOutputTask.GetAwaiter().GetResult()
        $standardError = $standardErrorTask.GetAwaiter().GetResult()
        $exitCode = $process.ExitCode
    }
    finally {
        $process.Dispose()
    }

    return [pscustomobject]@{
        ExitCode = $exitCode
        Stdout = $standardOutput
        Stderr = $standardError
    }
}

function Invoke-GitRawAt {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Root,

        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [string[]]$ArgumentList
    )

    $result = Invoke-NativeCapture `
        -FilePath $script:GitExecutable `
        -ArgumentList (@("-C", $Root) + $ArgumentList)
    if ($result.ExitCode -ne 0) {
        $details = @($result.Stderr.Trim(), $result.Stdout.Trim()) |
            Where-Object { $_ }
        throw (
            "Git command failed with exit code $($result.ExitCode): " +
            ($details -join [Environment]::NewLine)
        )
    }
    if ($result.Stderr.Trim()) {
        Write-Warning "Git: $($result.Stderr.Trim())"
    }
    return $result.Stdout
}

function Invoke-GitRaw {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [string[]]$ArgumentList
    )

    return Invoke-GitRawAt -Root $script:RepositoryRoot -ArgumentList $ArgumentList
}

function ConvertFrom-NulPaths {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Value
    )

    if (-not $Value) {
        return @()
    }
    return @(
        $Value -split "`0" |
            Where-Object { $_ } |
            ForEach-Object { $_.Replace("\", "/") }
    )
}

function Get-GitPaths {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$ArgumentList
    )

    $raw = Invoke-GitRaw -ArgumentList $ArgumentList
    return @(ConvertFrom-NulPaths -Value $raw)
}

function Resolve-GitDirectory {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Root
    )

    $value = (Invoke-GitRawAt `
        -Root $Root `
        -ArgumentList @("rev-parse", "--git-common-dir")).Trim()
    if ([System.IO.Path]::IsPathRooted($value)) {
        return [System.IO.Path]::GetFullPath($value).TrimEnd("\")
    }
    return [System.IO.Path]::GetFullPath((Join-Path $Root $value)).TrimEnd("\")
}

function Assert-ExactRepository {
    $primaryRoot = [System.IO.Path]::GetFullPath(
        $script:PrimaryRepositoryRoot
    ).TrimEnd("\")
    if (-not (Test-Path -LiteralPath $primaryRoot -PathType Container)) {
        throw "Primary repository does not exist: $primaryRoot"
    }
    if (-not (Test-Path -LiteralPath $script:RepositoryRoot -PathType Container)) {
        throw "Requested worktree does not exist: $script:RepositoryRoot"
    }

    $primaryRepos = Join-Path $primaryRoot "repos"
    $primaryReposPrefix = $primaryRepos.TrimEnd("\") + "\"
    if (
        $script:RepositoryRoot.Equals(
            $primaryRepos,
            [System.StringComparison]::OrdinalIgnoreCase
        ) -or
        $script:RepositoryRoot.StartsWith(
            $primaryReposPrefix,
            [System.StringComparison]::OrdinalIgnoreCase
        )
    ) {
        throw "Refusing repository under repos/: $script:RepositoryRoot"
    }

    $actualRoot = (Invoke-GitRaw `
        -ArgumentList @("rev-parse", "--show-toplevel")).Trim()
    $actualRoot = [System.IO.Path]::GetFullPath($actualRoot).TrimEnd("\")
    if (-not $actualRoot.Equals(
        $script:RepositoryRoot,
        [System.StringComparison]::OrdinalIgnoreCase
    )) {
        throw "RepositoryPath must be the exact worktree root: '$actualRoot'."
    }

    $expectedCommon = Resolve-GitDirectory -Root $primaryRoot
    $actualCommon = Resolve-GitDirectory -Root $script:RepositoryRoot
    if (-not $actualCommon.Equals(
        $expectedCommon,
        [System.StringComparison]::OrdinalIgnoreCase
    )) {
        throw (
            "Refusing unrelated Git repository '$actualCommon'; " +
            "expected common directory '$expectedCommon'."
        )
    }

    $script:PrimaryRepositoryRoot = $primaryRoot
    $script:PrimaryCommonGitDirectory = $expectedCommon
}

function Assert-Config {
    if (-not (Test-Path -LiteralPath $script:ConfigPath -PathType Leaf)) {
        throw "Ruff/Pylint configuration is missing: $script:ConfigPath"
    }
}

function Assert-NoForbiddenParameters {
    param(
        [switch]$AllowPythonFile,
        [switch]$AllowBaseRevision,
        [switch]$AllowFullAudit
    )

    if (-not $AllowPythonFile -and $PythonFile.Count -gt 0) {
        throw "$Action does not accept -PythonFile."
    }
    if (-not $AllowBaseRevision -and $BaseRevision) {
        throw "$Action does not accept -BaseRevision."
    }
    if (-not $AllowFullAudit -and $FullAuditAuthorized) {
        throw "$Action does not accept -FullAuditAuthorized."
    }
}

function Assert-AllowedPythonPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$PathValue,

        [switch]$MustExist
    )

    if ([System.IO.Path]::IsPathRooted($PathValue)) {
        $fullPath = [System.IO.Path]::GetFullPath($PathValue)
    }
    else {
        $fullPath = [System.IO.Path]::GetFullPath(
            (Join-Path $script:RepositoryRoot $PathValue)
        )
    }

    $repositoryPrefix = $script:RepositoryRoot.TrimEnd("\") + "\"
    if (-not $fullPath.StartsWith(
        $repositoryPrefix,
        [System.StringComparison]::OrdinalIgnoreCase
    )) {
        throw "Python path is outside the outer workspace: $PathValue"
    }

    $reposPrefix = (Join-Path $script:RepositoryRoot "repos").TrimEnd("\") + "\"
    if ($fullPath.StartsWith(
        $reposPrefix,
        [System.StringComparison]::OrdinalIgnoreCase
    )) {
        throw "Python path is under forbidden repos/: $PathValue"
    }
    if (-not $fullPath.EndsWith(
        ".py",
        [System.StringComparison]::OrdinalIgnoreCase
    )) {
        throw "Path is not a Python file: $PathValue"
    }
    if ($MustExist -and -not (
        Test-Path -LiteralPath $fullPath -PathType Leaf
    )) {
        throw "Python file does not exist: $PathValue"
    }

    return $fullPath.Substring($repositoryPrefix.Length).Replace("\", "/")
}

function New-PathLookup {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [AllowNull()]
        [string[]]$Path
    )

    $lookup = @{}
    foreach ($item in @($Path)) {
        if ($item) {
            $lookup[$item.ToLowerInvariant()] = $true
        }
    }
    return $lookup
}

function Get-ChangedPython {
    param([string]$CommittedBase)

    if ($CommittedBase) {
        Invoke-GitRaw -ArgumentList @(
            "rev-parse",
            "--verify",
            "$CommittedBase^{commit}"
        ) | Out-Null
        $tracked = Get-GitPaths -ArgumentList @(
            "-c", "core.quotePath=false",
            "diff", "--name-only", "--diff-filter=ACMR", "-z",
            $CommittedBase, "HEAD", "--", "*.py"
        )
        $untracked = @()
    }
    else {
        $tracked = Get-GitPaths -ArgumentList @(
            "-c", "core.quotePath=false",
            "diff", "--name-only", "--diff-filter=ACMR", "-z",
            "HEAD", "--", "*.py"
        )
        $untracked = Get-GitPaths -ArgumentList @(
            "-c", "core.quotePath=false",
            "ls-files", "--others", "--exclude-standard", "-z",
            "--", "*.py"
        )
    }

    return @(
        @($tracked) + @($untracked) |
            Where-Object { $_ } |
            Sort-Object -Unique
    )
}

function Get-AllPython {
    $allPython = Get-GitPaths -ArgumentList @(
        "-c", "core.quotePath=false",
        "ls-files", "--cached", "--others", "--exclude-standard", "-z",
        "--", "*.py"
    )
    return @(
        $allPython |
            Where-Object { $_ } |
            Sort-Object -Unique
    )
}

function Get-CurrentStatusLookups {
    $staged = @(Get-GitPaths -ArgumentList @(
        "-c", "core.quotePath=false",
        "diff", "--cached", "--name-only", "--diff-filter=ACMR", "-z",
        "HEAD", "--", "*.py"
    ))
    $unstaged = @(Get-GitPaths -ArgumentList @(
        "-c", "core.quotePath=false",
        "diff", "--name-only", "--diff-filter=ACMR", "-z",
        "--", "*.py"
    ))
    $untracked = @(Get-GitPaths -ArgumentList @(
        "-c", "core.quotePath=false",
        "ls-files", "--others", "--exclude-standard", "-z",
        "--", "*.py"
    ))
    return @{
        Staged = New-PathLookup -Path $staged
        Unstaged = New-PathLookup -Path $unstaged
        Untracked = New-PathLookup -Path $untracked
    }
}

function Write-RepositoryIdentity {
    $branch = (Invoke-GitRaw -ArgumentList @(
        "rev-parse", "--abbrev-ref", "HEAD"
    )).Trim()
    $head = (Invoke-GitRaw -ArgumentList @("rev-parse", "HEAD")).Trim()
    Write-Output "RESCUEBENCH_WORKTREE=$script:RepositoryRoot"
    Write-Output "RESCUEBENCH_COMMON_GIT_DIR=$script:PrimaryCommonGitDirectory"
    Write-Output "RESCUEBENCH_BRANCH=$branch"
    Write-Output "RESCUEBENCH_HEAD=$head"
}

function Write-Scope {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [string[]]$PythonPath,

        [switch]$Committed
    )

    Write-RepositoryIdentity
    Write-Output "RESCUEBENCH_PYTHON_COUNT=$($PythonPath.Count)"
    if (-not $Committed) {
        $status = Get-CurrentStatusLookups
    }

    foreach ($path in $PythonPath) {
        $relative = Assert-AllowedPythonPath -PathValue $path -MustExist
        $key = $relative.ToLowerInvariant()
        if ($Committed) {
            $state = "committed=1"
        }
        else {
            $state = (
                "staged=$([int]$status.Staged.ContainsKey($key));" +
                "unstaged=$([int]$status.Unstaged.ContainsKey($key));" +
                "untracked=$([int]$status.Untracked.ContainsKey($key))"
            )
        }
        if ($relative -match $script:TestPathPattern) {
            Write-Output "RESCUEBENCH_TEST_PYTHON=$relative|$state"
        }
        else {
            Write-Output "RESCUEBENCH_PRODUCTION_PYTHON=$relative|$state"
        }
    }
}

function Get-CondaExecutable {
    if ($script:CondaExecutable) {
        return $script:CondaExecutable
    }

    $candidates = @()
    if ($env:CONDA_EXE) {
        $candidates += $env:CONDA_EXE
    }
    $command = Get-Command conda.exe -ErrorAction SilentlyContinue
    if ($command) {
        $candidates += $command.Source
    }
    $candidates += "C:\Users\28893\miniconda3\Scripts\conda.exe"

    foreach ($candidate in $candidates | Select-Object -Unique) {
        if ($candidate -and (Test-Path -LiteralPath $candidate -PathType Leaf)) {
            $script:CondaExecutable = [System.IO.Path]::GetFullPath($candidate)
            return $script:CondaExecutable
        }
    }
    throw "conda.exe was not found."
}

function Invoke-CondaTool {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Label,

        [Parameter(Mandatory = $true)]
        [string[]]$ArgumentList
    )

    $condaExecutable = Get-CondaExecutable
    $result = Invoke-NativeCapture `
        -FilePath $condaExecutable `
        -ArgumentList (@(
            "run", "--no-capture-output", "-n", $script:EnvironmentName
        ) + $ArgumentList) `
        -WorkingDirectory $script:RepositoryRoot
    if ($result.Stdout) {
        Write-Host $result.Stdout.TrimEnd()
    }
    if ($result.Stderr) {
        Write-Host $result.Stderr.TrimEnd()
    }
    Write-Host "RESCUEBENCH_TOOL_EXIT=$Label|$($result.ExitCode)"
    return $result.ExitCode
}

function Invoke-NativeCheck {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Label,

        [Parameter(Mandatory = $true)]
        [string]$FilePath,

        [Parameter(Mandatory = $true)]
        [string[]]$ArgumentList
    )

    $result = Invoke-NativeCapture `
        -FilePath $FilePath `
        -ArgumentList $ArgumentList `
        -WorkingDirectory $script:RepositoryRoot
    if ($result.Stdout) {
        Write-Host $result.Stdout.TrimEnd()
    }
    if ($result.Stderr) {
        Write-Host $result.Stderr.TrimEnd()
    }
    Write-Host "RESCUEBENCH_TOOL_EXIT=$Label|$($result.ExitCode)"
    return $result.ExitCode
}

function Invoke-CheckScope {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [string[]]$PythonPath,

        [switch]$Committed
    )

    Write-Scope -PythonPath $PythonPath -Committed:$Committed
    if ($PythonPath.Count -eq 0) {
        Write-Output "RESCUEBENCH_CHECK_SKIPPED=no_python"
        return
    }
    Assert-Config

    $failures = 0
    Push-Location $script:RepositoryRoot
    try {
        $ruffCheck = Invoke-CondaTool `
            -Label "ruff-check" `
            -ArgumentList (@(
                "python", "-m", "ruff", "check",
                "--config", "pyproject.toml"
            ) + $PythonPath)
        if ($ruffCheck -ne 0) {
            $failures += 1
        }

        $ruffFormat = Invoke-CondaTool `
            -Label "ruff-format-check" `
            -ArgumentList (@(
                "python", "-m", "ruff", "format",
                "--config", "pyproject.toml", "--check"
            ) + $PythonPath)
        if ($ruffFormat -ne 0) {
            $failures += 1
        }

        $pylint = Invoke-CondaTool `
            -Label "pylint" `
            -ArgumentList (@(
                "python", "-m", "pylint", "--rcfile=pyproject.toml"
            ) + $PythonPath)
        if ($pylint -ne 0) {
            $failures += 1
        }

        $diffCheck = Invoke-NativeCheck `
            -Label "git-diff-check" `
            -FilePath $script:GitExecutable `
            -ArgumentList (@(
                "-C", $script:RepositoryRoot,
                "diff", "--check", "HEAD", "--"
            ) + $PythonPath)
        if ($diffCheck -ne 0) {
            $failures += 1
        }
    }
    finally {
        Pop-Location
    }

    if ($failures -gt 0) {
        throw "$failures read-only Python review check(s) failed."
    }
    Write-Output "RESCUEBENCH_CHECK_RESULT=pass"
}

function Invoke-FixExplicit {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$RequestedPath
    )

    if ($RequestedPath.Count -eq 0) {
        throw "FixExplicit requires explicit -PythonFile values."
    }
    Assert-Config

    $changedPython = @(Get-ChangedPython)
    $changedLookup = New-PathLookup -Path $changedPython
    $resolved = foreach ($path in $RequestedPath) {
        $relative = Assert-AllowedPythonPath -PathValue $path -MustExist
        if (-not $changedLookup.ContainsKey($relative.ToLowerInvariant())) {
            throw "FixExplicit path is not in the current Python change set: $relative"
        }
        $relative
    }
    $resolved = @($resolved | Sort-Object -Unique)

    Push-Location $script:RepositoryRoot
    try {
        $fixExit = Invoke-CondaTool `
            -Label "ruff-fix" `
            -ArgumentList (@(
                "python", "-m", "ruff", "check",
                "--config", "pyproject.toml", "--fix"
            ) + $resolved)
        if ($fixExit -ne 0) {
            throw "Ruff safe-fix failed."
        }

        $formatExit = Invoke-CondaTool `
            -Label "ruff-format" `
            -ArgumentList (@(
                "python", "-m", "ruff", "format",
                "--config", "pyproject.toml"
            ) + $resolved)
        if ($formatExit -ne 0) {
            throw "Ruff format failed."
        }
    }
    finally {
        Pop-Location
    }

    $allChanged = @(Get-ChangedPython)
    Invoke-CheckScope -PythonPath $allChanged
}

function Invoke-Probe {
    Write-RepositoryIdentity
    $status = Invoke-GitRaw -ArgumentList @(
        "-c", "core.quotePath=false", "status", "--short", "--branch"
    )
    foreach ($line in ($status.TrimEnd() -split "\r?\n")) {
        if ($line) {
            Write-Output "RESCUEBENCH_GIT_STATUS=$line"
        }
    }
    Write-Output "RESCUEBENCH_CONFIG_PRESENT=$([int](Test-Path -LiteralPath $script:ConfigPath -PathType Leaf))"
    Write-Output "RESCUEBENCH_ENVIRONMENT=$script:EnvironmentName"

    $failures = 0
    foreach ($tool in @(
        @{ Label = "python-version"; Arguments = @("python", "--version") },
        @{ Label = "ruff-version"; Arguments = @("python", "-m", "ruff", "--version") },
        @{ Label = "pylint-version"; Arguments = @("python", "-m", "pylint", "--version") }
    )) {
        $exitCode = Invoke-CondaTool `
            -Label $tool.Label `
            -ArgumentList $tool.Arguments
        if ($exitCode -ne 0) {
            $failures += 1
        }
    }
    if ($failures -gt 0) {
        throw "$failures review toolchain probe(s) failed."
    }
    Write-Output "RESCUEBENCH_PROBE_RESULT=pass"
}

Set-Utf8Environment
Assert-ExactRepository

switch ($Action) {
    "Probe" {
        Assert-NoForbiddenParameters
        Invoke-Probe
    }
    "Scope" {
        Assert-NoForbiddenParameters
        $changedPython = @(Get-ChangedPython)
        Write-Scope -PythonPath $changedPython
    }
    "CheckChanged" {
        Assert-NoForbiddenParameters
        $changedPython = @(Get-ChangedPython)
        Invoke-CheckScope -PythonPath $changedPython
    }
    "FixExplicit" {
        Assert-NoForbiddenParameters -AllowPythonFile
        Invoke-FixExplicit -RequestedPath $PythonFile
    }
    "VerifyCommitted" {
        Assert-NoForbiddenParameters -AllowBaseRevision
        if (-not $BaseRevision) {
            throw "VerifyCommitted requires explicit -BaseRevision."
        }
        $committedPython = @(Get-ChangedPython -CommittedBase $BaseRevision)
        Invoke-CheckScope -PythonPath $committedPython -Committed
    }
    "FullWorkspaceAudit" {
        Assert-NoForbiddenParameters -AllowFullAudit
        if (-not $FullAuditAuthorized) {
            throw "FullWorkspaceAudit requires -FullAuditAuthorized."
        }
        $allPython = @(Get-AllPython)
        Write-Output "RESCUEBENCH_FULL_AUDIT=authorized"
        Invoke-CheckScope -PythonPath $allPython
    }
}
