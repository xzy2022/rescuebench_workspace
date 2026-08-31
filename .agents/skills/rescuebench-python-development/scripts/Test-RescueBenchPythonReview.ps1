[CmdletBinding()]
param(
    [string]$HelperPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if (-not $HelperPath) {
    $HelperPath = Join-Path $PSScriptRoot "Invoke-RescueBenchPythonReview.ps1"
}
$helper = [System.IO.Path]::GetFullPath($HelperPath)
$windowsPowerShell = (Get-Command powershell.exe -ErrorAction Stop).Source
$gitExecutable = (Get-Command git.exe -ErrorAction Stop).Source
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$script:Assertions = 0

function Assert-True {
    param(
        [Parameter(Mandatory = $true)]
        [bool]$Condition,

        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    $script:Assertions += 1
    if (-not $Condition) {
        throw "ASSERTION_FAILED: $Message"
    }
}

function Assert-Equal {
    param(
        [AllowNull()]
        [object]$Expected,

        [AllowNull()]
        [object]$Actual,

        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    Assert-True `
        -Condition ($Expected -ceq $Actual) `
        -Message "$Message`nEXPECTED: $Expected`nACTUAL: $Actual"
}

function Write-Utf8Text {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Value
    )

    [System.IO.File]::WriteAllText($Path, $Value, $utf8NoBom)
}

function Invoke-Git {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Root,

        [Parameter(Mandatory = $true)]
        [string[]]$ArgumentList
    )

    $output = & $gitExecutable -C $Root @ArgumentList 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Git failed in ${Root}: $($output | Out-String)"
    }
    return $output
}

function Initialize-Repository {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    New-Item -ItemType Directory -Path $Path -Force | Out-Null
    & $gitExecutable -C $Path init --quiet
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to initialize fixture repository: $Path"
    }
    Invoke-Git -Root $Path -ArgumentList @("config", "user.name", "Review Fixture") |
        Out-Null
    Invoke-Git -Root $Path -ArgumentList @(
        "config", "user.email", "review@example.invalid"
    ) | Out-Null
    Invoke-Git -Root $Path -ArgumentList @("config", "core.autocrlf", "false") |
        Out-Null
}

function Commit-All {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Root,

        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    Invoke-Git -Root $Root -ArgumentList @("add", "--all") | Out-Null
    Invoke-Git -Root $Root -ArgumentList @("commit", "--quiet", "-m", $Message) |
        Out-Null
}

function Invoke-HelperProcess {
    param(
        [Parameter(Mandatory = $true)]
        [string]$WorkspaceRoot,

        [Parameter(Mandatory = $true)]
        [string]$RepositoryPath,

        [Parameter(Mandatory = $true)]
        [string[]]$ArgumentList
    )

    $previousPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $output = & $windowsPowerShell `
            -NoProfile `
            -ExecutionPolicy Bypass `
            -File $helper `
            -WorkspaceRoot $WorkspaceRoot `
            -RepositoryPath $RepositoryPath `
            @ArgumentList 2>&1
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousPreference
    }
    return [pscustomobject]@{
        ExitCode = $exitCode
        Output = (($output | Out-String).TrimEnd())
    }
}

function Get-RepositoryFingerprint {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Root
    )

    $status = Invoke-Git -Root $Root -ArgumentList @(
        "-c", "core.quotePath=false", "status", "--porcelain=v1"
    )
    $diff = Invoke-Git -Root $Root -ArgumentList @(
        "-c", "core.quotePath=false", "diff", "HEAD", "--"
    )
    $paths = Invoke-Git -Root $Root -ArgumentList @(
        "-c", "core.quotePath=false", "ls-files", "--cached", "--others",
        "--exclude-standard"
    )
    $hashes = foreach ($path in @($paths | Where-Object { $_ })) {
        $fullPath = Join-Path $Root $path
        if (Test-Path -LiteralPath $fullPath -PathType Leaf) {
            $hash = (Get-FileHash -LiteralPath $fullPath -Algorithm SHA256).Hash
            "${path}|${hash}"
        }
    }
    return (
        (@($status) -join "`n") + "`n---DIFF---`n" +
        (@($diff) -join "`n") + "`n---HASHES---`n" +
        (@($hashes | Sort-Object) -join "`n")
    )
}

function Assert-ParseablePowerShell {
    param([string]$Path)

    $tokens = $null
    $errors = $null
    [System.Management.Automation.Language.Parser]::ParseFile(
        $Path,
        [ref]$tokens,
        [ref]$errors
    ) | Out-Null
    Assert-True `
        -Condition ($errors.Count -eq 0) `
        -Message "PowerShell parse errors in $Path"
}

