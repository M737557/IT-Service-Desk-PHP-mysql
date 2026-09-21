$computers = @('VLA-DT-1101','VLA-DT-1102','VLA-DT-1103','VLA-DT-1104','VLA-DT-1105',

        'VLA-DT-1106','VLA-DT-1107','VLA-DT-1108','VLA-DT-1109','VLA-DT-1110',

        'VLA-DT-1111','VLA-DT-1112','VLA-DT-1113','VLA-DT-1114','VLA-DT-1115',

        'VLA-DT-1116','VLA-DT-1117','VLA-DT-1118','VLA-DT-1119','VLA-DT-1120',

        'VLA-DT-1121','VLA-LT-003','VLA-LT-005','VLA-LT-006',

        'VLA-LT-1021','VLA-LT-1022','VLA-LT-1151')

 

# Read the script content ONCE

$scriptContent = Get-Content -Path 'C:\scripts\assets.ps1' -Raw

 

# Run on each machine. Because the script uses `exit`, wrap it so it

# doesn't kill the remote session.

$results = Invoke-Command -ComputerName $computers -ErrorAction Continue -ScriptBlock {

    param($scriptText)

 

    # Run the script in a child scope; capture exit code without exiting session

    try {

        $sb = [ScriptBlock]::Create($scriptText + "`n; `$global:LASTEXIT = 0")

        & $sb 2>&1 | ForEach-Object { $_ }

    } catch {

        Write-Output "ERROR: $($_.Exception.Message)"

    }

} -ArgumentList $scriptContent -ThrottleLimit 2

 

# Show results per machine

$results | Format-Table PSComputerName, Message -AutoSize -Wrap
