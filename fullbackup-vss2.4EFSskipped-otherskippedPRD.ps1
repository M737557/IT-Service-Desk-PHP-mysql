#Requires -RunAsAdministrator
<#
 fullbackup-vss2.ps1
 Copies source folders from a VSS snapshot (so open/locked files copy consistently).

 Modes:
   Full         Mirror snapshot to F:\Full\<drive>\<path>.
   Incremental  Copy only new/changed files (compared with Full).
   Archive      Complete dated copy of the snapshot.

 Usage:  .\fullbackup-vss2.ps1 -Mode Full

 v2.8 changelog:
   - All skipped files/paths are now logged to a single CSV per run
     (Skipped_<stamp>.csv) with columns Time, Reason, Path, plus a grouped
     summary warning in the transcript. Reasons include EFS, ExcludedDir,
     ReparsePoint, MissingSource, FailedSource, VanishedBeforeCopy,
     CopyFailed, RoboError.
   - Copy-Item failures in Incremental mode no longer abort the whole
     source; they are recorded and processing continues.
   - Invoke-Robo now tees robocopy output to a per-call log and greps for
     ERROR / "Access is denied" / "The process cannot access" lines, so
     file-level robocopy failures are visible despite /NP.

 v2.7 changelog:
   - EFS-encrypted files skipped by Get-TreeDiff are now collected and written
     to a per-run log (EFS_skipped_<stamp>.log) under F:\Logs, plus a summary
     warning. Previously they were skipped silently and invisible because
     robocopy is invoked with /NP (no per-file progress).
   - Redundant per-file EFS check in Incremental mode removed; Get-TreeDiff
     already filters encrypted files out of $changed.
#>
param(
    [ValidateSet('Full','Incremental','Archive')]
    [string]$Mode = 'Incremental'
)

$ErrorActionPreference = 'Stop'

# ----------------------------- CONFIG ---------------------------------------
$SourceDirs = @(
    "C:\xampp3\htdocs"
    "C:\Users\maev\Desktop"
    "C:\Users\maev\Downloads"
    "C:\scripts"
    # FIX v2.6: if Mijnbestanden is a junction to another volume, this entry
    # cannot be backed up through a snapshot of C:. Run:
    #   Get-Item 'C:\windows10\pri\Mijnbestanden' -Force | fl LinkType,Target,Attributes
    # If LinkType=Junction/SymbolicLink and Target points to another drive, replace
    # this entry with the TARGET path (e.g. "D:\Mijnbestanden") and re-run. The
    # script will automatically snapshot the target drive too.
    "C:\windows10\pri\Mijnbestanden"
)

$DestinationDrive = "F"
$DestinationBase  = "${DestinationDrive}:\"

$FullRoot   = Join-Path $DestinationBase 'Full'
$IncRoot    = Join-Path $DestinationBase 'Incremental'
$ArchRoot   = Join-Path $DestinationBase 'Archive'
$SuperRoot  = Join-Path $DestinationBase 'Superseded'
$LogRoot    = Join-Path $DestinationBase 'Logs'

$VssLinkRoot = 'C:\vsslinks'
$VssLinkFmt  = Join-Path $VssLinkRoot 'vss_link_{0}'

$ExcludeDirs = @(
    "C:\users\maev\appdata"
)

$EncryptedFiles = 'Skip'

# FIX v2.6: mtime tolerance matching robocopy /FFT (FAT + VSS DST drift).
$DiffTolerance = [TimeSpan]::FromSeconds(2)

# FIX v2.6: when a source is a reparse point (junction/symlink/mount point),
# skip it with a clear message rather than silently following it into a volume
# that isn't in the snapshot set. Set to $false ONLY if you have added the
# target volume to $SourceDirs and know what you're doing.
$SkipReparsePoints = $true
# ----------------------------------------------------------------------------

$Stamp = Get-Date -Format 'yyyy-MM-dd_HHmmss'

