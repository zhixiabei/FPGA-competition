$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$bitWorkspace = Split-Path -Parent $PSScriptRoot
$bitRun = Join-Path $PSScriptRoot 'anlogic_edge_osd_Runs\phy_1'
$bitDestination = Join-Path $PSScriptRoot 'anlogic_edge_osd_Runs\best_result'
$bitDatabase = Join-Path $bitRun 'anlogic_edge_osd_pr.db'
$bitBuildId = Get-Date -Format 'yyyyMMdd_HHmmss_fff'
$bitBackup = Join-Path $bitDestination ('backup_before_' + $bitBuildId)
$bitDriver = Join-Path $bitWorkspace 'verification\run_image_quality_build.ps1'
$bitTokens = $null
$bitParseErrors = $null
$bitAst = [Management.Automation.Language.Parser]::ParseFile(
    $bitDriver, [ref]$bitTokens, [ref]$bitParseErrors)
if ($bitParseErrors.Count) { throw 'Cannot parse existing release checks' }
foreach ($functionName in @('Assert-RouteCompletion', 'Assert-FinalTiming',
        'Assert-DisplayEffectConstraintHealth', 'Assert-TargetFrameConstraintHealth',
        'Assert-AeConstraintHealth', 'Publish-StagedFile', 'Publish-ReleaseFiles')) {
    $definition = $bitAst.Find({ param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -eq $functionName
    }, $true)
    if ($null -eq $definition) { throw "Missing release helper: $functionName" }
    . ([scriptblock]::Create($definition.Extent.Text))
}

$routeConsole = [IO.File]::ReadAllText((Join-Path $bitRun 'run.log'))
$routeResult = Assert-RouteCompletion (Join-Path $bitRun 'anlogic_edge_osd_route.status') $routeConsole
$null = Assert-FinalTiming (Join-Path $bitRun 'anlogic_edge_osd_pr.timing') (Join-Path $bitRun 'route.qor')
$health = Join-Path $bitRun 'constraint_health.timing'
$null = Assert-DisplayEffectConstraintHealth $health
$null = Assert-TargetFrameConstraintHealth $health
$null = Assert-AeConstraintHealth $health (Join-Path $PSScriptRoot 'anlogic_edge_osd.sdc')
$databaseHash = (Get-FileHash -LiteralPath $bitDatabase -Algorithm SHA256).Hash

# Keep named copies of earlier deliverables before generating or publishing.
$artifactNames = @('anlogic_edge_osd.bit', 'anlogic_edge_osd_compress.bit',
    'anlogic_edge_osd_inst.bid', 'anlogic_edge_osd_phy.ts', 'readMe.txt', 'bitgen_manifest.json')
