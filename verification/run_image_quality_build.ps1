param([string] $TdBin='D:\TD\bin', [switch] $SkipRoute,
      [switch] $GenerateBit, [string] $OutputDirectory='',
      [hashtable] $ResourceLimits=@{}, [int] $PlaceSeed=1,
      [ValidateSet('','CongestionHigh','CongestionMedium')]
      [string] $PhysicalStrategy='', [string] $ResumeGateSnapshot='',
      [string] $ResumePlaceSnapshot='', [string] $CoreRtlOverride='')
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
if($GenerateBit -and $SkipRoute) {throw 'Bit generation requires final routed timing checks'}
if($ResourceLimits.Count -and $SkipRoute) {throw 'Resource limits require final routing'}
if($PlaceSeed -lt -1) {throw 'Place seed must be -1 (tool default) or a non-negative integer'}
if($ResumeGateSnapshot -and $ResumePlaceSnapshot) {throw 'Choose one resume stage'}
if($ResumePlaceSnapshot -and $SkipRoute) {throw 'Placed snapshot resume requires routing'}
if($CoreRtlOverride -and $GenerateBit) {throw 'Diagnostic RTL overrides cannot publish a release'}
foreach($resource in @($ResourceLimits.Keys)) {
    $limit=0
    if($resource -notin @('slice','lut6','reg','eram','dsp') -or
       -not [int]::TryParse([string]$ResourceLimits[$resource],[ref]$limit) -or $limit -lt 0) {
        throw "Invalid physical resource limit: $resource"
    }
    $ResourceLimits[$resource]=$limit
}
$root=[IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))

