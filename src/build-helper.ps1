#Requires -Version 5.1
[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$ZigPath,
      [Parameter(Mandatory=$true)][string]$FirmwareDirectory)
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$env:ZIG_GLOBAL_CACHE_DIR=Join-Path $root '.build-cache'
$argsList=@('cc','-target','arm-linux-gnueabi','-mcpu=cortex_a9','-mfloat-abi=soft',
    '-O2','-g0','-fno-sanitize=all','-fno-unwind-tables','-fno-asynchronous-unwind-tables',
    '-nostdlib','-shared','-fPIC','-fno-stack-protector','-Wl,--hash-style=sysv',
    '-Wl,-soname,libb618repair.so','-Wl,--allow-shlib-undefined','-Wl,-s',
    '-o',(Join-Path $root 'libb618repair.so'),(Join-Path $PSScriptRoot 'keyrepair.c'))
foreach($name in @('libdl.so','libc.so','libsecapi.so')) {
    $path=Join-Path $FirmwareDirectory $name
    if(!(Test-Path -LiteralPath $path)){throw "Missing link reference: $path"}
    $argsList+=$path
}
& $ZigPath @argsList
if($LASTEXITCODE -ne 0){throw 'Compilation failed.'}
Write-Host 'Built libb618repair.so. Update helperSha256 in manifest.json only after reviewing and testing the rebuilt helper.'
Get-FileHash (Join-Path $root 'libb618repair.so') -Algorithm SHA256