New-Item -ItemType Directory -Path $bitBackup | Out-Null
foreach ($name in $artifactNames) {
    $oldArtifact = Join-Path $bitDestination $name
    if (Test-Path -LiteralPath $oldArtifact -PathType Leaf) {
        Copy-Item -LiteralPath $oldArtifact -Destination (Join-Path $bitBackup $name)
    }
}
Set-Location -LiteralPath $bitRun
foreach ($name in @('anlogic_edge_osd.bit', 'anlogic_edge_osd_compress.bit',
        'anlogic_edge_osd_inst.bid', 'project_inst.bid', 'bitgen.log')) {
    if (Test-Path -LiteralPath $name -PathType Leaf) {
        Copy-Item -LiteralPath $name -Destination ($name + '.before_' + $bitBuildId)
    }
}
$bitStartedAt = [datetime]::UtcNow
$bitScript = (Join-Path $PSScriptRoot 'generate_routed_bit.tcl').Replace('\', '/')
Write-Output "ROUTED_BITGEN_STARTED database_sha256=$databaseHash backup=$bitBackup"
& 'D:\TD\bin\td_commands_prompt.exe' $bitScript *> bitgen.log
if ($LASTEXITCODE -ne 0) { throw "TD bitgen failed: see $bitRun\bitgen.log" }
$bitConsole = [IO.File]::ReadAllText((Join-Path $bitRun 'bitgen.log'))
if ($bitConsole -notmatch 'ROUTED_BITGEN_COMPLETE') { throw 'Missing bitgen completion marker' }
if ((Get-FileHash -LiteralPath $bitDatabase -Algorithm SHA256).Hash -ne $databaseHash) {
    throw 'Routed database changed during bitgen'
}
$timing = Assert-FinalTiming (Join-Path $bitRun 'bitgen_final.timing') (Join-Path $bitRun 'bitgen.qor')
$null = Assert-RouteCompletion (Join-Path $bitRun 'bitgen_route.status') ($routeConsole + "`n" + $bitConsole)
$instanceReport = @('anlogic_edge_osd_inst.bid', 'project_inst.bid') | Where-Object {
    (Test-Path -LiteralPath $_ -PathType Leaf) -and
    (Get-Item -LiteralPath $_).LastWriteTimeUtc -ge $bitStartedAt
} | Select-Object -First 1
if (-not $instanceReport) { throw 'Missing new bitstream instance report' }
$artifacts = @(
    @{Source='anlogic_edge_osd.bit'; Name='anlogic_edge_osd.bit'},
    @{Source='anlogic_edge_osd_compress.bit'; Name='anlogic_edge_osd_compress.bit'},
    @{Source=$instanceReport; Name='anlogic_edge_osd_inst.bid'},
    @{Source='bitgen_final.ts'; Name='anlogic_edge_osd_phy.ts'}
)
$artifactInfo = foreach ($artifact in $artifacts) {
    $item = Get-Item -LiteralPath $artifact.Source
    if ($item.Length -le 0 -or $item.LastWriteTimeUtc -lt $bitStartedAt) {
        throw "Missing, empty or stale bitgen artifact: $($artifact.Source)"
    }
    [ordered]@{name=$artifact.Name; bytes=$item.Length;
        sha256=(Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash}
}
$manifest = [ordered]@{
    generated_at_utc=[datetime]::UtcNow.ToString('o')
    source_routed_database=$bitDatabase
    source_routed_database_sha256=$databaseHash
    physical_strategy='CongestionHigh'; route_effort='normal'; place_seed=1
    timing=$timing; routing=$routeResult; artifacts=@($artifactInfo)
    reports_directory=$bitRun; previous_files_backup=$bitBackup
    limitations='Existing clock/IO constraint warnings remain. Board operation is not verified.'
}
$manifest | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath bitgen_manifest.json -Encoding UTF8
@("Generated from the accepted routed database on $((Get-Date).ToString('yyyy-MM-dd HH:mm:ss')).",
    'Program anlogic_edge_osd.bit from this directory.',
    'Current provenance: bitgen_manifest.json.',
    "Reports: $bitRun. Prior files: $bitBackup.",
    'Existing clock/IO constraint warnings remain; board operation is not verified.') |
    Set-Content -LiteralPath bitgen_readme.txt -Encoding UTF8
$artifacts += @{Source='bitgen_manifest.json'; Name='bitgen_manifest.json'}
$artifacts += @{Source='bitgen_readme.txt'; Name='readMe.txt'}
$releaseFiles = foreach ($artifact in $artifacts) {
    [pscustomobject]@{
        SourcePath=(Join-Path $bitRun $artifact.Source)
        StagedPath=(Join-Path $bitDestination ('.' + $artifact.Name + '.' + $bitBuildId + '.tmp'))
        DestinationPath=(Join-Path $bitDestination $artifact.Name)
    }
}
Publish-ReleaseFiles @($releaseFiles) (Join-Path $bitBackup 'publication_rollback')
Write-Output "ROUTED_BITGEN_ACCEPTED setup=$($timing.SWNS)ns hold=$($timing.HWNS)ns open_nets=0"
Write-Output "Programming file: $bitDestination\anlogic_edge_osd.bit"
Write-Output "Backup: $bitBackup"