if (-not (Test-Path $DestinationBase)) { throw "Destination drive $DestinationBase not found." }
foreach ($d in $FullRoot,$IncRoot,$ArchRoot,$SuperRoot,$LogRoot) {
    New-Item -ItemType Directory -Path $d -Force | Out-Null
}
New-Item -ItemType Directory -Path $VssLinkRoot -Force | Out-Null

Start-Transcript -Path (Join-Path $LogRoot "$Mode`_$Stamp.log") | Out-Null

# FIX v2.7: collect EFS-skipped files across all sources for a per-run log.
$script:EfsSkipped = [System.Collections.Generic.List[string]]::new()

# FIX v2.8: collect every skipped file/path with a reason, not just EFS.
$script:Skipped = [System.Collections.Generic.List[object]]::new()
function Add-Skip([string]$Path, [string]$Reason) {
    $script:Skipped.Add([pscustomobject]@{
        Time   = (Get-Date).ToString('s')
        Reason = $Reason
        Path   = $Path
    }) | Out-Null
}

$EncArgs = switch ($EncryptedFiles) {
    'Raw'   { @('/EFSRAW') }
    default { @('/XA:E') }
}

# ---------- helpers ----------
function New-Snapshot([string]$Drive) {
    $res = Invoke-CimMethod -ClassName Win32_ShadowCopy -MethodName Create `
           -Arguments @{ Volume = "${Drive}:\"; Context = 'ClientAccessible' }
    if ($res.ReturnValue -ne 0) { throw "VSS create failed for ${Drive}: (code $($res.ReturnValue))" }
    $sc   = Get-CimInstance Win32_ShadowCopy -Filter "ID='$($res.ShadowID)'"
    $link = $VssLinkFmt -f $Drive
    if (Test-Path $link) { cmd /c rmdir "`"$link`"" | Out-Null }
    cmd /c mklink /d "`"$link`"" "`"$($sc.DeviceObject)\`"" | Out-Null
    if (-not (Test-Path $link)) { throw "Could not link snapshot for ${Drive}:" }
    $link = (Get-Item -LiteralPath $link).FullName
    [pscustomobject]@{ Drive = $Drive; Shadow = $sc; Link = $link }
}

