$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
$work=Join-Path $root 'build\flash_model\sim'
New-Item -ItemType Directory -Force -Path $work | Out-Null
$bin='C:\altera\14.1\modelsim_ase\win32aloem'
Push-Location $work
try {
    & "$bin\vlib.exe" work | Out-Null
    & "$bin\vlog.exe" -sv "$root\user_source\hdl_source\flash\spi_flash_byte.v" "$root\user_source\hdl_source\flash\spi_flash_reader.v" "$root\user_source\hdl_source\flash\fruit_flash_boot.v" "$root\user_source\hdl_source\flash\fruit_flash_programmer.v" "$PSScriptRoot\tb_fruit_flash.sv" *> compile.log
    if($LASTEXITCODE -ne 0){Get-Content compile.log;throw 'Flash simulation compile failed'}
    & "$bin\vsim.exe" -c -onfinish exit work.tb_fruit_flash -do 'run -all; quit -code 0 -force' -l simulation.log *> console.log
    Get-Content simulation.log -Tail 25
    if(-not (Select-String simulation.log -Pattern 'FRUIT_FLASH_TEST_PASS' -Quiet)){throw 'Flash simulation failed'}
} finally {Pop-Location}
