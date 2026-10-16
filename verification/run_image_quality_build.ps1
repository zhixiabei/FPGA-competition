param([string] $TdBin='D:\TD\bin', [switch] $SkipRoute,
      [switch] $GenerateBit, [string] $OutputDirectory='')
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
if($GenerateBit -and $SkipRoute) {throw 'Bit generation requires final routed timing checks'}
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

$firmwareDirectory=Get-WorkspaceDestination 'firmware'
$reportDirectory=$null
if($GenerateBit) {
    $reportDirectory=Get-WorkspaceDestination $(if($OutputDirectory) {$OutputDirectory} else {'build\release'})
    if($reportDirectory.Equals($firmwareDirectory,[StringComparison]::OrdinalIgnoreCase) -or
        $reportDirectory.StartsWith($firmwareDirectory+[IO.Path]::DirectorySeparatorChar,
            [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Firmware contains only the fixed bitstream and its instructions; choose a separate report directory'
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
$route=''
if(-not $SkipRoute) {
    $route=@'
    load_run_param -run phy_1
    commit_param -step place
    place
    update_timing -mode manhattan
    report_timing_summary -file system_place.timing
    commit_param -step route
    route
    update_timing -mode final
    report_timing_summary -file system_pr.timing
    report_area -io_info -file system_phy.area
    report_timing_status -file system_phy.ts
    check_timing -verbose -file constraint_health.timing
    export_db system_pr.db
    puts "IMAGE_QUALITY_ROUTE_PASS"
'@
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
    bitgen -bit image_quality.bit
    puts "IMAGE_QUALITY_BITGEN_PASS"
'@
}
$script=@'
set root [file dirname [file normalize [info script]]]
cd $root
if {[catch {
    import_device ph1_35p.db -package PH1P35MDG324 -speed 3
    open_project project.al -single_run
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
    puts "IMAGE_QUALITY_SYNTHESIS_PASS"
ROUTE_COMMANDS
BITGEN_COMMANDS
} detail]} {
    puts stderr "IMAGE_QUALITY_BUILD_FAIL: $detail"
    exit 1
}
exit 0
'@
$script=$script.Replace('ROUTE_COMMANDS',$route)
$script=$script.Replace('BITGEN_COMMANDS',$bitgen)
[IO.File]::WriteAllText((Join-Path $work 'build.tcl'),$script,[Text.UTF8Encoding]::new($false))
Write-Output "Build output: $work"
Write-Output "Source version: $version"
Push-Location $work
try {
    & $tdCommand build.tcl *> console.log
    if($LASTEXITCODE -ne 0) {throw "TD build failed: $work\console.log"}
    $text=[IO.File]::ReadAllText((Join-Path $work 'console.log'))
    if($text -notmatch 'IMAGE_QUALITY_SYNTHESIS_PASS' -or
        (-not $SkipRoute -and $text -notmatch 'IMAGE_QUALITY_ROUTE_PASS')) {
        throw "TD build is incomplete: $work\console.log"
    }
    $slacks=@{}
    if(-not $SkipRoute) {
        $timing=[IO.File]::ReadAllText((Join-Path $work 'system_pr.timing'))
        foreach($kind in @('SWNS','HWNS')) {
            $slack=[regex]::Match($timing,$kind + ':\s*(-?\d+(?:\.\d+)?)ns')
            if(-not $slack.Success -or
                [double]::Parse($slack.Groups[1].Value,[Globalization.CultureInfo]::InvariantCulture) -lt 0) {
                throw "Final $kind timing did not pass: $work\system_pr.timing"
            }
            $slacks[$kind]=[double]::Parse($slack.Groups[1].Value,
                [Globalization.CultureInfo]::InvariantCulture)
            Write-Output $slack.Value
        }
    }
    Select-String -LiteralPath console.log -Pattern '^IMAGE_QUALITY_.*PASS' |
        ForEach-Object { $_.Line }
    if($GenerateBit) {
        $generatedBit=Join-Path $work 'image_quality.bit'
        if($text -notmatch 'IMAGE_QUALITY_BITGEN_PASS' -or
           -not (Test-Path -LiteralPath $generatedBit -PathType Leaf) -or
           (Get-Item -LiteralPath $generatedBit).Length -eq 0) {
            throw "Programming file was not generated: $work"
        }
        $reportNames=@('system_rtl.area','system_gate.area','system_gate.timing',
            'system_place.timing','system_pr.timing','system_phy.area','system_phy.ts',
            'constraint_health.timing','source_sha256.csv','console.log','build.tcl')
        foreach($name in $reportNames) {
            if(-not (Test-Path -LiteralPath (Join-Path $work $name) -PathType Leaf)) {
                throw "Release report is missing: $work\$name"
            }
        }
        # Stage and back up every deliverable before replacing the previous release.
        $firmwareDirectory=Get-WorkspaceDestination $firmwareDirectory
        $reportDirectory=Get-WorkspaceDestination $reportDirectory
        New-Item -ItemType Directory -Path $firmwareDirectory -Force | Out-Null
        New-Item -ItemType Directory -Path $reportDirectory -Force | Out-Null
        $fixedBit=Join-Path $firmwareDirectory 'anlogic_edge_osd.bit'
        $stagedBit=Join-Path $firmwareDirectory ('.anlogic_edge_osd.'+$buildId+'.tmp')
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
        $releaseFiles+=[pscustomobject]@{
            SourcePath=$generatedBit
            StagedPath=$stagedBit
            DestinationPath=$fixedBit
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
                path='firmware/anlogic_edge_osd.bit'
                sha256=$bitHash
                bytes=(Get-Item -LiteralPath $generatedBit).Length
            }
            timing=[ordered]@{
                status='passed'
                mode='final_routed'
                setup_slack_ns=$slacks['SWNS']
                hold_slack_ns=$slacks['HWNS']
            }
            build=[ordered]@{
                started_at_utc=$startedAtUtc
                snapshot_directory=$work
                td_bin=[IO.Path]::GetFullPath($TdBin)
                driver='verification/run_image_quality_build.ps1'
                report_directory=$reportDirectory.Substring($root.Length+1).Replace('\','/')
            }
            reports=$reportNames
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
        Write-Output "FIRMWARE_RELEASE_PASS version=$version"
        Write-Output "Programming file (fixed path): $fixedBit"
        Write-Output "Programming file SHA256: $bitHash"
        Write-Output "Release reports: $reportDirectory"
        Write-Output "Release manifest: $(Join-Path $reportDirectory 'release_manifest.json')"
    }
} finally {
    Pop-Location
}
