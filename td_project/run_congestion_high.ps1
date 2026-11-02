$ErrorActionPreference = 'Stop'
$congestionWorkspace = Split-Path -Parent $PSScriptRoot
$congestionRun = Join-Path $PSScriptRoot 'anlogic_edge_osd_Runs\phy_1'
$congestionDriver = Join-Path $congestionWorkspace 'verification\run_image_quality_build.ps1'
try {
    # Reuse the existing final-route and timing checks without running its build.
    $parseTokens = $null
    $parseErrors = $null
    $driverAst = [Management.Automation.Language.Parser]::ParseFile(
        $congestionDriver, [ref]$parseTokens, [ref]$parseErrors)
    if ($parseErrors.Count) { throw 'Cannot parse existing build validation functions' }
    foreach ($functionName in @('Assert-RouteCompletion', 'Assert-FinalTiming',
            'Assert-DisplayEffectConstraintHealth', 'Assert-TargetFrameConstraintHealth',
            'Assert-AeConstraintHealth')) {
        $definition = $driverAst.Find({ param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -eq $functionName
        }, $true)
        if ($null -eq $definition) { throw "Missing validation function: $functionName" }
        . ([scriptblock]::Create($definition.Extent.Text))
    }
    Set-Location -LiteralPath $congestionRun
    Write-Output 'CONGESTIONHIGH_BUILD_STARTED output=td_project/anlogic_edge_osd_Runs/phy_1'
    $congestionTcl = (Join-Path $PSScriptRoot 'run_congestion_high.tcl').Replace('\', '/')
    & 'D:\TD\bin\td_commands_prompt.exe' $congestionTcl *> run.log
    if ($LASTEXITCODE -ne 0) { throw "TD failed with exit code $LASTEXITCODE; see run.log" }
    $consoleText = [IO.File]::ReadAllText((Join-Path $congestionRun 'run.log'))
    if ($consoleText -notmatch 'CONGESTIONHIGH_FLOW_COMPLETE_PENDING_ACCEPTANCE') {
        throw 'TD flow did not complete'
    }
    $routeResult = Assert-RouteCompletion (Join-Path $congestionRun 'anlogic_edge_osd_route.status') $consoleText
    $timingResult = Assert-FinalTiming (Join-Path $congestionRun 'anlogic_edge_osd_pr.timing') (Join-Path $congestionRun 'route.qor')
    $constraintReport = Join-Path $congestionRun 'constraint_health.timing'
    $null = Assert-DisplayEffectConstraintHealth $constraintReport
    $null = Assert-TargetFrameConstraintHealth $constraintReport
    $null = Assert-AeConstraintHealth $constraintReport (Join-Path $PSScriptRoot 'anlogic_edge_osd.sdc')
    Write-Output "CONGESTIONHIGH_ACCEPTED open_nets=0 setup=$($timingResult.SWNS)ns hold=$($timingResult.HWNS)ns"
    exit 0
} catch {
    Write-Output "CONGESTIONHIGH_FAILED: $($_.Exception.Message)"
    exit 1
}