$testRoot = Join-Path (
    [System.IO.Path]::GetTempPath()
) ("rescuebench-review-" + [guid]::NewGuid().ToString("N"))
$testRoot = [System.IO.Path]::GetFullPath($testRoot)
$workspaceRoot = Join-Path $testRoot "workspace"
$reposRoot = Join-Path $workspaceRoot "repos"
$repositoryA = Join-Path $reposRoot "repo-a"
$repositoryB = Join-Path $reposRoot "repo-b"
$repositoryTests = Join-Path $reposRoot "repo-tests"
$repositoryMismatch = Join-Path $reposRoot "repo-mismatch"
$outsideRepository = Join-Path $testRoot "outside-repo"

$reviewConfig = @'
[tool.ruff]
target-version = "py311"
line-length = 88

[tool.ruff.lint]
select = ["E4", "E7", "E9", "F", "I", "B", "UP"]

[tool.pylint.main]
py-version = "3.11"
jobs = 1
persistent = false

[tool.pylint.format]
max-line-length = 88

[tool.pylint.design]
max-args = 2

[tool.pylint.reports]
reports = false
score = false
'@

try {
    Assert-True -Condition (Test-Path -LiteralPath $helper -PathType Leaf) `
        -Message "Helper does not exist."
    Assert-ParseablePowerShell -Path $helper
    Assert-ParseablePowerShell -Path $PSCommandPath

    Initialize-Repository -Path $workspaceRoot
    New-Item -ItemType Directory -Path $reposRoot -Force | Out-Null
    Write-Utf8Text -Path (Join-Path $workspaceRoot ".gitignore") `
        -Value "/repos/`n"
    Write-Utf8Text -Path (Join-Path $workspaceRoot "pyproject.toml") `
        -Value $reviewConfig
    Commit-All -Root $workspaceRoot -Message "Initialize outer workspace"

    Initialize-Repository -Path $repositoryA
    Write-Utf8Text -Path (Join-Path $repositoryA "committed.py") `
        -Value "`"`"`"Committed fixture.`"`"`"`n`nVALUE = 1`n"
    Write-Utf8Text -Path (Join-Path $repositoryA "modified.py") `
        -Value "`"`"`"Modified fixture.`"`"`"`n`nVALUE = 1`n"
    Commit-All -Root $repositoryA -Message "Initialize repository A"
    Write-Utf8Text -Path (Join-Path $repositoryA "modified.py") `
        -Value "`"`"`"Modified fixture.`"`"`"`n`nVALUE = 2`n"
    Write-Utf8Text -Path (Join-Path $repositoryA "staged.py") `
        -Value "`"`"`"Staged fixture.`"`"`"`n`nVALUE = 1`n"
    Invoke-Git -Root $repositoryA -ArgumentList @("add", "staged.py") |
        Out-Null
    Write-Utf8Text -Path (Join-Path $repositoryA "untracked.py") `
        -Value "`"`"`"Untracked fixture.`"`"`"`n`nVALUE = 1`n"
    New-Item -ItemType Directory -Path (Join-Path $repositoryA "src") |
        Out-Null

    Initialize-Repository -Path $repositoryB
    Write-Utf8Text -Path (Join-Path $repositoryB "pyproject.toml") `
        -Value $reviewConfig
    Write-Utf8Text -Path (Join-Path $repositoryB "committed.py") `
        -Value "`"`"`"Repository B fixture.`"`"`"`n`nVALUE = 1`n"
    Commit-All -Root $repositoryB -Message "Initialize repository B"
    Write-Utf8Text -Path (Join-Path $repositoryB "other.py") `
        -Value "`"`"`"Other repository fixture.`"`"`"`n`nVALUE = 1`n"

    Initialize-Repository -Path $repositoryMismatch
    Write-Utf8Text -Path (Join-Path $repositoryMismatch "pyproject.toml") `
        -Value ($reviewConfig -replace 'py-version = "3.11"', 'py-version = "3.8"')
    Write-Utf8Text -Path (Join-Path $repositoryMismatch "committed.py") `
        -Value "`"`"`"Mismatch fixture.`"`"`"`n`nVALUE = 1`n"
    Commit-All -Root $repositoryMismatch -Message "Initialize mismatch repository"
    Write-Utf8Text -Path (Join-Path $repositoryMismatch "changed.py") `
        -Value "`"`"`"Changed mismatch fixture.`"`"`"`n`nVALUE = 1`n"

    Initialize-Repository -Path $repositoryTests
    Write-Utf8Text -Path (Join-Path $repositoryTests "committed.py") `
        -Value "`"`"`"Committed test-repository fixture.`"`"`"`n`nVALUE = 1`n"
    Commit-All -Root $repositoryTests -Message "Initialize test-only repository"
    New-Item -ItemType Directory -Path (Join-Path $repositoryTests "tests") |
        Out-Null
    Write-Utf8Text `
        -Path (Join-Path $repositoryTests "tests\test_feedback.py") `
        -Value (
            "`"`"`"Pylint-only failure fixture.`"`"`"`n`n`n" +
            "def combine(first, second, third):`n" +
            "    `"`"`"Return every supplied value.`"`"`"`n" +
            "    return first, second, third`n"
        )
    Write-Utf8Text -Path (Join-Path $repositoryTests "test_root.py") `
        -Value "`"`"`"Root test fixture.`"`"`"`n`nVALUE = 1`n"
    Write-Utf8Text -Path (Join-Path $repositoryTests "feedback_test.py") `
        -Value "`"`"`"Suffix test fixture.`"`"`"`n`nVALUE = 1`n"
    Write-Utf8Text -Path (Join-Path $repositoryTests "conftest.py") `
        -Value "`"`"`"Pytest configuration fixture.`"`"`"`n`nVALUE = 1`n"

    Initialize-Repository -Path $outsideRepository
    Write-Utf8Text -Path (Join-Path $outsideRepository "outside.py") `
        -Value "`"`"`"Outside fixture.`"`"`"`n`nVALUE = 1`n"
    Commit-All -Root $outsideRepository -Message "Initialize outside repository"

    $beforeOuter = Get-RepositoryFingerprint -Root $workspaceRoot
    $beforeA = Get-RepositoryFingerprint -Root $repositoryA
    $beforeB = Get-RepositoryFingerprint -Root $repositoryB
    $beforeTests = Get-RepositoryFingerprint -Root $repositoryTests
    $beforeMismatch = Get-RepositoryFingerprint -Root $repositoryMismatch

    $outerScope = Invoke-HelperProcess `
        -WorkspaceRoot $workspaceRoot `
        -RepositoryPath $workspaceRoot `
        -ArgumentList @("-Action", "Scope")
    Assert-Equal -Expected 0 -Actual $outerScope.ExitCode `
        -Message "Outer Scope should pass."
    Assert-True `
        -Condition $outerScope.Output.Contains("RESCUEBENCH_REPOSITORY_KIND=outer") `
        -Message "Outer repository kind is missing."
    Assert-True `
        -Condition $outerScope.Output.Contains("RESCUEBENCH_PYTHON_COUNT=0") `
        -Message "Outer Scope should not enter ignored repositories."

    $probeA = Invoke-HelperProcess `
        -WorkspaceRoot $workspaceRoot `
        -RepositoryPath $repositoryA `
        -ArgumentList @("-Action", "Probe")
    Assert-Equal -Expected 0 -Actual $probeA.ExitCode `
        -Message "Independent Probe should pass."
    Assert-True `
        -Condition $probeA.Output.Contains("RESCUEBENCH_REPOSITORY_KIND=independent") `
        -Message "Independent repository kind is missing."
    Assert-True `
        -Condition $probeA.Output.Contains("RESCUEBENCH_CONFIG_SOURCE=workspace-fallback") `
        -Message "Workspace config fallback is missing."

    $scopeA = Invoke-HelperProcess `
        -WorkspaceRoot $workspaceRoot `
        -RepositoryPath $repositoryA `
        -ArgumentList @("-Action", "Scope")
    Assert-Equal -Expected 0 -Actual $scopeA.ExitCode `
        -Message "Independent Scope should pass."
    Assert-True `
        -Condition $scopeA.Output.Contains("RESCUEBENCH_PYTHON_COUNT=3") `
        -Message "Independent Scope count is incorrect."
    Assert-True `
        -Condition $scopeA.Output.Contains("modified.py|staged=0;unstaged=1;untracked=0") `
        -Message "Unstaged Python state is missing."
    Assert-True `
        -Condition $scopeA.Output.Contains("staged.py|staged=1;unstaged=0;untracked=0") `
        -Message "Staged Python state is missing."
    Assert-True `
        -Condition $scopeA.Output.Contains("untracked.py|staged=0;unstaged=0;untracked=1") `
        -Message "Untracked Python state is missing."
    Assert-True -Condition (-not $scopeA.Output.Contains("committed.py")) `
        -Message "Committed Python should not enter ordinary Scope."
    Assert-True -Condition (-not $scopeA.Output.Contains("other.py")) `
        -Message "Another repository should not enter Scope."

    $checkAWithoutTarget = Invoke-HelperProcess `
        -WorkspaceRoot $workspaceRoot `
        -RepositoryPath $repositoryA `
        -ArgumentList @("-Action", "CheckChanged")
    Assert-True -Condition ($checkAWithoutTarget.ExitCode -ne 0) `
        -Message "Workspace-fallback CheckChanged should require a target version."
    Assert-True `
        -Condition $checkAWithoutTarget.Output.Contains("independent-workspace-fallback") `
        -Message "Missing target-version failure reason is absent."

    $fixAWithoutTarget = Invoke-HelperProcess `
        -WorkspaceRoot $workspaceRoot `
        -RepositoryPath $repositoryA `
        -ArgumentList @(
            "-Action", "FixExplicit", "-PythonFile", "untracked.py"
        )
    Assert-True -Condition ($fixAWithoutTarget.ExitCode -ne 0) `
        -Message "Workspace-fallback FixExplicit should require a target version."
    Assert-Equal -Expected $beforeA `
        -Actual (Get-RepositoryFingerprint -Root $repositoryA) `
        -Message "Missing target version changed repository A."

    $explicitProbe = Invoke-HelperProcess `
        -WorkspaceRoot $workspaceRoot `
        -RepositoryPath $repositoryA `
        -ArgumentList @(
            "-Action", "Probe", "-TargetPythonVersion", "3.8.10"
        )
    Assert-Equal -Expected 0 -Actual $explicitProbe.ExitCode `
        -Message "Explicit target-version Probe should pass."
    Assert-True `
        -Condition $explicitProbe.Output.Contains("RESCUEBENCH_TARGET_PYTHON_EFFECTIVE=3.8") `
        -Message "Patch target version was not normalized."
    Assert-True `
        -Condition $explicitProbe.Output.Contains("RESCUEBENCH_RUFF_TARGET_VERSION=py38") `
        -Message "Ruff target version was not derived."
    Assert-True `
        -Condition $explicitProbe.Output.Contains("RESCUEBENCH_PYLINT_TARGET_VERSION=3.8") `
        -Message "Pylint target version was not derived."

    $invalidTarget = Invoke-HelperProcess `
        -WorkspaceRoot $workspaceRoot `
        -RepositoryPath $repositoryA `
        -ArgumentList @(
            "-Action", "Probe", "-TargetPythonVersion", "2.7"
        )
    Assert-True -Condition ($invalidTarget.ExitCode -ne 0) `
        -Message "A non-Python-3 target should be rejected."

    $checkA = Invoke-HelperProcess `
        -WorkspaceRoot $workspaceRoot `
        -RepositoryPath $repositoryA `
        -ArgumentList @(
            "-Action", "CheckChanged", "-TargetPythonVersion", "3.11"
        )
    Assert-Equal -Expected 0 -Actual $checkA.ExitCode `
        -Message "Independent CheckChanged should pass."
    Assert-True `
        -Condition $checkA.Output.Contains("RESCUEBENCH_CHECK_RESULT=pass") `
        -Message "Independent CheckChanged pass marker is missing."

    $scopeB = Invoke-HelperProcess `
        -WorkspaceRoot $workspaceRoot `
        -RepositoryPath $repositoryB `
        -ArgumentList @("-Action", "Scope")
    Assert-Equal -Expected 0 -Actual $scopeB.ExitCode `
        -Message "Second independent Scope should pass."
    Assert-True `
        -Condition $scopeB.Output.Contains("RESCUEBENCH_CONFIG_SOURCE=repository-native") `
        -Message "Repository-native config source is missing."
    Assert-True `
        -Condition $scopeB.Output.Contains("RESCUEBENCH_PYTHON_COUNT=1") `
        -Message "Second repository Scope is not isolated."
    Assert-True `
        -Condition $scopeB.Output.Contains("RESCUEBENCH_TARGET_PYTHON_EFFECTIVE=3.11") `
        -Message "Repository-native target version is missing."

    $mismatchScope = Invoke-HelperProcess `
        -WorkspaceRoot $workspaceRoot `
        -RepositoryPath $repositoryMismatch `
        -ArgumentList @("-Action", "Scope")
    Assert-Equal -Expected 0 -Actual $mismatchScope.ExitCode `
        -Message "Mismatch Scope should remain read-only and report its state."
    Assert-True `
        -Condition $mismatchScope.Output.Contains("RESCUEBENCH_TARGET_PYTHON_REASON=config-target-mismatch") `
        -Message "Config target mismatch is not reported."
    $mismatchCheck = Invoke-HelperProcess `
        -WorkspaceRoot $workspaceRoot `
        -RepositoryPath $repositoryMismatch `
        -ArgumentList @("-Action", "CheckChanged")
    Assert-True -Condition ($mismatchCheck.ExitCode -ne 0) `
        -Message "Mismatched native targets should fail review."
    $mismatchOverride = Invoke-HelperProcess `
        -WorkspaceRoot $workspaceRoot `
        -RepositoryPath $repositoryMismatch `
        -ArgumentList @(
            "-Action", "CheckChanged", "-TargetPythonVersion", "3.8"
        )
    Assert-Equal -Expected 0 -Actual $mismatchOverride.ExitCode `
        -Message "Explicit target should override mismatched config targets."
    Assert-Equal -Expected $beforeMismatch `
        -Actual (Get-RepositoryFingerprint -Root $repositoryMismatch) `
        -Message "Mismatch review changed its repository."

    $testOnlyScope = Invoke-HelperProcess `
        -WorkspaceRoot $workspaceRoot `
        -RepositoryPath $repositoryTests `
        -ArgumentList @("-Action", "Scope")
    Assert-Equal -Expected 0 -Actual $testOnlyScope.ExitCode `
        -Message "Test-only Scope should pass."
    Assert-True `
        -Condition $testOnlyScope.Output.Contains("RESCUEBENCH_PYTHON_COUNT=4") `
        -Message "Test-only total count is incorrect."
    Assert-True `
        -Condition $testOnlyScope.Output.Contains("RESCUEBENCH_PRODUCTION_PYTHON_COUNT=0") `
        -Message "Test-only production count is incorrect."
    Assert-True `
        -Condition $testOnlyScope.Output.Contains("RESCUEBENCH_TEST_PYTHON_COUNT=4") `
        -Message "Test-only test count is incorrect."
    foreach ($testPath in @(
        "tests/test_feedback.py",
        "test_root.py",
        "feedback_test.py",
        "conftest.py"
    )) {
        Assert-True `
            -Condition $testOnlyScope.Output.Contains("RESCUEBENCH_TEST_PYTHON=$testPath|") `
            -Message "Test classification is missing for $testPath."
    }

    $testOnlyCheck = Invoke-HelperProcess `
        -WorkspaceRoot $workspaceRoot `
        -RepositoryPath $repositoryTests `
        -ArgumentList @(
            "-Action", "CheckChanged", "-TargetPythonVersion", "3.11"
        )
    Assert-Equal -Expected 0 -Actual $testOnlyCheck.ExitCode `
        -Message (
            "Test-only CheckChanged should pass without Pylint.`n" +
            "OUTPUT:`n$($testOnlyCheck.Output)"
        )
    Assert-True `
        -Condition $testOnlyCheck.Output.Contains("RESCUEBENCH_PYLINT_SCOPE=production_only") `
        -Message "Production-only Pylint scope marker is missing."
    Assert-True `
        -Condition $testOnlyCheck.Output.Contains("RESCUEBENCH_PYLINT_PYTHON_COUNT=0") `
        -Message "Test-only Pylint count is incorrect."
    Assert-True `
        -Condition $testOnlyCheck.Output.Contains("RESCUEBENCH_PYLINT_SKIPPED_TEST_COUNT=4") `
        -Message "Test-only Pylint skipped count is incorrect."
    Assert-True `
        -Condition $testOnlyCheck.Output.Contains("RESCUEBENCH_TOOL_SKIPPED=pylint|no_production_python") `
        -Message "Test-only Pylint skip marker is missing."
    Assert-True `
        -Condition (-not $testOnlyCheck.Output.Contains("RESCUEBENCH_TOOL_EXIT=pylint|")) `
        -Message "Pylint unexpectedly ran for a test-only scope."
    Assert-True `
        -Condition $testOnlyCheck.Output.Contains("RESCUEBENCH_CHECK_RESULT=pass") `
        -Message "Test-only CheckChanged pass marker is missing."
    Assert-Equal -Expected $beforeTests `
        -Actual (Get-RepositoryFingerprint -Root $repositoryTests) `
        -Message "Test-only read-only actions changed their repository."

    Write-Utf8Text -Path (Join-Path $repositoryTests "clean.py") `
        -Value "`"`"`"Clean production fixture.`"`"`"`n`nVALUE = 1`n"
    $mixedCheck = Invoke-HelperProcess `
        -WorkspaceRoot $workspaceRoot `
        -RepositoryPath $repositoryTests `
        -ArgumentList @(
            "-Action", "CheckChanged", "-TargetPythonVersion", "3.11"
        )
    Assert-Equal -Expected 0 -Actual $mixedCheck.ExitCode `
        -Message "Mixed production/test CheckChanged should pass."
    Assert-True `
        -Condition $mixedCheck.Output.Contains("RESCUEBENCH_PYLINT_PYTHON_COUNT=1") `
        -Message "Mixed-scope Pylint production count is incorrect."
    Assert-True `
        -Condition $mixedCheck.Output.Contains("RESCUEBENCH_PYLINT_SKIPPED_TEST_COUNT=4") `
        -Message "Mixed-scope Pylint skipped count is incorrect."
    Assert-True `
        -Condition $mixedCheck.Output.Contains("RESCUEBENCH_TOOL_EXIT=pylint|0") `
        -Message "Mixed-scope production Pylint did not pass."

    Write-Utf8Text -Path (Join-Path $repositoryTests "bad_pylint.py") `
        -Value (
            "`"`"`"Production Pylint failure fixture.`"`"`"`n`n`n" +
            "def combine(first, second, third):`n" +
            "    `"`"`"Return every supplied value.`"`"`"`n" +
            "    return first, second, third`n"
        )
    $productionPylintFailure = Invoke-HelperProcess `
        -WorkspaceRoot $workspaceRoot `
        -RepositoryPath $repositoryTests `
        -ArgumentList @(
            "-Action", "CheckChanged", "-TargetPythonVersion", "3.11"
        )
    Assert-True -Condition ($productionPylintFailure.ExitCode -ne 0) `
        -Message "A production Pylint failure should fail CheckChanged."
    Assert-True `
        -Condition ($productionPylintFailure.Output -match "RESCUEBENCH_TOOL_EXIT=pylint\|[1-9]") `
        -Message "Production Pylint failure marker is missing."
    Remove-Item -LiteralPath (Join-Path $repositoryTests "bad_pylint.py") -Force

    Write-Utf8Text `
        -Path (Join-Path $repositoryTests "tests\test_bad_ruff.py") `
        -Value "`"`"`"Test Ruff failure fixture.`"`"`"`n`nVALUE = missing_name`n"
    $testRuffFailure = Invoke-HelperProcess `
        -WorkspaceRoot $workspaceRoot `
        -RepositoryPath $repositoryTests `
        -ArgumentList @(
            "-Action", "CheckChanged", "-TargetPythonVersion", "3.11"
        )
    Assert-True -Condition ($testRuffFailure.ExitCode -ne 0) `
        -Message "A test Ruff failure should fail CheckChanged."
    Assert-True `
        -Condition ($testRuffFailure.Output -match "RESCUEBENCH_TOOL_EXIT=ruff-check\|[1-9]") `
        -Message "Test Ruff failure marker is missing."
    Remove-Item `
        -LiteralPath (Join-Path $repositoryTests "tests\test_bad_ruff.py") `
        -Force

    Commit-All -Root $repositoryTests -Message "Commit mixed review fixtures"
    Write-Utf8Text `
        -Path (Join-Path $repositoryTests "tests\test_fix_me.py") `
        -Value "`"`"`"Test formatting fixture.`"`"`"`n`nVALUE=1`n"
    $testFix = Invoke-HelperProcess `
        -WorkspaceRoot $workspaceRoot `
        -RepositoryPath $repositoryTests `
        -ArgumentList @(
            "-Action", "FixExplicit",
            "-TargetPythonVersion", "3.11",
            "-PythonFile", "tests/test_fix_me.py"
        )
    Assert-Equal -Expected 0 -Actual $testFix.ExitCode `
        -Message "FixExplicit should format a test-only scope."
    Assert-True `
        -Condition $testFix.Output.Contains("RESCUEBENCH_TOOL_SKIPPED=pylint|no_production_python") `
        -Message "Test-only FixExplicit did not skip Pylint."
    $fixedTestContent = [System.IO.File]::ReadAllText(
        (Join-Path $repositoryTests "tests\test_fix_me.py")
    )
    Assert-True -Condition $fixedTestContent.Contains("VALUE = 1") `
        -Message "FixExplicit did not format the test fixture file."

    $reposDirectory = Invoke-HelperProcess `
        -WorkspaceRoot $workspaceRoot `
        -RepositoryPath $reposRoot `
        -ArgumentList @("-Action", "Scope")
    Assert-True -Condition ($reposDirectory.ExitCode -ne 0) `
        -Message "The repos directory itself should be rejected."

    $nestedDirectory = Invoke-HelperProcess `
        -WorkspaceRoot $workspaceRoot `
        -RepositoryPath (Join-Path $repositoryA "src") `
        -ArgumentList @("-Action", "Scope")
    Assert-True -Condition ($nestedDirectory.ExitCode -ne 0) `
        -Message "A directory inside an independent repository should be rejected."

    $outside = Invoke-HelperProcess `
        -WorkspaceRoot $workspaceRoot `
        -RepositoryPath $outsideRepository `
        -ArgumentList @("-Action", "Scope")
    Assert-True -Condition ($outside.ExitCode -ne 0) `
        -Message "A repository outside workspace repos/ should be rejected."

    $verify = Invoke-HelperProcess `
        -WorkspaceRoot $workspaceRoot `
        -RepositoryPath $repositoryA `
        -ArgumentList @("-Action", "VerifyCommitted", "-BaseRevision", "HEAD~1")
    Assert-True -Condition ($verify.ExitCode -ne 0) `
        -Message "VerifyCommitted should be rejected for independent repositories."
    Assert-True -Condition $verify.Output.Contains("is not allowed") `
        -Message "Independent VerifyCommitted rejection reason is missing."

    $fullAudit = Invoke-HelperProcess `
        -WorkspaceRoot $workspaceRoot `
        -RepositoryPath $repositoryA `
        -ArgumentList @("-Action", "FullWorkspaceAudit", "-FullAuditAuthorized")
    Assert-True -Condition ($fullAudit.ExitCode -ne 0) `
        -Message "FullWorkspaceAudit should be rejected for independent repositories."

    $committedFix = Invoke-HelperProcess `
        -WorkspaceRoot $workspaceRoot `
        -RepositoryPath $repositoryA `
        -ArgumentList @(
            "-Action", "FixExplicit",
            "-TargetPythonVersion", "3.11",
            "-PythonFile", "committed.py"
        )
    Assert-True -Condition ($committedFix.ExitCode -ne 0) `
        -Message "FixExplicit should reject committed Python."
    Assert-True -Condition $committedFix.Output.Contains("not in the current Python change set") `
        -Message "Committed FixExplicit rejection reason is missing."

    $crossRepositoryFix = Invoke-HelperProcess `
        -WorkspaceRoot $workspaceRoot `
        -RepositoryPath $repositoryA `
        -ArgumentList @(
            "-Action", "FixExplicit",
            "-TargetPythonVersion", "3.11",
            "-PythonFile", (Join-Path $repositoryB "other.py")
        )
    Assert-True -Condition ($crossRepositoryFix.ExitCode -ne 0) `
        -Message "FixExplicit should reject a file from another repository."

    $directoryFix = Invoke-HelperProcess `
        -WorkspaceRoot $workspaceRoot `
        -RepositoryPath $repositoryA `
        -ArgumentList @(
            "-Action", "FixExplicit",
            "-TargetPythonVersion", "3.11",
            "-PythonFile", "."
        )
    Assert-True -Condition ($directoryFix.ExitCode -ne 0) `
        -Message "FixExplicit should reject a directory."

    Assert-Equal -Expected $beforeOuter `
        -Actual (Get-RepositoryFingerprint -Root $workspaceRoot) `
        -Message "Read-only actions changed the outer workspace."
    Assert-Equal -Expected $beforeA `
        -Actual (Get-RepositoryFingerprint -Root $repositoryA) `
        -Message "Read-only actions changed repository A."
    Assert-Equal -Expected $beforeB `
        -Actual (Get-RepositoryFingerprint -Root $repositoryB) `
        -Message "Read-only actions changed repository B."

    $compatibilityFixture = (
        "`"`"`"Target-version compatibility fixture.`"`"`"`n`n" +
        "from typing import Tuple, cast`n`n" +
        "VALUE = cast(Tuple[int, ...], (1,))`n"
    )
    Write-Utf8Text -Path (Join-Path $repositoryA "compat_py38.py") `
        -Value $compatibilityFixture
    $compatibilityFix = Invoke-HelperProcess `
        -WorkspaceRoot $workspaceRoot `
        -RepositoryPath $repositoryA `
        -ArgumentList @(
            "-Action", "FixExplicit",
            "-TargetPythonVersion", "3.8",
            "-PythonFile", "compat_py38.py"
        )
    Assert-Equal -Expected 0 -Actual $compatibilityFix.ExitCode `
        -Message "Python 3.8 compatibility FixExplicit should pass."
    Assert-True `
        -Condition $compatibilityFix.Output.Contains("RESCUEBENCH_RUFF_TARGET_VERSION=py38") `
        -Message "FixExplicit did not report the Python 3.8 Ruff target."
    $compatibilityContent = [System.IO.File]::ReadAllText(
        (Join-Path $repositoryA "compat_py38.py")
    )
    Assert-True -Condition $compatibilityContent.Contains("Tuple[int, ...]") `
        -Message "Ruff changed typing.Tuple for a Python 3.8 target."
    Assert-True -Condition (-not $compatibilityContent.Contains("tuple[int, ...]")) `
        -Message "Ruff introduced a PEP 585 generic for a Python 3.8 target."
    Remove-Item -LiteralPath (Join-Path $repositoryA "compat_py38.py") -Force

    Write-Utf8Text -Path (Join-Path $repositoryA "compat_py311.py") `
        -Value $compatibilityFixture
    $modernFix = Invoke-HelperProcess `
        -WorkspaceRoot $workspaceRoot `
        -RepositoryPath $repositoryA `
        -ArgumentList @(
            "-Action", "FixExplicit",
            "-TargetPythonVersion", "3.11",
            "-PythonFile", "compat_py311.py"
        )
    Assert-Equal -Expected 0 -Actual $modernFix.ExitCode `
        -Message "Python 3.11 FixExplicit should pass."
    $modernContent = [System.IO.File]::ReadAllText(
        (Join-Path $repositoryA "compat_py311.py")
    )
    Assert-True -Condition $modernContent.Contains("tuple[int, ...]") `
        -Message "Ruff did not apply the Python 3.11 PEP 585 upgrade."
    Remove-Item -LiteralPath (Join-Path $repositoryA "compat_py311.py") -Force

    Write-Utf8Text -Path (Join-Path $repositoryA "bad.py") `
        -Value "`"`"`"Bad whitespace fixture.`"`"`"   `n"
    $badWhitespace = Invoke-HelperProcess `
        -WorkspaceRoot $workspaceRoot `
        -RepositoryPath $repositoryA `
        -ArgumentList @(
            "-Action", "CheckChanged", "-TargetPythonVersion", "3.11"
        )
    Assert-True -Condition ($badWhitespace.ExitCode -ne 0) `
        -Message "Untracked trailing whitespace should fail CheckChanged."
    Assert-True `
        -Condition $badWhitespace.Output.Contains("RESCUEBENCH_TOOL_EXIT=untracked-whitespace|1") `
        -Message "Untracked whitespace failure marker is missing."
    Remove-Item -LiteralPath (Join-Path $repositoryA "bad.py") -Force

    Write-Utf8Text -Path (Join-Path $repositoryA "fix_me.py") `
        -Value "`"`"`"Fix fixture.`"`"`"`n`nVALUE=1`n"
    $fix = Invoke-HelperProcess `
        -WorkspaceRoot $workspaceRoot `
        -RepositoryPath $repositoryA `
        -ArgumentList @(
            "-Action", "FixExplicit",
            "-TargetPythonVersion", "3.11",
            "-PythonFile", "fix_me.py"
        )
    Assert-Equal -Expected 0 -Actual $fix.ExitCode `
        -Message "FixExplicit should accept a changed file in the selected repository."
    $fixedContent = [System.IO.File]::ReadAllText(
        (Join-Path $repositoryA "fix_me.py")
    )
    Assert-True -Condition $fixedContent.Contains("VALUE = 1") `
        -Message "FixExplicit did not format the explicit fixture file."

    Commit-All -Root $repositoryA -Message "Commit current worktree changes"
    $committedScope = Invoke-HelperProcess `
        -WorkspaceRoot $workspaceRoot `
        -RepositoryPath $repositoryA `
        -ArgumentList @("-Action", "Scope")
    Assert-Equal -Expected 0 -Actual $committedScope.ExitCode `
        -Message "Scope should pass after committing fixture changes."
    Assert-True `
        -Condition $committedScope.Output.Contains("RESCUEBENCH_PYTHON_COUNT=0") `
        -Message "Committed Python should disappear from ordinary Scope."

    Write-Output "RESCUEBENCH_REVIEW_SELF_TEST_ASSERTIONS=$script:Assertions"
    Write-Output "RESCUEBENCH_REVIEW_SELF_TEST=pass"
}
finally {
    $tempRoot = [System.IO.Path]::GetFullPath(
        [System.IO.Path]::GetTempPath()
    ).TrimEnd("\") + "\"
    if (-not $testRoot.StartsWith(
        $tempRoot,
        [System.StringComparison]::OrdinalIgnoreCase
    )) {
        throw "Refusing to remove fixture outside the system temp directory: $testRoot"
    }
    if (Test-Path -LiteralPath $testRoot -PathType Container) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
}
