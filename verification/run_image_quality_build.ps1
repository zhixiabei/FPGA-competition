param([string] $TdBin='D:\TD\bin', [switch] $SkipRoute)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$root=Split-Path -Parent $PSScriptRoot
$work=Join-Path $env:TEMP ('anlogic_image_quality_' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $work | Out-Null
Copy-Item -LiteralPath (Join-Path $root 'user_source') -Destination $work -Recurse
New-Item -ItemType Directory -Path (Join-Path $work 'td_project') | Out-Null
Copy-Item -LiteralPath (Join-Path $root 'td_project\anlogic_edge_osd.sdc') -Destination (Join-Path $work 'td_project')
$projectText=Get-Content -Raw -LiteralPath (Join-Path $root 'td_project\anlogic_edge_osd.al')
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
Get-ChildItem -LiteralPath (Join-Path $work 'user_source') -File -Recurse |
    Get-FileHash -Algorithm SHA256 | Select-Object Path,Hash |
    Export-Csv -LiteralPath (Join-Path $work 'source_sha256.csv') -NoTypeInformation
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
} detail]} {
    puts stderr "IMAGE_QUALITY_BUILD_FAIL: $detail"
    exit 1
}
exit 0
'@
$script=$script.Replace('ROUTE_COMMANDS',$route)
[IO.File]::WriteAllText((Join-Path $work 'build.tcl'),$script,[Text.UTF8Encoding]::new($false))
Write-Output "Build output: $work"
Push-Location $work
try {
    & (Join-Path $TdBin 'td_commands_prompt.exe') build.tcl *> console.log
    if($LASTEXITCODE -ne 0) {throw "TD build failed: $work\console.log"}
    $text=[IO.File]::ReadAllText((Join-Path $work 'console.log'))
    if($text -notmatch 'IMAGE_QUALITY_SYNTHESIS_PASS' -or
        (-not $SkipRoute -and $text -notmatch 'IMAGE_QUALITY_ROUTE_PASS')) {
        throw "TD build is incomplete: $work\console.log"
    }
    if(-not $SkipRoute) {
        $timing=[IO.File]::ReadAllText((Join-Path $work 'system_pr.timing'))
        foreach($kind in @('SWNS','HWNS')) {
            $slack=[regex]::Match($timing,$kind + ':\s*(-?\d+(?:\.\d+)?)ns')
            if(-not $slack.Success -or
                [double]::Parse($slack.Groups[1].Value,[Globalization.CultureInfo]::InvariantCulture) -lt 0) {
                throw "Final $kind timing did not pass: $work\system_pr.timing"
            }
            Write-Output $slack.Value
        }
    }
    Select-String -LiteralPath console.log -Pattern '^IMAGE_QUALITY_.*PASS' |
        ForEach-Object { $_.Line }
} finally {
    Pop-Location
}
