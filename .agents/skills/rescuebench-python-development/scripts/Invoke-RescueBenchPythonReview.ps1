[CmdletBinding()]
param(
    [string]$WorkspaceRoot = "D:\Workspace\00_MyRepo\Rescubench",

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

$script:WorkspaceRoot = [System.IO.Path]::GetFullPath($WorkspaceRoot).TrimEnd("\")
$script:EnvironmentName = "rescuebench-local"
$script:RepositoryRoot = [System.IO.Path]::GetFullPath($RepositoryPath).TrimEnd("\")
$script:RepositoryKind = $null
$script:RepositoryCommonGitDirectory = $null
$script:ConfigPath = $null
$script:ConfigSource = $null
$script:TestPathPattern = (
    '(^|/)(tests?|test)(/|$)|' +
    '(^|/)(test_[^/]*|[^/]*_test|conftest)\.py$'
)
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

function Test-ReviewConfig {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $false
    }
    $content = [System.IO.File]::ReadAllText($Path)
    return (
        $content -match '(?m)^\[tool\.ruff(?:\.|\])' -and
        $content -match '(?m)^\[tool\.pylint(?:\.|\])'
    )
}

function Resolve-ReviewConfig {
    $repositoryConfig = Join-Path $script:RepositoryRoot "pyproject.toml"
    if (Test-ReviewConfig -Path $repositoryConfig) {
        $script:ConfigPath = [System.IO.Path]::GetFullPath($repositoryConfig)
        $script:ConfigSource = "repository-native"
        return
    }

    $workspaceConfig = Join-Path $script:WorkspaceRoot "pyproject.toml"
    if (-not (Test-ReviewConfig -Path $workspaceConfig)) {
        throw "Workspace Ruff/Pylint configuration is missing: $workspaceConfig"
    }
    $script:ConfigPath = [System.IO.Path]::GetFullPath($workspaceConfig)
    $script:ConfigSource = "workspace-fallback"
}

function Assert-ExactRepository {
    if (-not (Test-Path -LiteralPath $script:WorkspaceRoot -PathType Container)) {
        throw "Workspace root does not exist: $script:WorkspaceRoot"
    }
    if (-not (Test-Path -LiteralPath $script:RepositoryRoot -PathType Container)) {
        throw "Requested worktree does not exist: $script:RepositoryRoot"
    }

    $actualWorkspaceRoot = (Invoke-GitRawAt `
        -Root $script:WorkspaceRoot `
        -ArgumentList @("rev-parse", "--show-toplevel")).Trim()
    $actualWorkspaceRoot = [System.IO.Path]::GetFullPath(
        $actualWorkspaceRoot
    ).TrimEnd("\")
    if (-not $actualWorkspaceRoot.Equals(
        $script:WorkspaceRoot,
        [System.StringComparison]::OrdinalIgnoreCase
    )) {
        throw "WorkspaceRoot must be the exact worktree root: '$actualWorkspaceRoot'."
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

    $workspaceCommon = Resolve-GitDirectory -Root $script:WorkspaceRoot
    $actualCommon = Resolve-GitDirectory -Root $script:RepositoryRoot
    if ($script:RepositoryRoot.Equals(
        $script:WorkspaceRoot,
        [System.StringComparison]::OrdinalIgnoreCase
    )) {
        if (-not $actualCommon.Equals(
            $workspaceCommon,
            [System.StringComparison]::OrdinalIgnoreCase
        )) {
            throw "Outer repository common Git directory does not match the workspace."
        }
        $script:RepositoryKind = "outer"
    }
    else {
        $reposRoot = [System.IO.Path]::GetFullPath(
            (Join-Path $script:WorkspaceRoot "repos")
        ).TrimEnd("\")
        $reposPrefix = $reposRoot + "\"
        if (-not $script:RepositoryRoot.StartsWith(
            $reposPrefix,
            [System.StringComparison]::OrdinalIgnoreCase
        )) {
            throw (
                "RepositoryPath must be the outer workspace or an independent " +
                "Git repository under repos/: $script:RepositoryRoot"
            )
        }
        if ($actualCommon.Equals(
            $workspaceCommon,
            [System.StringComparison]::OrdinalIgnoreCase
        )) {
            throw "Repository under repos/ must have an independent Git directory."
        }
        $script:RepositoryKind = "independent"
    }

    $script:WorkspaceCommonGitDirectory = $workspaceCommon
    $script:RepositoryCommonGitDirectory = $actualCommon
    Resolve-ReviewConfig
}

function Assert-Config {
    if (-not (Test-Path -LiteralPath $script:ConfigPath -PathType Leaf)) {
        throw "Ruff/Pylint configuration is missing: $script:ConfigPath"
    }
}

function Assert-ActionAllowedForRepository {
    if (
        $script:RepositoryKind -eq "independent" -and
        $Action -in @("VerifyCommitted", "FullWorkspaceAudit")
    ) {
        throw "$Action is not allowed for independent repositories under repos/."
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
        throw "Python path is outside the selected repository: $PathValue"
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

    if (Test-Path -LiteralPath $fullPath -PathType Leaf) {
        $fileRepository = (Invoke-GitRawAt `
            -Root (Split-Path -Parent $fullPath) `
            -ArgumentList @("rev-parse", "--show-toplevel")).Trim()
        $fileRepository = [System.IO.Path]::GetFullPath(
            $fileRepository
        ).TrimEnd("\")
        if (-not $fileRepository.Equals(
            $script:RepositoryRoot,
            [System.StringComparison]::OrdinalIgnoreCase
        )) {
            throw "Python path belongs to another Git repository: $PathValue"
        }
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

function Test-IsTestPythonPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $normalized = $Path.Replace("\", "/")
    return $normalized -match $script:TestPathPattern
}

function Split-PythonScope {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [string[]]$PythonPath
    )

    $productionPython = @()
    $testPython = @()
    foreach ($path in $PythonPath) {
        if (Test-IsTestPythonPath -Path $path) {
            $testPython += $path
        }
        else {
            $productionPython += $path
        }
    }

    return [pscustomobject]@{
        ProductionPython = @($productionPython)
        TestPython = @($testPython)
    }
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
    Write-Output "RESCUEBENCH_WORKSPACE_ROOT=$script:WorkspaceRoot"
    Write-Output "RESCUEBENCH_WORKTREE=$script:RepositoryRoot"
    Write-Output "RESCUEBENCH_REPOSITORY_KIND=$script:RepositoryKind"
    Write-Output "RESCUEBENCH_COMMON_GIT_DIR=$script:RepositoryCommonGitDirectory"
    Write-Output "RESCUEBENCH_BRANCH=$branch"
    Write-Output "RESCUEBENCH_HEAD=$head"
    Write-Output "RESCUEBENCH_CONFIG_PATH=$script:ConfigPath"
    Write-Output "RESCUEBENCH_CONFIG_SOURCE=$script:ConfigSource"
}

function Write-Scope {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [string[]]$PythonPath,

        [switch]$Committed
    )

    $scope = Split-PythonScope -PythonPath $PythonPath

    Write-RepositoryIdentity
    Write-Output "RESCUEBENCH_PYTHON_COUNT=$($PythonPath.Count)"
    Write-Output (
        "RESCUEBENCH_PRODUCTION_PYTHON_COUNT=" +
        $scope.ProductionPython.Count
    )
    Write-Output "RESCUEBENCH_TEST_PYTHON_COUNT=$($scope.TestPython.Count)"
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
        if (Test-IsTestPythonPath -Path $relative) {
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

function Invoke-UntrackedWhitespaceCheck {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [string[]]$PythonPath
    )

    $status = Get-CurrentStatusLookups
    $strictUtf8 = New-Object System.Text.UTF8Encoding($false, $true)
    $failures = 0
    foreach ($path in $PythonPath) {
        $relative = Assert-AllowedPythonPath -PathValue $path -MustExist
        if (-not $status.Untracked.ContainsKey($relative.ToLowerInvariant())) {
            continue
        }
        $fullPath = Join-Path $script:RepositoryRoot $relative
        $content = [System.IO.File]::ReadAllText($fullPath, $strictUtf8)
        $lines = [regex]::Split($content, "\r\n|\n|\r")
        for ($index = 0; $index -lt $lines.Count; $index += 1) {
            if ($lines[$index] -match '[ \t]+$') {
                Write-Host "${relative}:$($index + 1): trailing whitespace."
                $failures += 1
            }
        }
    }
    $exitCode = [int]($failures -gt 0)
    Write-Host "RESCUEBENCH_TOOL_EXIT=untracked-whitespace|$exitCode"
    return $exitCode
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

    $scope = Split-PythonScope -PythonPath $PythonPath
    Write-Host "RESCUEBENCH_PYLINT_SCOPE=production_only"
    Write-Host (
        "RESCUEBENCH_PYLINT_PYTHON_COUNT=" +
        $scope.ProductionPython.Count
    )
    Write-Host (
        "RESCUEBENCH_PYLINT_SKIPPED_TEST_COUNT=" +
        $scope.TestPython.Count
    )

    $failures = 0
    Push-Location $script:RepositoryRoot
    try {
        $ruffCheck = Invoke-CondaTool `
            -Label "ruff-check" `
            -ArgumentList (@(
                "python", "-m", "ruff", "check",
                "--config", $script:ConfigPath
            ) + $PythonPath)
        if ($ruffCheck -ne 0) {
            $failures += 1
        }

        $ruffFormat = Invoke-CondaTool `
            -Label "ruff-format-check" `
            -ArgumentList (@(
                "python", "-m", "ruff", "format",
                "--config", $script:ConfigPath, "--check"
            ) + $PythonPath)
        if ($ruffFormat -ne 0) {
            $failures += 1
        }

        if ($scope.ProductionPython.Count -gt 0) {
            $pylint = Invoke-CondaTool `
                -Label "pylint" `
                -ArgumentList (@(
                    "python", "-m", "pylint", "--rcfile=$script:ConfigPath"
                ) + $scope.ProductionPython)
            if ($pylint -ne 0) {
                $failures += 1
            }
        }
        else {
            Write-Host (
                "RESCUEBENCH_TOOL_SKIPPED=" +
                "pylint|no_production_python"
            )
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

        if (-not $Committed) {
            $untrackedWhitespace = Invoke-UntrackedWhitespaceCheck `
                -PythonPath $PythonPath
            if ($untrackedWhitespace -ne 0) {
                $failures += 1
            }
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
                "--config", $script:ConfigPath, "--fix"
            ) + $resolved)
        if ($fixExit -ne 0) {
            throw "Ruff safe-fix failed."
        }

        $formatExit = Invoke-CondaTool `
            -Label "ruff-format" `
            -ArgumentList (@(
                "python", "-m", "ruff", "format",
                "--config", $script:ConfigPath
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
Assert-ActionAllowedForRepository

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
