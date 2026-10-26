param(
    [string] $ReferenceRtl = '',
    [string] $RtlSource = '',
    [string] $ModelSimBin = 'C:\altera\14.1\modelsim_ase\win32aloem',
    [int] $TimeoutSeconds = 300
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$projectRoot = Split-Path -Parent $PSScriptRoot
if (-not $ReferenceRtl) {
    $ReferenceRtl = Join-Path $projectRoot 'build\slice_compression\baseline_project\user_source\hdl_source\hdmi_mixer.v'
}
$simulationDir = Join-Path $env:TEMP ('anlogic_label_equivalence_' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $simulationDir | Out-Null
$sources = @('hdmi_mixer.v','display_effects_rgb888.v','gamma_lut_rgb888.v',
    'anlogic_logo_rom.v','osd_char_lib.v','video_latency_osd.v')
foreach ($source in $sources) {
    $selectedSource = if ($source -eq 'hdmi_mixer.v' -and $RtlSource) {
        (Resolve-Path -LiteralPath $RtlSource).Path
    } else { Join-Path $projectRoot ('user_source\hdl_source\' + $source) }
    Copy-Item -LiteralPath $selectedSource -Destination (Join-Path $simulationDir $source)
}
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'tb_hdmi_label_equivalence.sv') `
    -Destination $simulationDir
$referenceText = [IO.File]::ReadAllText((Resolve-Path -LiteralPath $ReferenceRtl))
$referenceText = [regex]::Replace($referenceText,'\bhdmi_mixer\b','hdmi_mixer_reference')
[IO.File]::WriteAllText((Join-Path $simulationDir 'hdmi_mixer_reference.v'),
    $referenceText,[Text.UTF8Encoding]::new($false))
$sourceFiles = @(Get-ChildItem -LiteralPath $simulationDir -File)
$sourceFiles |
    Get-FileHash -Algorithm SHA256 |
    Export-Csv -LiteralPath (Join-Path $simulationDir 'source_sha256.csv') -NoTypeInformation
$compile = @($sources + 'hdmi_mixer_reference.v' + 'tb_hdmi_label_equivalence.sv') -join ' '
$runScript = @"
onerror {quit -code 1 -force}
onbreak {quit -code 1 -force}
vlib work
vlog -sv $compile
vsim -t ps work.tb_hdmi_label_equivalence
run -all
quit -code 0 -force
"@
[IO.File]::WriteAllText((Join-Path $simulationDir 'run.do'),$runScript,[Text.UTF8Encoding]::new($false))
Write-Output "Simulation output: $simulationDir"
$consolePath = Join-Path $simulationDir 'console.log'
$process = Start-Process -FilePath (Join-Path $ModelSimBin 'vsim.exe') `
    -ArgumentList @('-c','-do','run.do','-l','transcript.log') `
    -WorkingDirectory $simulationDir -WindowStyle Hidden -PassThru `
    -RedirectStandardOutput $consolePath `
    -RedirectStandardError (Join-Path $simulationDir 'stderr.log')
if (-not $process.WaitForExit($TimeoutSeconds*1000)) {
    Stop-Process -Id $process.Id -Force
    throw "Label equivalence timeout: $consolePath"
}
$process.WaitForExit()
$console = [IO.File]::ReadAllText($consolePath)
if ($process.ExitCode -ne 0 -or
    $console -match '(?im)^\s*(?:#\s*)?\*\*\s+(?:Fatal|Error)\b' -or
    $console -notmatch 'HDMI_LABEL_EQUIVALENCE_PASS cases=3') {
    throw "Label equivalence failed: $consolePath"
}
[regex]::Matches($console,'(?m)^\s*(?:#\s*)?HDMI_LABEL_EQUIVALENCE(?:_CASE)?_PASS.*$') |
    ForEach-Object { $_.Value.Trim() -replace '^#\s*','' }
