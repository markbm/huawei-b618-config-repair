# Huawei B618 configuration-save repair

A Windows PowerShell toolkit for **one verified failure** on a custom-firmware HUAWEI B618s-22d: configuration saves fail with `dbd_save error[9f110c]` because encryption domain `0x41` has no active type-3 master key. A full, 128-entry key store can also prevent replacement-key creation (`9f110b`).

This is **not a universal factory-reset fix**. It does not repair failing NAND, arbitrary configuration corruption, or other firmware variants. The original reason automatic key maintenance stopped is still unknown.

## Tested device and requirements

- HUAWEI B618s-22d, reporting software `81.198.11.00.00` and WebUI `81.100.31.01.91`, with custom firmware.
- Root ADB already enabled; tested with ADB 1.0.26 at `192.168.8.1:5555`.
- Windows and PowerShell 5.1 or newer. Live testing used PowerShell 7; 5.1 syntax is supported but has not been live-tested.
- `busyboxx` and the exact firmware libraries/executable listed in `manifest.json`.

The script pulls five binaries and checks their SHA-256 fingerprints **before loading its helper**. The displayed firmware version alone is insufficient. A mismatch stops the script: do not remove the compatibility checks to force it onto another build.

ADB and Huawei firmware binaries are **not included**. Use your existing ADB executable. Nothing in this package enables ADB, unlocks a modem, or flashes firmware.

## Run diagnosis first

Extract the ZIP. Open PowerShell in the extracted folder:

```powershell
.\Repair-B618.ps1 -AdbPath 'C:\Tools\adb.exe'
```

For another address:

```powershell
.\Repair-B618.ps1 -AdbPath 'C:\Tools\adb.exe' -Device '192.168.8.1:5555'
```

If Windows blocks this downloaded script, review its source and unblock the extracted script with `Unblock-File .\Repair-B618.ps1`. Organization policy can still prevent execution.

Diagnosis backs up the files, initializes Huawei's key manager in a temporary `dbd` process, and queries the active key. The helper does **not** call key creation, key removal, or configuration saving in this mode. Firmware initialization may perform its own housekeeping; this is not a raw read-only flash dump.

Example of the specific failure:

```text
B618_DIAG domain=41 key_count=128 active_rc=9f110c active_id=0
B618_DONE status=diagnosed rc=0
```

`active_rc=0` means the required active key already exists. This toolkit should not be used to repair a different failure merely because the modem resets.

## Repair

Leave the modem powered, and finish choosing the settings you want to keep in the web interface. Stop making settings changes while the script runs.

If the key store has fewer than 128 entries:

```powershell
.\Repair-B618.ps1 -AdbPath 'C:\Tools\adb.exe' -Repair
```

If it is full, explicitly allow retiring **one oldest inactive key from configuration domain `0x41`**:

```powershell
.\Repair-B618.ps1 -AdbPath 'C:\Tools\adb.exe' -Repair -RetireOldestInactiveKey
```

That last option matters: inactive keys can still decrypt older saved data. Their contents are retained in the verified local backup, but retiring a key can affect older encrypted configurations if restored without the matching key files. Do not share the private backup folder.

The repair:

1. Verifies firmware compatibility and checks that another `dbd` operation is not running.
2. Downloads and verifies `currentcfg`, `customizecfg`, `keystore`, `keystore_bak`, `kmccfg`, and `kmccfg_bak`.
3. Confirms the specific missing-active-key error. An already-active key produces `already-healthy` without changes.
4. If necessary and explicitly allowed, retires one inactive type-3 key in domain `0x41`. It never selects an active key or another domain.
5. Calls Huawei's `KMC_CreateMk`, verifies the new active key, and invokes the original configuration-save routine.
6. Backs up the resulting files and checks both configuration-file headers.

Success ends with `B618_DONE status=repaired rc=0` and the PowerShell message confirming saved-file headers. If there is an error, **do not treat a new key alone as a successful repair**.

No firmware partitions or startup scripts are changed. The helper runs from `/tmp` in a single save process. The script does not reboot automatically.

## Verify after repair

Reboot from the modem's normal web interface when a short connection interruption is acceptable. Confirm that your SSID/settings survived and the normal login/settings page appears. You can then run diagnosis again; expect `active_rc=0`.

The original modem passed an actual reboot test and an ordinary save after reboot, without the helper. The reusable package has been live-tested in diagnosis mode and its already-healthy repair path; destructive/full-store cases were tested offline against mocked firmware APIs rather than recreated on the repaired modem.

## Backups, failures, and limits

- Each run gets its own folder under `runs\`. Use `-OutputDirectory 'D:\Private\B618-runs'` to choose another location.
- **Share the original ZIP, not your `runs` folder.** Runs contain device-specific key material, configuration, and pulled firmware binaries. This distributable contains none of the original modem's secrets or backups.
- If creation or saving fails after a key was retired, keep the entire `before` directory and `result.log`. Do not restore only one key/configuration file or blindly reset the modem. Recovery must account for the complete matching file set and the key manager's in-memory state.
- An interrupted/uncertain run leaves `/tmp/b618-repair.lock` and its temporary directory for inspection. Do not delete the lock while `dbd` is running or automatically launch another repair.
- Retiring one key and creating one replacement leaves a full store at 128 entries. This is a targeted recovery, **not permanent key-store housekeeping**. Future key renewal can require further investigation or another targeted recovery.
- The firmware mismatch guard is intentional. Support for other builds needs separate examination of their API, layout, and error handling.

## Source and tests

- `src/keyrepair.c`: small dynamic interposer; does not log key contents.
- `src/build-helper.ps1`: build using Zig (tested with 0.16.0) and link references pulled from your own compatible firmware: `libdl.so`, `libc.so`, and `libsecapi.so`. Those binaries are not copied into the resulting shared library.
- `tests/run-tests.ps1`: 15 mocked offline scenarios covering normal diagnosis, healthy no-op, successful repairs, candidate selection, missing backup/retirement flags, and failures. It never contacts a modem.

```powershell
.\tests\run-tests.ps1 -ZigPath 'C:\Tools\zig\zig.exe'
.\src\build-helper.ps1 -ZigPath 'C:\Tools\zig\zig.exe' -FirmwareDirectory 'C:\Private\B618-firmware'
```

After a reviewed rebuild, update `helperSha256` in `manifest.json` using the printed hash. Do not alter the firmware fingerprints to bypass compatibility.

## Disclaimer
This toolkit is provided “as is,” without warranty of any kind. Use it entirely at your own risk. It modifies modem configuration and key storage. Using it may cause loss of settings, loss of connectivity, or permanently render your modem unusable (“brick” it).
The authors and contributors accept no responsibility or liability for damage, data loss, service interruptions, or other consequences arising from its use, to the fullest extent permitted by applicable law.
Compatibility is limited to the firmware versions explicitly supported by this toolkit. Back up your configuration and keys, read the instructions, and verify compatibility before proceeding.

MIT license applies to this toolkit's original code. No affiliation with or endorsement by Huawei is implied.
