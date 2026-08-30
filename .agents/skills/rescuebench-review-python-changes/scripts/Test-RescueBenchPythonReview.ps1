[CmdletBinding()]
param(
    [string]$RepositoryPath = "D:\Workspace\00_MyRepo\Rescubench",
    [string]$HelperPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if (-not $HelperPath) {
    $HelperPath = Join-Path $PSScriptRoot "Invoke-RescueBenchPythonReview.ps1"
}
$repositoryRoot = [System.IO.Path]::GetFullPath($RepositoryPath).TrimEnd("\")
$helper = [System.IO.Path]::GetFullPath($HelperPath)
$windowsPowerShell = (Get-Command powershell.exe -ErrorAction Stop).Source
$gitExecutable = (Get-Command git.exe -ErrorAction Stop).Source
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

function Invoke-HelperProcess {
    param(
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

function Get-WorkspaceFingerprint {
    $status = & $gitExecutable `
        -C $repositoryRoot `
        -c core.quotePath=false `
        status --porcelain=v1
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to read Git status."
    }
    $pythonDiff = & $gitExecutable `
        -C $repositoryRoot `
        -c core.quotePath=false `
        diff HEAD -- "*.py"
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to read Python diff."
    }
    return (($status -join "`n") + "`n---PYTHON-DIFF---`n" + ($pythonDiff -join "`n"))
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

Assert-True -Condition (Test-Path -LiteralPath $helper -PathType Leaf) `
    -Message "Helper does not exist."
Assert-True -Condition (Test-Path -LiteralPath $repositoryRoot -PathType Container) `
    -Message "Repository does not exist."
Assert-ParseablePowerShell -Path $helper
Assert-ParseablePowerShell -Path $PSCommandPath

$before = Get-WorkspaceFingerprint

$probe = Invoke-HelperProcess -ArgumentList @(
    "-RepositoryPath", $repositoryRoot,
    "-Action", "Probe"
)
Assert-Equal -Expected 0 -Actual $probe.ExitCode -Message "Probe should pass."
Assert-True `
    -Condition $probe.Output.Contains("RESCUEBENCH_PROBE_RESULT=pass") `
    -Message "Probe pass marker is missing."

$scope = Invoke-HelperProcess -ArgumentList @(
    "-RepositoryPath", $repositoryRoot,
    "-Action", "Scope"
)
Assert-Equal -Expected 0 -Actual $scope.ExitCode -Message "Scope should pass."
Assert-True `
    -Condition $scope.Output.Contains("RESCUEBENCH_PYTHON_COUNT=") `
    -Message "Scope count marker is missing."
Assert-True `
    -Condition (-not $scope.Output.Contains("RESCUEBENCH_PRODUCTION_PYTHON=repos/")) `
    -Message "Scope entered repos/."
Assert-True `
    -Condition (-not $scope.Output.Contains("RESCUEBENCH_TEST_PYTHON=repos/")) `
    -Message "Test scope entered repos/."

$nestedRepository = Join-Path $repositoryRoot "repos\RescueBench"
if (Test-Path -LiteralPath $nestedRepository -PathType Container) {
    $nested = Invoke-HelperProcess -ArgumentList @(
        "-RepositoryPath", $nestedRepository,
        "-Action", "Scope"
    )
    Assert-True -Condition ($nested.ExitCode -ne 0) `
        -Message "Nested repository should be rejected."
    Assert-True -Condition $nested.Output.Contains("Refusing repository under repos/") `
        -Message "Nested repository rejection reason is missing."
}

$fullAudit = Invoke-HelperProcess -ArgumentList @(
    "-RepositoryPath", $repositoryRoot,
    "-Action", "FullWorkspaceAudit"
)
Assert-True -Condition ($fullAudit.ExitCode -ne 0) `
    -Message "Unauthorized full audit should fail."
Assert-True -Condition $fullAudit.Output.Contains("requires -FullAuditAuthorized") `
    -Message "Full-audit authorization error is missing."

$verify = Invoke-HelperProcess -ArgumentList @(
    "-RepositoryPath", $repositoryRoot,
    "-Action", "VerifyCommitted"
)
Assert-True -Condition ($verify.ExitCode -ne 0) `
    -Message "VerifyCommitted without a base should fail."
Assert-True -Condition $verify.Output.Contains("requires explicit -BaseRevision") `
    -Message "Base-revision error is missing."

$forbiddenFix = Invoke-HelperProcess -ArgumentList @(
    "-RepositoryPath", $repositoryRoot,
    "-Action", "FixExplicit",
    "-PythonFile", "repos/RescueBench/forbidden.py"
)
Assert-True -Condition ($forbiddenFix.ExitCode -ne 0) `
    -Message "FixExplicit should reject repos/."
Assert-True -Condition $forbiddenFix.Output.Contains("under forbidden repos/") `
    -Message "Forbidden-path error is missing."

$directoryFix = Invoke-HelperProcess -ArgumentList @(
    "-RepositoryPath", $repositoryRoot,
    "-Action", "FixExplicit",
    "-PythonFile", "."
)
Assert-True -Condition ($directoryFix.ExitCode -ne 0) `
    -Message "FixExplicit should reject a directory."
Assert-True -Condition (
    $directoryFix.Output.Contains("not a Python file") -or
    $directoryFix.Output.Contains("outside the outer workspace")
) `
    -Message "Directory rejection reason is missing."

$after = Get-WorkspaceFingerprint
Assert-Equal `
    -Expected $before `
    -Actual $after `
    -Message "Read-only and rejected actions changed the workspace."

Write-Output "RESCUEBENCH_REVIEW_SELF_TEST_ASSERTIONS=$script:Assertions"
Write-Output "RESCUEBENCH_REVIEW_SELF_TEST=pass"