function Remove-Snapshot($snap) {
    try { cmd /c rmdir "`"$($snap.Link)`"" | Out-Null } catch {}
    try { $snap.Shadow | Remove-CimInstance } catch { Write-Warning "Could not delete shadow copy: $_" }
}

function Get-SnapExcludes([string]$Drive, [string]$Link) {
    $ExcludeDirs | Where-Object { $_ -like "${Drive}:\*" } |
        ForEach-Object { Join-Path $Link $_.Substring(3) }
}

function Invoke-Robo([string[]]$RoboArgs) {
    # FIX v2.8: tee robocopy output to a per-call log and surface per-file
    # errors, since /NP suppresses them on the console.
    $log = Join-Path $LogRoot ("robo_" + [guid]::NewGuid().ToString('N') + ".log")
    $argsWithLog = @($RoboArgs) + @("/LOG+:$log")
    & robocopy @argsWithLog
    $code = $LASTEXITCODE
    if (Test-Path -LiteralPath $log) {
        Select-String -LiteralPath $log -Pattern 'ERROR|Access is denied|The process cannot access' |
            ForEach-Object { Add-Skip $_.Line 'RoboError' }
    }
    if ($code -ge 8) { throw "robocopy failed (exit $code)" }
}

# Native PowerShell tree comparison (from v2.5). No robocopy, no log file,
# no encoding round-trip. Emits Class + Rel objects.
function Get-TreeDiff([string]$Src, [string]$Dst, [string[]]$Xd) {
    $Src = (Get-Item -LiteralPath $Src -Force).FullName
    $DstExists = Test-Path -LiteralPath $Dst
    if ($DstExists) { $Dst = (Get-Item -LiteralPath $Dst -Force).FullName }
    else            { $Dst = $Dst.TrimEnd('\') }

    $xdAbs = @($Xd | Where-Object { $_ } | ForEach-Object { $_.TrimEnd('\') })

    function Test-Excluded([string]$FullPath) {
        foreach ($x in $xdAbs) {
            if ($FullPath.Equals($x, 'OrdinalIgnoreCase'))           { return $true }
            if ($FullPath.StartsWith($x + '\', 'OrdinalIgnoreCase')) { return $true }
        }
        return $false
    }

    $srcFiles = @{}
    Get-ChildItem -LiteralPath $Src -Recurse -File -Force -ErrorAction SilentlyContinue |
        ForEach-Object {
            if (Test-Excluded $_.FullName) {
                # FIX v2.8: log excluded files.
                Add-Skip $_.FullName 'ExcludedDir'
                return
            }
            if ($EncryptedFiles -eq 'Skip' -and
                ($_.Attributes -band [IO.FileAttributes]::Encrypted)) {
                # FIX v2.7: record EFS-skipped files instead of silently dropping them.
                $script:EfsSkipped.Add($_.FullName) | Out-Null
                # FIX v2.8: also add to unified skip log.
                Add-Skip $_.FullName 'EFS'
                return
            }
            $rel = $_.FullName.Substring($Src.Length).TrimStart('\')
            if ($rel) { $srcFiles[$rel] = $_ }
        }

    $dstFiles = @{}
    if ($DstExists) {
        Get-ChildItem -LiteralPath $Dst -Recurse -File -Force -ErrorAction SilentlyContinue |
            ForEach-Object {
                $rel = $_.FullName.Substring($Dst.Length).TrimStart('\')
                if ($rel) { $dstFiles[$rel] = $_ }
            }
    }

    foreach ($rel in $srcFiles.Keys) {
        $s = $srcFiles[$rel]
        if (-not $dstFiles.ContainsKey($rel)) {
            [pscustomobject]@{ Class = 'New File'; Rel = $rel }
            continue
        }
        $d     = $dstFiles[$rel]
        $delta = $s.LastWriteTimeUtc - $d.LastWriteTimeUtc
        if     ($delta -gt  $DiffTolerance) { [pscustomobject]@{ Class = 'Newer';   Rel = $rel } }
        elseif ($delta -lt -$DiffTolerance) { [pscustomobject]@{ Class = 'Older';   Rel = $rel } }
        elseif ($s.Length -ne $d.Length)    { [pscustomobject]@{ Class = 'Changed'; Rel = $rel } }
    }

    foreach ($rel in $dstFiles.Keys) {
        if (-not $srcFiles.ContainsKey($rel)) {
            [pscustomobject]@{ Class = '*EXTRA File'; Rel = $rel }
        }
    }
}

function Get-DestKey([string]$Src) {
    Join-Path $Src.Substring(0,1).ToUpper() $Src.Substring(3).TrimEnd('\')
}

# FIX v2.6: describes what a live path really is, for use in error messages.
function Get-PathDiagnosis([string]$Path) {
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if (-not $item) { return "  (live path could not be resolved with Get-Item)" }
    $drive = if ($item.PSDrive) { $item.PSDrive.Name } else { '<none>' }
    $root  = if ($item.Root)    { $item.Root }         else { '<none>' }
    @(
        "  FullName   : $($item.FullName)"
        "  Attributes : $($item.Attributes)"
        "  LinkType   : $($item.LinkType)"
        "  Target     : $($item.Target -join ', ')"
        "  PSDrive    : $drive"
        "  Root       : $root"
    ) -join [Environment]::NewLine
}

# ---------- main ----------
$snaps  = @{}
$failed = @()
try {
    if ($Mode -eq 'Incremental') {
        $missing = $SourceDirs | Where-Object {
            (Test-Path $_) -and -not (Test-Path (Join-Path $FullRoot (Get-DestKey $_)))
        }
        if ($missing) {
            Write-Warning "No Full backup for: $($missing -join ', '). Switching to Full mode."
            $Mode = 'Full'
        }
    }

    $drives = $SourceDirs | Where-Object { Test-Path $_ } |
              ForEach-Object { $_.Substring(0,1).ToUpper() } | Sort-Object -Unique
    foreach ($d in $drives) {
        Write-Host "Creating snapshot of ${d}: ..."
        $snaps[$d] = New-Snapshot $d
    }

    foreach ($src in $SourceDirs) {
        if (-not (Test-Path $src)) {
            Write-Warning "Skipping missing source: $src"
            # FIX v2.8: log missing source.
            Add-Skip $src 'MissingSource'
            continue
        }

        try {
            # FIX v2.6: if the source is a reparse point (junction, symlink,
            # mount point), skipping is the safe default. Following it into a
            # volume that isn't in the snapshot set produces the exact
            # "Test-Path true / Get-Item false" symptom you saw.
            $liveItem = Get-Item -LiteralPath $src -Force -ErrorAction SilentlyContinue
            if (-not $liveItem) {
                throw "Live path cannot be resolved with Get-Item: $src"
            }
            $isReparse = [bool]($liveItem.Attributes -band [IO.FileAttributes]::ReparsePoint)
            if ($isReparse -and $SkipReparsePoints) {
                Write-Warning ("SKIP (reparse point): $src" + [Environment]::NewLine +
                    (Get-PathDiagnosis $src) + [Environment]::NewLine +
                    "  If the Target lives on another drive, replace the entry in " +
                    "`$SourceDirs with that target path and re-run; the script will " +
                    "snapshot the target drive automatically.")
                # FIX v2.8: log reparse-point skip.
                Add-Skip $src 'ReparsePoint'
                continue
            }

            $drive   = $src.Substring(0,1).ToUpper()
            $snap    = $snaps[$drive]
            $rel     = $src.Substring(3).TrimEnd('\')
            $key     = Get-DestKey $src
            $snapSrc = Join-Path $snap.Link $rel
            $xd      = @(Get-SnapExcludes $drive $snap.Link)

            # FIX v2.6: use Get-Item (not Test-Path) here, because Test-Path
            # follows reparse points across the snapshot boundary and gives a
            # misleading $true. If Get-Item fails, report it as a snapshot-
            # scope problem with full topology diagnostics.
            try {
                $null = Get-Item -LiteralPath $snapSrc -Force -ErrorAction Stop
            }
            catch {
                throw ("Snapshot path not resolvable: '$snapSrc'" +
                    [Environment]::NewLine + "Live source:" + [Environment]::NewLine +
                    (Get-PathDiagnosis $src) + [Environment]::NewLine +
                    "This almost always means the source is a reparse point whose " +
                    "target lives on a volume that is NOT in the snapshot set " +
                    "(snapshots currently: $($snaps.Keys -join ', ')). " +
                    "Replace the entry in `$SourceDirs with the reparse point's " +
                    "target path, or add the target drive to `$SourceDirs.")
            }

            Write-Host "`n=== $Mode : $src ==="

            switch ($Mode) {

                'Full' {
                    $dst = Join-Path $FullRoot $key
                    New-Item -ItemType Directory -Path $dst -Force | Out-Null

                    $supBase = Join-Path (Join-Path $SuperRoot $Stamp) $key
                    try {
                        $diff = @(Get-TreeDiff $snapSrc $dst $xd |
                                Where-Object { $_.Class -in '*EXTRA File','Newer','Older','Changed' })
                    }
                    catch {
                        throw "Get-TreeDiff failed for '$snapSrc' -> '$dst': $($_.Exception.Message)"
                    }
                    foreach ($f in $diff) {
                        $from = Join-Path $dst     $f.Rel
                        $to   = Join-Path $supBase $f.Rel
                        if (Test-Path -LiteralPath $from) {
                            New-Item -ItemType Directory -Path (Split-Path $to) -Force | Out-Null
                            Move-Item -LiteralPath $from -Destination $to -Force
                        }
                    }
                    Write-Host "Superseded files moved: $($diff.Count)"

                    $a = @($snapSrc,$dst,'/MIR','/COPY:DAT','/DCOPY:T','/FFT','/XJ','/R:1','/W:1','/NP','/NDL') + $EncArgs
                    if ($xd) { $a += '/XD'; $a += $xd }
                    Invoke-Robo $a
                }

                'Incremental' {
                    $full = Join-Path $FullRoot $key
                    $dst  = Join-Path (Join-Path $IncRoot $Stamp) $key

                    try {
                        $changed = @(Get-TreeDiff $snapSrc $full $xd |
                                   Where-Object { $_.Class -in 'New File','Newer','Older','Changed' })
                    }
                    catch {
                        throw "Get-TreeDiff failed for '$snapSrc' -> '$full': $($_.Exception.Message)"
                    }
                    Write-Host "Files new/changed vs Full: $($changed.Count)"
                    foreach ($f in $changed) {
                        $from = Join-Path $snapSrc $f.Rel
                        $to   = Join-Path $dst     $f.Rel
                        if (-not (Test-Path -LiteralPath $from)) {
                            Write-Warning "Diff entry no longer present, skipping: $from"
                            # FIX v2.8: log vanished-before-copy.
                            Add-Skip $from 'VanishedBeforeCopy'
                            continue
                        }
                        # FIX v2.7: removed redundant per-file EFS check.
                        # Get-TreeDiff already filters EFS files out of $changed
                        # and records them in $script:EfsSkipped.
                        New-Item -ItemType Directory -Path (Split-Path $to) -Force | Out-Null
                        # FIX v2.8: do not abort the source on a single copy failure.
                        try {
                            Copy-Item -LiteralPath $from -Destination $to -Force -ErrorAction Stop
                        }
                        catch {
                            Add-Skip $from ("CopyFailed: " + $_.Exception.Message)
                        }
                    }
                }

                'Archive' {
                    $dst = Join-Path (Join-Path $ArchRoot $Stamp) $key
                    New-Item -ItemType Directory -Path $dst -Force | Out-Null
                    $a = @($snapSrc,$dst,'/E','/COPY:DAT','/DCOPY:T','/FFT','/XJ','/R:1','/W:1','/NP','/NDL') + $EncArgs
                    if ($xd) { $a += '/XD'; $a += $xd }
                    Invoke-Robo $a
                }
            }
        }
        catch {
            Write-Warning "FAILED, skipping ${src}: $($_.Exception.Message)"
            $failed += $src
            # FIX v2.8: log failed source with exception message.
            Add-Skip $src ("FailedSource: " + $_.Exception.Message)
        }
    }

    if ($failed) { Write-Warning "Sources that failed: $($failed -join ', ')" }
    Write-Host "`nDone: $Mode ($Stamp)"
}
finally {
    # FIX v2.7: write EFS-skipped log and summary before tearing down.
    if ($script:EfsSkipped.Count -gt 0) {
        $efsLog = Join-Path $LogRoot "EFS_skipped_$Stamp.log"
        try {
            $script:EfsSkipped | Set-Content -LiteralPath $efsLog -Encoding UTF8
            Write-Warning ("EFS files skipped: $($script:EfsSkipped.Count) " +
                           "(see $efsLog)")
        }
        catch {
            Write-Warning "Could not write EFS skip log: $($_.Exception.Message)"
        }
    }

    # FIX v2.8: unified skip log (CSV) + grouped summary.
    if ($script:Skipped.Count -gt 0) {
        $skipLog = Join-Path $LogRoot "Skipped_$Stamp.csv"
        try {
            $script:Skipped | Export-Csv -LiteralPath $skipLog -NoTypeInformation -Encoding UTF8
            $byReason = $script:Skipped | Group-Object Reason | Sort-Object Name |
                        ForEach-Object { "  $($_.Name): $($_.Count)" }
            Write-Warning ("Skipped items: $($script:Skipped.Count) (see $skipLog)" +
                           [Environment]::NewLine + ($byReason -join [Environment]::NewLine))
        }
        catch {
            Write-Warning "Could not write skip log: $($_.Exception.Message)"
        }
    }

    foreach ($s in $snaps.Values) { Remove-Snapshot $s }
    Stop-Transcript | Out-Null
}

if ($failed) { exit 1 }