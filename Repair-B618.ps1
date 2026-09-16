#Requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$AdbPath,
    [ValidatePattern('^(?:\d{1,3}\.){3}\d{1,3}:\d{1,5}$')][string]$Device='192.168.8.1:5555',
    [switch]$Repair,
    [switch]$RetireOldestInactiveKey,
    [string]$OutputDirectory=(Join-Path $PSScriptRoot 'runs')
)
$ErrorActionPreference='Stop'
if ($RetireOldestInactiveKey -and !$Repair) { throw '-RetireOldestInactiveKey requires -Repair.' }
$adb=(Resolve-Path -LiteralPath $AdbPath).Path
$manifest=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'manifest.json') -Raw | ConvertFrom-Json
$helper=Join-Path $PSScriptRoot 'libb618repair.so'
if ((Get-FileHash -LiteralPath $helper -Algorithm SHA256).Hash -ne $manifest.helperSha256) { throw 'Helper checksum mismatch. Extract a fresh copy of the toolkit.' }
$run=Join-Path $OutputDirectory ((Get-Date -Format 'yyyyMMdd-HHmmss')+'-'+[guid]::NewGuid().ToString('N').Substring(0,8))
$null=New-Item -ItemType Directory -Path $run -Force
$run=(Resolve-Path -LiteralPath $run).Path
$remote='/tmp/b618repair-'+[guid]::NewGuid().ToString('N')
$locked=$false; $started=$false; $finished=$false

function Quote-Argument([string]$value) {
    # Windows CreateProcess argument quoting; no shell is used on the PC.
    '"'+[regex]::Replace([regex]::Replace($value,'(\\*)"','$1$1\"'),'(\\+)$','$1$1')+'"'
}
function Invoke-Adb([string[]]$Arguments) {
    $psi=New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName=$adb
    $psi.Arguments=($Arguments | ForEach-Object { Quote-Argument $_ }) -join ' '
    $psi.UseShellExecute=$false; $psi.CreateNoWindow=$true
    $psi.RedirectStandardOutput=$true; $psi.RedirectStandardError=$true
    $p=New-Object System.Diagnostics.Process; $p.StartInfo=$psi
    try {
        if(!$p.Start()){throw 'Could not start ADB.'}
        $stdout=$p.StandardOutput.ReadToEndAsync();$stderr=$p.StandardError.ReadToEndAsync()
        if(!$p.WaitForExit(60000)){ $p.Kill();throw 'ADB timed out. The router operation may still be running; inspect the run log before retrying.' }
        $out=$stdout.Result+$stderr.Result
        if($p.ExitCode -ne 0){throw "ADB failed: $out"}
        return $out.Replace("`r",'').Trim()
    } finally { $p.Dispose() }
}
function Shell([string]$Command) { Invoke-Adb -Arguments @('-s',$Device,'shell',$Command) }
function Write-Utf8([string]$Path,[string]$Text) {
    [IO.File]::WriteAllText($Path,$Text.Replace("`r",''),(New-Object Text.UTF8Encoding($false)))
}
function Remote-Md5([string]$Path) {
    $line=Shell "busyboxx md5sum '$Path'"
    if($line -notmatch '^([a-fA-F0-9]{32})\s'){throw "Could not checksum $Path : $line"}
    $Matches[1]
}
function Backup-Files([string]$Stage) {
    $dir=Join-Path $run $Stage;$null=New-Item -ItemType Directory -Path $dir
    foreach($name in @('currentcfg','customizecfg','keystore','keystore_bak','kmccfg','kmccfg_bak')) {
        $path="/data/atp/$name";$before=Remote-Md5 $path;$local=Join-Path $dir $name
        $null=Invoke-Adb -Arguments @('-s',$Device,'pull',$path,$local)
        $after=Remote-Md5 $path;$localHash=(Get-FileHash -LiteralPath $local -Algorithm MD5).Hash
        if($before -ne $after -or $after -ne $localHash){throw "Backup verification failed for $name. Stop changing settings and retry."}
    }
    foreach($name in @('currentcfg','customizecfg','keystore','keystore_bak','kmccfg','kmccfg_bak')) {
        if((Remote-Md5 "/data/atp/$name") -ne (Get-FileHash -LiteralPath (Join-Path $dir $name) -Algorithm MD5).Hash) {
            throw 'The configuration changed during the backup. Stop changing settings and retry.'
        }
    }
    Get-ChildItem -LiteralPath $dir -File | Get-FileHash -Algorithm SHA256 |
        Select-Object Hash,Path | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $dir 'SHA256.json')
}