function Get-WorkspaceDestination([string] $Path) {
    $destination=if([IO.Path]::IsPathRooted($Path)) {
        [IO.Path]::GetFullPath($Path)
    } else {
        [IO.Path]::GetFullPath((Join-Path $root $Path))
    }
    if(-not $destination.StartsWith($root+[IO.Path]::DirectorySeparatorChar,
        [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Output directory must be inside the project workspace'
    }
    $probe=$destination
    while(-not $probe.Equals($root,[StringComparison]::OrdinalIgnoreCase)) {
        if(Test-Path -LiteralPath $probe) {
            $item=Get-Item -LiteralPath $probe -Force
            if(($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "Output paths must not traverse directory links: $probe"
            }
        }
        $probe=[IO.Path]::GetDirectoryName($probe)
    }
    return $destination
}

function Publish-StagedFile([string] $StagedPath,[string] $DestinationPath) {
    # Both paths share a directory/volume. Replace leaves the old file intact
    # when publication fails, and never exposes a partially copied bitstream.
    if(Test-Path -LiteralPath $DestinationPath -PathType Leaf) {
        [IO.File]::Replace($StagedPath,$DestinationPath,[NullString]::Value,$true)
    } else {
        [IO.File]::Move($StagedPath,$DestinationPath)
    }
}

function Publish-ReleaseFiles([object[]] $Files,[string] $BackupDirectory) {
    $releaseFiles=@($Files | ForEach-Object {
        [pscustomobject]@{
            SourcePath=$_.SourcePath
            StagedPath=$_.StagedPath
            DestinationPath=$_.DestinationPath
            BackupPath=$null
            Published=$false
        }
    })
    try {
        New-Item -ItemType Directory -Path $BackupDirectory | Out-Null
        for($index=0;$index -lt $releaseFiles.Count;$index++) {
            $file=$releaseFiles[$index]
            Copy-Item -LiteralPath $file.SourcePath -Destination $file.StagedPath
            if((Get-FileHash -LiteralPath $file.SourcePath -Algorithm SHA256).Hash -ne
                (Get-FileHash -LiteralPath $file.StagedPath -Algorithm SHA256).Hash) {
                throw "Staged release file failed SHA256 verification: $($file.StagedPath)"
            }
            if(Test-Path -LiteralPath $file.DestinationPath -PathType Leaf) {
                $file.BackupPath=Join-Path $BackupDirectory ([string] $index)
                Copy-Item -LiteralPath $file.DestinationPath -Destination $file.BackupPath
            } elseif(Test-Path -LiteralPath $file.DestinationPath) {
                throw "Release destination is not a file: $($file.DestinationPath)"
            }
        }
        foreach($file in $releaseFiles) {
            Publish-StagedFile $file.StagedPath $file.DestinationPath
            $file.Published=$true
        }
    } catch {
        $publicationError=$_
        $rollbackErrors=@()
        # Restore in reverse order so the bit and its preceding reports agree again.
        for($index=$releaseFiles.Count-1;$index -ge 0;$index--) {
            $file=$releaseFiles[$index]
            if(-not $file.Published) {continue}
            try {
                if($file.BackupPath) {
                    Copy-Item -LiteralPath $file.BackupPath -Destination $file.StagedPath
                    Publish-StagedFile $file.StagedPath $file.DestinationPath
                } else {
                    Remove-Item -LiteralPath $file.DestinationPath -Force
                }
            } catch {
                $rollbackErrors+="$($file.DestinationPath): $($_.Exception.Message)"
            }
        }
        if($rollbackErrors.Count) {
            throw "Release publication failed: $($publicationError.Exception.Message). Rollback incomplete: $($rollbackErrors -join '; '). Recovery copies: $BackupDirectory"
        }
        throw $publicationError
    } finally {
        foreach($file in $releaseFiles) {
            try {
                if(Test-Path -LiteralPath $file.StagedPath -PathType Leaf) {
                    Remove-Item -LiteralPath $file.StagedPath -Force
                }
            } catch {
                Write-Warning "Could not clean staged release file $($file.StagedPath): $($_.Exception.Message)"
            }
        }
    }
}

function Assert-RouteCompletion([string] $StatusPath,[string] $ConsoleText) {
    $status=[IO.File]::ReadAllText($StatusPath)
    $total=[regex]::Match($status,'(?m)^#Total Routed Net\s+(\d+)\s*$')
    if(-not $total.Success -or [int]$total.Groups[1].Value -le 0) {
        throw "Missing routed-net count: $StatusPath"
    }
    $known=@('Total Routed Net','Gnd Net','Local Net','Net Drivers Same Slice',
             'Net Drivers Same PLB Slice','Other Net')
    foreach($row in [regex]::Matches($status,'(?m)^\s*#(.+?)\s+(\d+)\s*$')) {
        if($row.Groups[1].Value -notin $known) {
            throw "Unrecognized route status; review before release: $($row.Value.Trim())"
        }
    }
    $reportStart=$ConsoleText.LastIndexOf('start command "report_route_status',
        [StringComparison]::Ordinal)
    if($reportStart -lt 0) {throw 'Final route status was not queried'}
    $reportConsole=$ConsoleText.Substring($reportStart)
    $openNets=[regex]::Matches($reportConsole,'eco open net\s*=\s*(\d+)')
    if($openNets.Count -ne 1 -or [int]$openNets[0].Groups[1].Value -ne 0) {
        throw 'Final route database has open nets or missing coverage'
    }
    $drcStart=$ConsoleText.LastIndexOf('Stage 5 | Routing DRC',
        [StringComparison]::Ordinal)
    foreach($required in @('PHY-1003 : Routed, final wirelength =',
                           'End Stage 5 | Routing DRC',
                           'No multi-drive.','No abnormal timing path.')) {
        if(-not $ConsoleText.Contains($required)) {
            throw "Missing completed-route check: $required"
        }
    }
    if($drcStart -gt $reportStart) {throw 'Route status precedes final routing DRC'}
    return [ordered]@{status='passed';routed_nets=[int]$total.Groups[1].Value;open_nets=0}
}

function Assert-FinalTiming([string] $TimingPath,[string] $QorPath) {
    $timing=[IO.File]::ReadAllText($TimingPath)
    if($timing -notmatch '(?m)^Confidence\s*:\s*Routed\s*$' -or
       $timing -notmatch '(?m)^Check Corner\s*:\s*Both \(Slow and Fast\)\s*$') {
        throw "Final timing must use routed delays at both corners: $TimingPath"
    }
    foreach($corner in @('Slow','Fast')) {
        if($timing -notmatch ('(?m)^'+$corner+'\s*\|\s*yes\s+yes\s*$')) {
            throw "Missing setup/hold checks at $corner corner: $TimingPath"
        }
    }
    $values=[ordered]@{}
    foreach($kind in @('SWNS','STNS','HWNS','HTNS','Period Check WNS')) {
        $matches=[regex]::Matches($timing,[regex]::Escape($kind)+':\s*(-?\d+(?:\.\d+)?)ns')
        if($matches.Count -ne 1) {throw "Missing or ambiguous final ${kind}: $TimingPath"}
        $value=[double]::Parse($matches[0].Groups[1].Value,
            [Globalization.CultureInfo]::InvariantCulture)
        if($value -lt 0 -or ($kind -in @('STNS','HTNS') -and $value -ne 0)) {
            throw "Final $kind timing did not pass: $TimingPath"
        }
        $values[$kind]=$value
    }
    # Rounded WNS can hide a tiny violation; check endpoint counts as well.
    foreach($type in @('Max','Min')) {
        $rows=[regex]::Matches($timing,'(?m)^'+$type+'\s*:\s*[^\r\n]*?\b(\d+) Viol Endpoints\b')
        if($rows.Count -eq 0) {throw "Missing $type endpoint statistics: $TimingPath"}
        foreach($row in $rows) {
            if([int]$row.Groups[1].Value -ne 0) {
                throw "Final timing has failing endpoints: $($row.Value)"
            }
        }
    }
    $qor=[IO.File]::ReadAllText($QorPath)
    foreach($kind in @('Setup WNS','Setup TNS','Hold WNS','Hold TNS',
                       'Num of violated S-EP','Num of violated H-EP')) {
        $rows=[regex]::Matches($qor,'(?m)^\|\s*'+[regex]::Escape($kind)+'\s*\|\s*(-?\d+(?:\.\d+)?)\s*\|\s*$')
        if($rows.Count -ne 1) {throw "Missing or ambiguous route QoR ${kind}: $QorPath"}
        $value=[double]::Parse($rows[0].Groups[1].Value,
            [Globalization.CultureInfo]::InvariantCulture)
        if($value -lt 0 -or ($kind -notlike '*WNS' -and $value -ne 0)) {
            throw "Final route QoR $kind did not pass: $QorPath"
        }
    }
    return $values
}

function Assert-DisplayEffectConstraintHealth([string] $Path) {
    $health=[IO.File]::ReadAllText($Path)
    if($health -notmatch 'There are 0 invalid constraints\.' -or
       $health -notmatch 'There are 0 constraints that have no timing paths\.') {
        throw "Invalid or missing-path timing constraints: $Path"
    }
    $rows=@($health -split '\r?\n' | Where-Object {
        $_.Contains('u_display_effect_cdc/payload_hold[*]') -and
        $_.Contains('u_display_effect_cdc/O_dst_data[*]')
    })
    $pattern='^\s*(?<total>\d+)\s+(?<dominated>\d+)\s+(?<shadowed>\d+)\s+(?<ignored>\d+)\s+set_max_delay\s+-datapath_only\b.*\s(?<limit>\d+(?:\.\d+)?)\s*$'
    if($rows.Count -ne 1) {
        throw "Expected one display-effect CDC payload constraint: $Path"
    }
    $row=[regex]::Match($rows[0],$pattern)
    if(-not $row.Success) {
        throw "Unrecognized display-effect CDC constraint health: $Path"
    }
    $total=[int]$row.Groups['total'].Value
    $limit=[double]::Parse($row.Groups['limit'].Value,
        [Globalization.CultureInfo]::InvariantCulture)
    if($total -le 0 -or [int]$row.Groups['dominated'].Value -ne $total -or
       [int]$row.Groups['shadowed'].Value -ne 0 -or
       [int]$row.Groups['ignored'].Value -ne 0 -or $limit -ne 13.0) {
        throw "The 13 ns display-effect CDC bound must cover every payload path: $Path"
    }
    return [pscustomobject]@{payload_paths=$total; max_delay_ns=$limit; status='passed'}
}

function Assert-TargetFrameConstraintHealth([string] $Path) {
    $health=[IO.File]::ReadAllText($Path)
    $rules=@(
        @{Name='frame_context'; From='u_target_frame_bridge/S_start_nonce[*]';
            To='u_target_frame_bridge/S_slot*'; Limit=20.0},
        @{Name='detector_result'; From='u_target_frame_bridge/S_result_payload[*]';
            To='u_target_frame_bridge/S_last_result_payload[*]'; Limit=20.0},
        @{Name='display_snapshot'; From='u_target_frame_bridge/S_read_payload[*]';
            To='u_target_frame_bridge/O_*'; Limit=13.0}
    )
    $pattern='^\s*(?<total>\d+)\s+(?<dominated>\d+)\s+(?<shadowed>\d+)\s+(?<ignored>\d+)\s+set_max_delay\s+-datapath_only\b.*\s(?<limit>\d+(?:\.\d+)?)\s*$'
    $results=[ordered]@{}
    foreach($rule in $rules) {
        $rows=@($health -split '\r?\n' | Where-Object {
            $_.Contains($rule.From) -and $_.Contains($rule.To)
        })
        if($rows.Count -ne 1) {
            throw "Expected one target-frame $($rule.Name) CDC constraint: $Path"
        }
        $row=[regex]::Match($rows[0],$pattern)
        if(-not $row.Success) {
            throw "Unrecognized target-frame $($rule.Name) constraint health: $Path"
        }
        $total=[int]$row.Groups['total'].Value
        $limit=[double]::Parse($row.Groups['limit'].Value,
            [Globalization.CultureInfo]::InvariantCulture)
        if($total -le 0 -or [int]$row.Groups['dominated'].Value -ne $total -or
           [int]$row.Groups['shadowed'].Value -ne 0 -or
           [int]$row.Groups['ignored'].Value -ne 0 -or $limit -ne $rule.Limit) {
            throw "Target-frame $($rule.Name) CDC bound must cover every payload path: $Path"
        }
        $results[$rule.Name]=[pscustomobject]@{
            payload_paths=$total; max_delay_ns=$limit; status='passed'
        }
    }
    return [pscustomobject]$results
}

function Assert-AeConstraintHealth([string] $Path,[string] $SdcPath) {
    $health=[IO.File]::ReadAllText($Path)
    $rows=@($health -split '\r?\n' | Where-Object {
        $_.Contains('u_ae_stats_cdc/payload_hold[*]') -and
        $_.Contains('u_ae_stats_cdc/O_dst_data[*]')
    })
    $pattern='^\s*(?<total>\d+)\s+(?<dominated>\d+)\s+(?<shadowed>\d+)\s+(?<ignored>\d+)\s+set_max_delay\s+-datapath_only\b.*\s(?<limit>\d+(?:\.\d+)?)\s*$'
    if($rows.Count -ne 1) {
        throw "Expected one AE statistics CDC payload constraint: $Path"
    }
    $row=[regex]::Match($rows[0],$pattern)
    if(-not $row.Success) {
        throw "Unrecognized AE statistics CDC constraint health: $Path"
    }
    $total=[int]$row.Groups['total'].Value
    $limit=[double]::Parse($row.Groups['limit'].Value,
        [Globalization.CultureInfo]::InvariantCulture)
    if($total -le 0 -or [int]$row.Groups['dominated'].Value -ne $total -or
       [int]$row.Groups['shadowed'].Value -ne 0 -or
       [int]$row.Groups['ignored'].Value -ne 0 -or $limit -ne 20.0) {
        throw "The 20 ns AE statistics CDC bound must cover every payload path: $Path"
    }
    # Original-compatible AWB does not consume the AE hold level. Requiring a
    # false path here would constrain a non-functional or optimized endpoint.
    $sdc=[IO.File]::ReadAllText($SdcPath)
    $holdRows=@($sdc -split '\r?\n' | Where-Object {
        $_ -match '^\s*set_false_path\b' -and $_.Contains('awb_hold')
    })
    if($holdRows.Count -ne 0 -or
       $health -notmatch 'There are 0 invalid constraints\.' -or
       $health -notmatch 'There are 0 constraints that have no timing paths\.') {
        throw "Original-compatible AWB must not retain an unused AE-hold exception: $Path"
    }
    return [pscustomobject]@{
        payload_paths=$total; max_delay_ns=$limit; status='passed'
        awb_hold_constraint='disabled_with_compatibility_awb'
    }
}

$bestResultDirectory=Get-WorkspaceDestination 'td_project\anlogic_edge_osd_Runs\best_result'
$reportDirectory=$null
if($GenerateBit) {
    $reportDirectory=Get-WorkspaceDestination $(if($OutputDirectory) {$OutputDirectory} else {'build\release'})
    if($reportDirectory.Equals($bestResultDirectory,[StringComparison]::OrdinalIgnoreCase) -or
        $reportDirectory.StartsWith($bestResultDirectory+[IO.Path]::DirectorySeparatorChar,
            [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Release reports must remain outside the best_result programming directory'
    }
}
$tdCommand=Join-Path $TdBin 'td_commands_prompt.exe'
if(-not (Test-Path -LiteralPath $tdCommand -PathType Leaf)) {
    throw "TD command-line tool was not found: $tdCommand"
}
$buildId=[guid]::NewGuid().ToString('N')
$startedAtUtc=[datetime]::UtcNow.ToString('o')
$work=Join-Path $env:TEMP ('anlogic_image_quality_' + $buildId)
New-Item -ItemType Directory -Path $work | Out-Null
Copy-Item -LiteralPath (Join-Path $root 'user_source') -Destination $work -Recurse
if($CoreRtlOverride) {
    Copy-Item -LiteralPath $CoreRtlOverride -Destination (Join-Path $work 'user_source/hdl_source/fruit_merged/fruitcnn128_core.v')
}
New-Item -ItemType Directory -Path (Join-Path $work 'td_project') | Out-Null
Copy-Item -LiteralPath (Join-Path $root 'td_project\anlogic_edge_osd.sdc') -Destination (Join-Path $work 'td_project')
Copy-Item -LiteralPath (Join-Path $root 'td_project\anlogic_edge_osd.al') -Destination (Join-Path $work 'td_project')
Copy-Item -LiteralPath $PSCommandPath -Destination (Join-Path $work 'build_driver.ps1')
$projectText=Get-Content -Raw -LiteralPath (Join-Path $work 'td_project\anlogic_edge_osd.al')
# TD writes a literal ampersand in this attribute; normalize for the XML API.
$normalizedProject=$projectText.Replace('UsedInP&R','UsedInP&amp;R')
[xml] $project=$normalizedProject.Replace('BitgenProperty::GeneralOption','BitgenProperty_GeneralOption')
$project.Project.SetAttribute('Path',$work.Replace('\','/'))
$project.Project.Name='project'
foreach($file in $project.SelectNodes('/Project/Source_Files/*/File')) {
    $relative=$file.GetAttribute('Path')
    $source=[IO.Path]::GetFullPath((Join-Path (Join-Path $root 'td_project') $relative))
    $snapshot=$source.Replace($root,$work).Replace('\','/')
    $file.SetAttribute('Path',$snapshot)
}
$serializedProject=$project.OuterXml.Replace('UsedInP&amp;R','UsedInP&R')
$serializedProject=$serializedProject.Replace('BitgenProperty_GeneralOption','BitgenProperty::GeneralOption')
[IO.File]::WriteAllText((Join-Path $work 'project.al'),$serializedProject,[Text.UTF8Encoding]::new($false))
$sourceHashes=@(
    Get-ChildItem -LiteralPath (Join-Path $work 'user_source') -File -Recurse |
        Get-FileHash -Algorithm SHA256 | ForEach-Object {
            [pscustomobject]@{
                Path=$_.Path.Substring($work.Length+1).Replace('\','/')
                Hash=$_.Hash
            }
        }
    foreach($relative in @('td_project/anlogic_edge_osd.al','td_project/anlogic_edge_osd.sdc')) {
        [pscustomobject]@{
            Path=$relative
            Hash=(Get-FileHash -LiteralPath (Join-Path $work $relative) -Algorithm SHA256).Hash
        }
    }
) | Sort-Object Path
$driverHash=(Get-FileHash -LiteralPath (Join-Path $work 'build_driver.ps1') -Algorithm SHA256).Hash
$sourceHashes | Export-Csv -LiteralPath (Join-Path $work 'source_sha256.csv') -NoTypeInformation -Encoding UTF8
$fingerprintText=($sourceHashes | ForEach-Object {$_.Hash+'  '+$_.Path}) -join "`n"
$fingerprintHasher=[Security.Cryptography.SHA256]::Create()
try {
    $fingerprintBytes=$fingerprintHasher.ComputeHash([Text.Encoding]::UTF8.GetBytes($fingerprintText))
    $sourceFingerprint=([BitConverter]::ToString($fingerprintBytes)).Replace('-','')
} finally {
    $fingerprintHasher.Dispose()
}
$version='src-'+$sourceFingerprint.Substring(0,12).ToLowerInvariant()
$resumeGate=$false
$resumePlace=[bool]$ResumePlaceSnapshot
$resumeSource=if($resumePlace) {$ResumePlaceSnapshot} else {$ResumeGateSnapshot}
if($resumeSource) {
    $resumeRoot=(Resolve-Path -LiteralPath $resumeSource).Path
    $resumeHashes=Import-Csv -LiteralPath (Join-Path $resumeRoot 'source_sha256.csv')
    $resumeFingerprintText=($resumeHashes | Sort-Object Path |
        ForEach-Object {$_.Hash+'  '+$_.Path}) -join "`n"
    if($resumeFingerprintText -cne $fingerprintText) {
        throw 'Cannot resume snapshot: source/project/constraint hashes differ'
    }
    if($resumePlace) {
        foreach($name in @('system_place.db','system_place.area','system_place.timing','place.qor')) {
            Copy-Item -LiteralPath (Join-Path $resumeRoot $name) -Destination (Join-Path $work $name)
        }
    }
    foreach($name in @('system_gate.db','system_gate.v','system_gate.area',
                       'system_gate.timing','system_rtl.area')) {
        Copy-Item -LiteralPath (Join-Path $resumeRoot $name) -Destination (Join-Path $work $name)
    }
    $resumeGate=$true
}
$route=''
if(-not $SkipRoute) {
    $route=@'
    load_run_param -run phy_1
PLACE_SEED_COMMAND
    commit_param -step place
    place
    update_timing -mode manhattan
    report_timing_summary -file system_place.timing
    report_area -file system_place.area
    report_qor -step place -file place.qor
    export_db system_place.db
    commit_param -step route
    route
    update_timing -mode final
    report_timing_summary -file system_pr.timing
    report_qor -step route -file route.qor
    report_area -io_info -file system_phy.area
    report_timing_status -file system_phy.ts
    report_route_status -file system_route.status
    check_timing -verbose -file constraint_health.timing
    verify_fifo_cdc constraint_health.timing
    export_db system_pr.db
    puts "IMAGE_QUALITY_ROUTE_PASS"
'@
    $placeSeedCommand=if($PlaceSeed -ge 0) {
        "    set_param place seed $PlaceSeed"
    } else {
        ''
    }
    $route=$route.Replace('PLACE_SEED_COMMAND',$placeSeedCommand)
    if($resumePlace) {
        $placeStart=$route.IndexOf('    commit_param -step place')
        $routeStart=$route.IndexOf('    commit_param -step route')
        if($placeStart -lt 0 -or $routeStart -le $placeStart) {throw 'Cannot isolate placement resume'}
        $route=$route.Substring(0,$placeStart)+$route.Substring($routeStart)
    }
}
$resourceGate=''
if($ResourceLimits.Count) {
    # Run inside TD before bitgen, so a failed area budget cannot publish a bit.
    $resourceGate=@'
    set resource_file [open system_phy.area r]
    set resource_text [read $resource_file]
    close $resource_file
    foreach {resource limit} {RESOURCE_LIMITS} {
        set resource_pattern [string cat {^#} $resource {[ \t]+([0-9]+)}]
        if {![regexp -line $resource_pattern $resource_text unused used]} {
            error "Missing final physical resource: $resource"
        }
        if {$used > $limit} {
            error "Final resource budget failed: $resource=$used exceeds $limit"
        }
    }
    puts "IMAGE_QUALITY_RESOURCE_BUDGET_PASS"
'@
    $limitPairs=($ResourceLimits.GetEnumerator() | Sort-Object Key |
        ForEach-Object { "$($_.Key) $($_.Value)" }) -join ' '
    $resourceGate=$resourceGate.Replace('RESOURCE_LIMITS',$limitPairs)
}
$bitgen=''
if($GenerateBit) {
    $bitgen=@'
    set timing_file [open system_pr.timing r]
    set timing_text [read $timing_file]
    close $timing_file
    if {![regexp {SWNS: *([-0-9.]+)ns} $timing_text unused setup_slack] || $setup_slack < 0} {
        error "Final setup timing failed"
    }
    if {![regexp {HWNS: *([-0-9.]+)ns} $timing_text unused hold_slack] || $hold_slack < 0} {
        error "Final hold timing failed"
    }
    commit_param -step bitgen
    # Selecting a physical strategy replaces its bitgen property group.
    set_param bitgen compress on
    bitgen -bit image_quality.bit
    puts "IMAGE_QUALITY_BITGEN_PASS"
'@
}
$script=@'
set root [file dirname [file normalize [info script]]]
cd $root
proc verify_fifo_cdc {report {stage final}} {
    set fd [open $report r]
    set health [read $fd]
    close $fd
    if {![string match {*There are 0 invalid constraints.*} $health] ||
        ![string match {*There are 0 constraints that have no timing paths.*} $health]} {
        error "Invalid timing constraint coverage: $report"
    }
    set camera_paths 0
    set display_paths 0
    foreach line [split $health \n] {
        if {![regexp {^\s*([0-9]+)\s+([0-9]+)\s+([0-9]+)\s+([0-9]+)\s+set_max_delay.*primary_addr_gray_reg.*sync_r1.*\s([0-9.]+)\s*$} $line unused total effective shadowed ignored limit]} {continue}
        if {$ignored != 0} {error "FIFO Gray-bus constraint ignored: $line"}
        if {$effective == 0} {continue}
        if {abs($limit-9.360) < 0.0001} {
            incr camera_paths $effective
        } elseif {abs($limit-13.033) < 0.0001} {
            incr display_paths $effective
        } else {error "Unexpected effective FIFO Gray-bus bound: $line"}
    }
    # In-session mapping counts these paths twice; importing the identical
    # gate DB reports them once. Verify actual endpoint coverage independently.
    set sources [llength [get_regs {*/primary_addr_gray_reg[*]}]]
    set destinations [llength [get_regs {*/sync_r1[*]}]]
    if {$sources != 54 || $destinations != 54} {
        error "FIFO Gray endpoint coverage incomplete: sources=$sources destinations=$destinations"
    }
    set factor [expr {$stage eq "gate" && $display_paths == 36 ? 2 : 1}]
    set expected_camera [expr {36*$factor}]
    set expected_display [expr {18*$factor}]
    if {$camera_paths != $expected_camera || $display_paths != $expected_display} {
        error "FIFO CDC coverage incomplete: camera=$camera_paths/$expected_camera display=$display_paths/$expected_display stage=$stage"
    }
    puts "FIFO_CDC_CONSTRAINT_PASS camera_paths=$camera_paths camera_ns=9.360 display_paths=$display_paths display_ns=13.033 stage=$stage report=$report"
}
if {[catch {
    import_device ph1_35p.db -package PH1P35MDG324 -speed 3
    open_project project.al -single_run
PHYSICAL_STRATEGY_COMMAND
    load_run_param -run syn_1
    commit_param -step design
    elaborate -top design_top_wrapper
    read_adc $root/user_source/constraints_source/pin.adc
    read_ip_adc -ip ddr2 -file $root/user_source/hdl_source/ph1p35_ddr/ddr2/src/adc/ddr2.adc
    read_sdc $root/td_project/anlogic_edge_osd.sdc
    read_sdc -ip ddr2 $root/user_source/hdl_source/ph1p35_ddr/ddr2/src/sdc/ddr2.sdc
    read_sdc -ip w128_d512_fifo $root/user_source/ip_source/w128_d512_fifo/w128_d512_fifo.tcl
    commit_param -step rtl
    optimize_rtl
    report_area -file system_rtl.area
    commit_param -step gate
    optimize_gate -packarea system_gate.area
    legalize_phy_inst
    update_timing
    report_timing_summary -file system_gate.timing
    write_verilog system_gate.v
    export_db system_gate.db
    check_timing -verbose -file constraint_health_gate.timing
    verify_fifo_cdc constraint_health_gate.timing gate
    puts "IMAGE_QUALITY_SYNTHESIS_PASS"
ROUTE_COMMANDS
RESOURCE_GATE_COMMANDS
BITGEN_COMMANDS
} detail]} {
    puts stderr "IMAGE_QUALITY_BUILD_FAIL: $detail"
    exit 1
}
exit 0
'@
$script=$script.Replace('ROUTE_COMMANDS',$route)
$strategyCommand=if($PhysicalStrategy) {"    set_strategy -run phy_1 $PhysicalStrategy"} else {''}
$script=$script.Replace('PHYSICAL_STRATEGY_COMMAND',$strategyCommand)
$script=$script.Replace('RESOURCE_GATE_COMMANDS',$resourceGate)
$script=$script.Replace('BITGEN_COMMANDS',$bitgen)
if($resumeGate) {
    $gateStart=$script.IndexOf('    load_run_param -run syn_1')
    $gateEnd=$script.IndexOf('    puts "IMAGE_QUALITY_SYNTHESIS_PASS"',$gateStart)
    if($gateStart -lt 0 -or $gateEnd -le $gateStart) {throw 'Cannot isolate synthesis for gate resume'}
    $resumeCommands=@'
    import_db system_gate.db
    update_timing
    check_timing -verbose -file constraint_health_gate.timing
    verify_fifo_cdc constraint_health_gate.timing gate

'@
    if($resumePlace) {
        $resumeCommands=$resumeCommands.Replace('import_db system_gate.db','import_db system_place.db')
        $resumeCommands=$resumeCommands.Replace('    update_timing','    update_timing -mode manhattan')
    }
    $script=$script.Substring(0,$gateStart)+$resumeCommands+$script.Substring($gateEnd)
}
[IO.File]::WriteAllText((Join-Path $work 'build.tcl'),$script,[Text.UTF8Encoding]::new($false))
Write-Output "Build output: $work"
Write-Output "Source version: $version"
if($PhysicalStrategy) {Write-Output "Physical strategy: $PhysicalStrategy"}
if($resumeGate) {
    $resumeStage=if($resumePlace) {'placed'} else {'gate'}
    Write-Output "Resuming verified source-matched $resumeStage snapshot: $resumeRoot"
}
Push-Location $work
try {
    & $tdCommand build.tcl *> console.log
    if($LASTEXITCODE -ne 0) {throw "TD build failed: $work\console.log"}
    $text=[IO.File]::ReadAllText((Join-Path $work 'console.log'))
    if($text -notmatch 'IMAGE_QUALITY_SYNTHESIS_PASS' -or
        (-not $SkipRoute -and $text -notmatch 'IMAGE_QUALITY_ROUTE_PASS') -or
        ($ResourceLimits.Count -and $text -notmatch 'IMAGE_QUALITY_RESOURCE_BUDGET_PASS')) {
        throw "TD build is incomplete: $work\console.log"
    }
    $slacks=@{}
    $displayEffectConstraint=$null
    $targetFrameConstraint=$null
    $aeConstraint=$null
    $routeCompletion=$null
    if(-not $SkipRoute) {
        $routeCompletion=Assert-RouteCompletion (Join-Path $work 'system_route.status') $text
        Write-Output "FINAL_ROUTE_COMPLETION_PASS routed_nets=$($routeCompletion.routed_nets) open_nets=0"
        $slacks=Assert-FinalTiming (Join-Path $work 'system_pr.timing') (Join-Path $work 'route.qor')
        foreach($kind in @('SWNS','HWNS')) {
            Write-Output "${kind}: $($slacks[$kind])ns"
        }
        Write-Output 'FINAL_TIMING_ENDPOINTS_PASS setup=0 hold=0 corners=slow,fast confidence=routed'
        $displayEffectConstraint=Assert-DisplayEffectConstraintHealth (Join-Path $work 'constraint_health.timing')
        Write-Output "DISPLAY_EFFECT_CDC_CONSTRAINT_PASS paths=$($displayEffectConstraint.payload_paths) max_delay_ns=$($displayEffectConstraint.max_delay_ns)"
        $targetFrameConstraint=Assert-TargetFrameConstraintHealth (Join-Path $work 'constraint_health.timing')
        Write-Output 'TARGET_FRAME_CDC_CONSTRAINT_PASS context=20ns result=20ns display=13ns'
        $aeConstraint=Assert-AeConstraintHealth (Join-Path $work 'constraint_health.timing') (Join-Path $work 'td_project\anlogic_edge_osd.sdc')
        Write-Output "AE_CDC_CONSTRAINT_PASS paths=$($aeConstraint.payload_paths) max_delay_ns=$($aeConstraint.max_delay_ns) awb_hold_constraint=$($aeConstraint.awb_hold_constraint)"
    }
    Select-String -LiteralPath console.log -Pattern '^IMAGE_QUALITY_.*PASS' |
        ForEach-Object { $_.Line }
    if($GenerateBit) {
        $generatedBit=Join-Path $work 'image_quality.bit'
        $generatedCompressedBit=Join-Path $work 'image_quality_compress.bit'
        if($text -notmatch 'IMAGE_QUALITY_BITGEN_PASS' -or
           -not (Test-Path -LiteralPath $generatedBit -PathType Leaf) -or
           (Get-Item -LiteralPath $generatedBit).Length -eq 0) {
            throw "Programming file was not generated: $work"
        }
        if(-not (Test-Path -LiteralPath $generatedCompressedBit -PathType Leaf) -or
           (Get-Item -LiteralPath $generatedCompressedBit).Length -eq 0 -or
           -not (Test-Path -LiteralPath (Join-Path $work 'project_inst.bid') -PathType Leaf)) {
            throw "Compressed bitstream or instance report is missing: $work"
        }
        $reportNames=@('system_rtl.area','system_gate.area','system_gate.timing',
            'system_place.timing','system_pr.timing','route.qor','system_phy.area','system_phy.ts',
            'constraint_health.timing','constraint_health_gate.timing','system_route.status','source_sha256.csv','console.log','build.tcl')
        foreach($name in $reportNames) {
            if(-not (Test-Path -LiteralPath (Join-Path $work $name) -PathType Leaf)) {
                throw "Release report is missing: $work\$name"
            }
        }
        # Stage and back up every deliverable before replacing the previous release.
        $bestResultDirectory=Get-WorkspaceDestination $bestResultDirectory
        $reportDirectory=Get-WorkspaceDestination $reportDirectory
        New-Item -ItemType Directory -Path $bestResultDirectory -Force | Out-Null
        New-Item -ItemType Directory -Path $reportDirectory -Force | Out-Null
        $bitHash=(Get-FileHash -LiteralPath $generatedBit -Algorithm SHA256).Hash
        $releaseFiles=@()
        foreach($name in $reportNames) {
            $stagedReport=Join-Path $reportDirectory ('.'+$name+'.'+$buildId+'.tmp')
            $releaseFiles+=[pscustomobject]@{
                SourcePath=(Join-Path $work $name)
                StagedPath=$stagedReport
                DestinationPath=(Join-Path $reportDirectory $name)
            }
        }
        $bestResultReadme=Join-Path $work 'best_result_readme.txt'
        [IO.File]::WriteAllText($bestResultReadme,
            "Verified build $version. Reports: build/release/release_manifest.json`r`n"+
            "Program anlogic_edge_osd.bit from this directory.`r`n",
            [Text.UTF8Encoding]::new($false))
        foreach($artifact in @(
            @{Source=$generatedBit; Name='anlogic_edge_osd.bit'},
            @{Source=$generatedCompressedBit; Name='anlogic_edge_osd_compress.bit'},
            @{Source=(Join-Path $work 'project_inst.bid'); Name='anlogic_edge_osd_inst.bid'},
            @{Source=(Join-Path $work 'system_phy.ts'); Name='anlogic_edge_osd_phy.ts'},
            @{Source=$bestResultReadme; Name='readMe.txt'}
        )) {
            $releaseFiles+=[pscustomobject]@{
                SourcePath=$artifact.Source
                StagedPath=(Join-Path $bestResultDirectory ('.'+$artifact.Name+'.'+$buildId+'.tmp'))
                DestinationPath=(Join-Path $bestResultDirectory $artifact.Name)
            }
        }
        $manifest=[ordered]@{
            schema_version=1
            project='anlogic_edge_osd'
            version=$version
            built_at_utc=[datetime]::UtcNow.ToString('o')
            build_id=$buildId
            source_fingerprint_sha256=$sourceFingerprint
            toolchain_fingerprint_sha256=$driverHash
            source_manifest='source_sha256.csv'
            bitstream=[ordered]@{
                path='td_project/anlogic_edge_osd_Runs/best_result/anlogic_edge_osd.bit'
                sha256=$bitHash
                bytes=(Get-Item -LiteralPath $generatedBit).Length
            }
            timing=[ordered]@{
                status='passed'
                mode='final_routed'
                setup_slack_ns=$slacks['SWNS']
                hold_slack_ns=$slacks['HWNS']
                setup_tns_ns=$slacks['STNS']
                hold_tns_ns=$slacks['HTNS']
                setup_violated_endpoints=0
                hold_violated_endpoints=0
                period_check_slack_ns=$slacks['Period Check WNS']
                corners=@('slow','fast')
                display_effect_cdc=$displayEffectConstraint
                target_frame_cdc=$targetFrameConstraint
                ae_stats_cdc=$aeConstraint
                fifo_gray_cdc=[ordered]@{
                    status='passed'
                    camera_paths=36
                    camera_max_delay_ns=9.360
                    display_paths=18
                    display_max_delay_ns=13.033
                }
            }
            routing=$routeCompletion
            build=[ordered]@{
                started_at_utc=$startedAtUtc
                snapshot_directory=$work
                td_bin=[IO.Path]::GetFullPath($TdBin)
                driver='verification/run_image_quality_build.ps1'
                physical_strategy=$PhysicalStrategy
                place_seed=$PlaceSeed
                resumed_gate_snapshot=$ResumeGateSnapshot
                resumed_place_snapshot=$ResumePlaceSnapshot
                report_directory=$reportDirectory.Substring($root.Length+1).Replace('\','/')
            }
            reports=$reportNames
        }
        if($ResourceLimits.Count) {
            $manifest['resource_budget']=[ordered]@{
                status='passed'
                report='system_phy.area'
                limits=$ResourceLimits
            }
        }
        $manifestSource=Join-Path $work 'release_manifest.json'
        [IO.File]::WriteAllText($manifestSource,($manifest | ConvertTo-Json -Depth 5),
            [Text.UTF8Encoding]::new($false))
        $releaseFiles+=[pscustomobject]@{
            SourcePath=$manifestSource
            StagedPath=(Join-Path $reportDirectory ('.release_manifest.'+$buildId+'.tmp'))
            DestinationPath=(Join-Path $reportDirectory 'release_manifest.json')
        }
        Publish-ReleaseFiles $releaseFiles (Join-Path $work 'release_backup')
        Write-Output "BEST_RESULT_RELEASE_PASS version=$version"
        Write-Output "Programming file (fixed path): $(Join-Path $bestResultDirectory 'anlogic_edge_osd.bit')"
        Write-Output "Programming file SHA256: $bitHash"
        Write-Output "Release reports: $reportDirectory"
        Write-Output "Release manifest: $(Join-Path $reportDirectory 'release_manifest.json')"
    }
} finally {
    Pop-Location
}
