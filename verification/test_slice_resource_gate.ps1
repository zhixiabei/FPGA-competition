param([string] $TdBin='D:\TD\bin')
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$root=Split-Path -Parent $PSScriptRoot
$driver=Join-Path $PSScriptRoot 'run_image_quality_build.ps1'
$area=Join-Path $root 'build\slice_compression\baseline_project\build\release\system_phy.area'
$gateArea=Join-Path $root 'build\slice_compression\baseline_release\release\system_gate.area'
$tokens=$null
$parseErrors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($driver,[ref]$tokens,[ref]$parseErrors)
if($parseErrors.Count) {throw "Build driver parse failed: $parseErrors"}
$assignments=@($ast.FindAll({
    param($node)
    $node -is [Management.Automation.Language.AssignmentStatementAst] -and
        $node.Left.Extent.Text -eq '$resourceGate' -and
        $node.Right.Extent.Text.StartsWith("@'")
},$true))
if($assignments.Count -ne 1) {throw 'Expected one literal TD resource gate in the build driver'}
$literal=@($assignments[0].Right.FindAll({
    param($node)
    $node -is [Management.Automation.Language.StringConstantExpressionAst]
},$true))
if($literal.Count -ne 1) {throw 'Resource gate must be a single literal string'}
$gate=$literal[0].Value
$areaText=[IO.File]::ReadAllText($area)
$usage=@{}
foreach($resource in @('slice','lut6','reg','eram','dsp')) {
    $match=[regex]::Match($areaText,'(?m)^#'+$resource+'\s+(\d+)')
    if(-not $match.Success) {throw "Baseline physical report lacks $resource"}
    $usage[$resource]=[int]$match.Groups[1].Value
}
$cases=@([pscustomobject]@{Name='equal_limits';Limits=$usage;Report=$area;Failure=''})
foreach($resource in @('slice','lut6','reg','eram','dsp')) {
    $limits=$usage.Clone()
    $limits[$resource]=$usage[$resource]-1
    $cases+=[pscustomobject]@{
        Name=('exceeds_'+$resource);Limits=$limits;Report=$area
        Failure=("Final resource budget failed: $resource=")
    }
}
$cases+=[pscustomobject]@{
    Name='reject_gate_slice_estimate';Limits=@{slice=99999};Report=$gateArea
    Failure='Missing final physical resource: slice'
}
$work=Join-Path $env:TEMP ('anlogic_resource_gate_'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $work | Out-Null
Write-Output "Resource gate test output: $work"
foreach($case in $cases) {
    $caseDir=Join-Path $work $case.Name
    New-Item -ItemType Directory -Path $caseDir | Out-Null
    Copy-Item -LiteralPath $case.Report -Destination (Join-Path $caseDir 'system_phy.area')
    $pairs=($case.Limits.GetEnumerator() | Sort-Object Key |
        ForEach-Object { "$($_.Key) $($_.Value)" }) -join ' '
    $script=@'
set root [file dirname [file normalize [info script]]]
cd $root
if {[catch {
GATE_COMMANDS
    puts "RESOURCE_GATE_REACHED_BITGEN"
} detail]} {
    puts stderr "RESOURCE_GATE_FAILURE: $detail"
    exit 1
}
exit 0
'@
    $script=$script.Replace('GATE_COMMANDS',$gate.Replace('RESOURCE_LIMITS',$pairs))
    [IO.File]::WriteAllText((Join-Path $caseDir 'check.tcl'),$script,[Text.UTF8Encoding]::new($false))
    Push-Location $caseDir
    try {
        & (Join-Path $TdBin 'td_commands_prompt.exe') check.tcl *> console.log
        $exitCode=$LASTEXITCODE
        $console=[IO.File]::ReadAllText((Join-Path $caseDir 'console.log'))
        $reached=$console.Contains('RESOURCE_GATE_REACHED_BITGEN')
        if($case.Failure) {
            if($exitCode -eq 0 -or $reached -or -not $console.Contains($case.Failure)) {
                throw "Resource gate failed to reject $($case.Name): $caseDir\console.log"
            }
        } elseif($exitCode -ne 0 -or -not $reached -or
                 -not $console.Contains('IMAGE_QUALITY_RESOURCE_BUDGET_PASS')) {
            throw "Resource gate rejected equal limits: $caseDir\console.log"
        }
        Write-Output "RESOURCE_GATE_CASE_PASS name=$($case.Name) reached_bitgen=$([int]$reached)"
    } finally {
        Pop-Location
    }
}
@($driver,$area,$gateArea,$PSCommandPath) | Get-FileHash -Algorithm SHA256 |
    Select-Object Path,Hash | Export-Csv -LiteralPath (Join-Path $work 'source_sha256.csv') -NoTypeInformation
Write-Output 'SLICE_RESOURCE_GATE_REGRESSION_PASS cases=7 actual_driver_tcl=1'