try {
    Write-Host "Connecting to $Device..."
    $connection=Invoke-Adb -Arguments @('connect',$Device)
    Write-Utf8 (Join-Path $run 'connection.txt') $connection
    if((Shell 'id') -notmatch 'uid=0\(root\)'){throw 'Root ADB access is required. This script does not enable or unlock ADB.'}
    $lockResult=Shell 'mkdir /tmp/b618-repair.lock 2>/dev/null && echo B618_LOCKED'
    if($lockResult -notmatch 'B618_LOCKED'){throw 'Another repair may be running (/tmp/b618-repair.lock exists). Inspect it before retrying; do not remove it while dbd is running.'}
    $locked=$true
    if((Shell 'busyboxx pidof dbd || true') -match '\d'){throw 'A dbd operation is already running. Wait for it to finish.'}
    Write-Host 'Checking exact firmware compatibility...'
    $fw=Join-Path $run 'firmware-check';$null=New-Item -ItemType Directory -Path $fw
    foreach($item in $manifest.firmware) {
        $local=Join-Path $fw ([IO.Path]::GetFileName($item.path))
        $null=Invoke-Adb -Arguments @('-s',$Device,'pull',$item.path,$local)
        if((Get-FileHash -LiteralPath $local -Algorithm SHA256).Hash -ne $item.sha256) {
            throw "Unsupported firmware: $($item.path) differs from the tested build. No keys were changed. Do not bypass this check."
        }
    }
    Write-Host 'Backing up and verifying configuration and key files...'
    Backup-Files 'before'
    $null=Shell "mkdir '$remote'"
    $null=Invoke-Adb -Arguments @('-s',$Device,'push',$helper,"$remote/helper.so")
    if((Remote-Md5 "$remote/helper.so") -ne (Get-FileHash -LiteralPath $helper -Algorithm MD5).Hash){throw 'Uploaded helper checksum mismatch.'}
    $preflight=Shell "busyboxx env LD_PRELOAD=$remote/helper.so /app/bin/dbd"
    Write-Utf8 (Join-Path $run 'helper-preflight.log') $preflight
    if($preflight -notmatch 'B618_HELPER_LOADED v=1' -or $preflight -match 'could not load library') { throw 'The helper failed its no-command load test. No save or repair was launched.' }
    $mode=0;if($Repair){$mode=1};$retire=0;if($RetireOldestInactiveKey){$retire=1}
    $runner=@"
#!/system/bin/sh
sleep 2
export LD_PRELOAD=$remote/helper.so
export B618_REPAIR=$mode
export B618_RETIRE_OLDEST=$retire
export B618_BACKUP_VERIFIED=1
exec /app/bin/dbd save
"@
    $runnerPath=Join-Path $run 'runner.sh';Write-Utf8 $runnerPath ($runner+"`n")
    $null=Invoke-Adb -Arguments @('-s',$Device,'push',$runnerPath,"$remote/runner.sh")
    # nohup prevents the old ADB shell from killing its child on disconnect.
    # After the shell exits, dbd has parent PID 1, which this firmware permits.
    $started=$true
    $null=Shell "busyboxx nohup /system/bin/sh '$remote/runner.sh' > '$remote/result.log' 2>&1 < /dev/null &"
    $log=''
    for($i=0;$i -lt 45;$i++) {
        Start-Sleep -Seconds 1
        $log=Shell "cat '$remote/result.log'"
        Write-Utf8 (Join-Path $run 'result.log') $log
        if($log -match 'B618_DONE status=([^\s]+) rc=([a-fA-F0-9]+)') {
            $status=$Matches[1];$rc=$Matches[2];$finished=$true;break
        }
    }
    Write-Host $log
    if(!$finished){throw "No completion marker. Do not reboot or repeat the repair until the process state is checked. Log: $run\result.log"}
    if($rc -ne '0'){throw "Stopped: $status (code $rc). If a key operation ran, keep the entire before backup; do not restore only one file. See README.md."}
    if($status -eq 'repaired') {
        Backup-Files 'after'
        foreach($name in @('currentcfg','customizecfg')) {
            $bytes=[IO.File]::ReadAllBytes((Join-Path (Join-Path $run 'after') $name))
            if($bytes.Length -lt 12 -or $bytes[0] -ne 0x3e){throw 'Save returned success but the stored header is unexpected. Keep the backups and investigate before rebooting.'}
        }
        Write-Host 'Repair completed and saved-file headers verified. No reboot was performed.'
        Write-Host 'Reboot from the normal web interface when convenient, then verify your SSID and login page.'
    } elseif($status -eq 'already-healthy') {
        Write-Host 'An active configuration key already exists. No key was changed and no save was performed.'
    } else {
        Write-Host 'Diagnosis complete. No key creation/removal or configuration save was requested by the helper.'
        Write-Host 'active_rc=9f110c indicates the missing-active-key failure this toolkit handles.'
    }
} finally {
    # Keep evidence and the lock after an uncertain/incomplete operation.
    if($locked -and (!$started -or $finished)) {
        try {
            Start-Sleep -Seconds 1
            if((Shell 'busyboxx pidof dbd || true') -notmatch '\d') {
                $null=Shell "rm -f '$remote/helper.so' '$remote/runner.sh' '$remote/result.log'; rmdir '$remote' 2>/dev/null; rmdir /tmp/b618-repair.lock"
            } else { Write-Warning 'dbd is still running; temporary files and the lock were retained.' }
        } catch { Write-Warning "Could not clean up temporary files: $_" }
    }
    Write-Host "Private backups and logs: $run"
}
