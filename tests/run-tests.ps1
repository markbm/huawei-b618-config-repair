param([Parameter(Mandatory=$true)][string]$ZigPath)
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$env:ZIG_GLOBAL_CACHE_DIR=Join-Path $root '.build-cache'
$exe=Join-Path $PSScriptRoot 'mock-keymanager.exe'
& $ZigPath cc -O2 -DB618_TEST -Dgetenv=b618_test_getenv (Join-Path $root 'src/keyrepair.c') (Join-Path $PSScriptRoot 'mock-keymanager.c') -o $exe
if($LASTEXITCODE -ne 0){throw 'Test compilation failed.'}
& $exe
if($LASTEXITCODE -ne 0){throw 'Offline tests failed.'}
