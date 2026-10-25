param(
    [string]$Conda='E:/anaconda/Scripts/conda.exe',
    [string]$Channel='https://mirrors.tuna.tsinghua.edu.cn/anaconda/pkgs/main/'
)
$ErrorActionPreference='Stop'
$fruitRoot=Split-Path -Parent $PSScriptRoot
$fruitEnvironment=Join-Path $fruitRoot '.conda/fruitcuda'
$fruitPython=Join-Path $fruitEnvironment 'python.exe'
$fruitCache=Join-Path $fruitRoot 'build/fruit/cache'
if(-not (Test-Path -LiteralPath $Conda)) {throw "Conda not found: $Conda"}
New-Item -ItemType Directory -Force -Path $fruitCache | Out-Null
$fruitOldPackages=$env:CONDA_PKGS_DIRS
try {
    $fruitCondaRoot=Split-Path -Parent (Split-Path -Parent $Conda)
    $env:CONDA_PKGS_DIRS=Join-Path $fruitCache 'conda'
    if(-not (Test-Path -LiteralPath $fruitPython)) {
        & $Conda run --no-capture-output --prefix $fruitCondaRoot python -m conda create --yes --prefix $fruitEnvironment --override-channels --channel $Channel python=3.11 pip
        if($LASTEXITCODE -ne 0) {throw 'Failed to create Python 3.11 environment.'}
    }
    & $Conda run --no-capture-output --prefix $fruitEnvironment python -m pip install --disable-pip-version-check --cache-dir (Join-Path $fruitCache 'pip') --requirement (Join-Path $PSScriptRoot 'requirements_fruitcuda.txt')
    if($LASTEXITCODE -ne 0) {throw 'CUDA training dependency installation failed.'}
    & $Conda run --no-capture-output --prefix $fruitEnvironment python -m pip check
    if($LASTEXITCODE -ne 0) {throw 'Dependency compatibility check failed.'}
    Write-Output "FRUITCUDA_ENVIRONMENT_READY $fruitPython"
} finally {
    $env:CONDA_PKGS_DIRS=$fruitOldPackages
}
