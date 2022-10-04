#Run in CrowdStrike RTR with:
# runscript -CloudFile=Collect-User-Information
#   or
# runscript -CloudFile=Collect-User-Information -CommandLine=```'{"Username": "40046051"}'```

# I dislike this, but limited alternatives
$sessions = (((query user /server:$env:COMPUTERNAME) -replace '^>', '') -replace '\s{2,}', ',' | ConvertFrom-Csv)

#region parameters

if($args) {
    $Username = $args[0] | ConvertFrom-Json | Select -ExpandProperty 'Username'
}
else {
    #Attempt to get username of who is currently signed in interactively
    $Username = $sessions[0].USERNAME
}

#endregion

#region modules/assemblies

try {
    if(-not (get-module mysqlite -ListAvailable)) {
        Install-Module -name MySQLite -repository PSGallery -Force
    }
} catch {}

#endregion

#region set output path
# This is largely driven from whether CrowdStrike Fusion (Workflow) can use an output parameter to "get" the file or it requires an arbitrary path

# Use dynamic path
$path = "$env:temp\Collection-$((Get-Date).ToFileTime())"

# Use static path
#$path = "C:\windows\TEMP\Collect-User-Information"

# Remove old files and create new folder
if(Test-Path $path){
    Remove-Item $path -Recurse
    Remove-Item "$path.zip"
}
New-Item $path -ItemType Directory | Out-Null
Write-Verbose "Saving to: $path"

#endregion

#region collect variables

Get-Variable | Export-Csv "$path\scriptVariables.csv" -NoTypeInformation 
Get-ChildItem env: | Export-Csv "$path\EnvironmentVariables.csv" -NoTypeInformation 

#endregion

#region collect screenshots

# As RTR runs as system, it does not have access to the user's session. 
# Using task scheduler as work around
# If this doesnt work:
#  - Interesting use of PsExec to interact with desktop session: https://stackoverflow.com/questions/59996907/how-to-take-a-remote-screenshot-with-powershell
#  - Potential alternative: https://github.com/npocmaka/batch.scripts/blob/master/hybrids/.net/c/screenCapture.bat

$taskScriptBlock = {
    Add-Type -AssemblyName System.Windows.Forms
    $i = 0;
    [System.Windows.Forms.Screen]::AllScreens | ForEach-Object {
        $screen = $_.WorkingArea;

        $image = New-Object System.Drawing.Bitmap($screen.Width, $screen.Height);
        $graphic = [System.Drawing.Graphics]::FromImage($image);
        $graphic.CopyFromScreen($screen.X,$screen.Y,0,0,$image.Size);
        $image.Save( "C:\windows\TEMP\Collect-User-Information\screen-$i.png", [System.Drawing.Imaging.ImageFormat]::Png);

        $i++;
    }
}

# Encoding the command: https://stackoverflow.com/questions/56107842/any-program-for-turning-a-multi-line-powershell-script-into-an-encoded-command
$commandBytes = [System.Text.Encoding]::Unicode.GetBytes($taskScriptBlock)
$encodedCommand = [Convert]::ToBase64String($commandBytes)

# Use task scheduler to execute as user: https://stackoverflow.com/questions/71328838/how-do-i-run-a-remote-command-in-a-specific-session-on-a-remote-computer
$taskAction = New-ScheduledTaskAction -Execute 'PowerShell.exe' -Argument "-EncodedCommand $encodedCommand"
$taskRegist = Register-ScheduledTask -TaskName 'RTR Screenshot' -Description 'Take screenshot for Real Time Response data collection' -Action $taskAction -User $Username -Settings (New-ScheduledTaskSettingsSet -Hidden:$true)
$taskStart  = Start-ScheduledTask -TaskPath $taskRegist.TaskPath -TaskName $taskRegist.TaskName
Sleep -Seconds 1
while($taskRegist.State -ne 'Ready') {
    Sleep -Milliseconds 100
}
$taskUnregi = Unregister-ScheduledTask -TaskPath $taskRegist.TaskPath -TaskName $taskRegist.TaskName -Confirm:$false

#endregion

#region collect network connections

Get-NetTCPConnection | Export-Csv "$path\networkConnections.csv" -NoTypeInformation 

#endregion

#region collect powershell historys

Get-History | Export-csv "$path\powershellHistory.csv" -NoTypeInformation 

#endregion

#region collect DNS cache

Get-DnsClientCache | Export-csv "$path\dnsCache.csv" -NoTypeInformation 

#endregion

#region collect processes

Get-Process | Select id,Path,ProcessName,Product,Description,TotalProcessorTime,Fileversion,MainWindowTitle,starttime | Export-csv "$path\processes.csv" -NoTypeInformation

#endregion

#region collect cached outlook content from the last month

if (Test-Path "C:\Users\$Username\AppData\Local\Microsoft\Windows\INetCache\Content.Outlook\") {
    Get-ChildItem "C:\Users\$Username\AppData\Local\Microsoft\Windows\INetCache\Content.Outlook\" -Recurse | ?{$_.Directory -and $_.LastWriteTime -gt (Get-Date).AddMonths(-1)}| Select @{N='SHA256';E={(Get-FileHash -Path $_.FullName).Hash}},LastWriteTime,FullName | Export-csv "$path\outlookCacheFiles.csv" -NoTypeInformation
}

#endregion

#region collect recycle bin items from the last month

if (Test-Path "C:\$Recycle.Bin") {
    Get-ChildItem -Path 'C:\$Recycle.Bin' -Force -Recurse -ErrorAction SilentlyContinue | ?{$_.Directory -and $_.LastWriteTime -gt (Get-Date).AddMonths(-1)}| Select @{N='SHA256';E={(Get-FileHash -Path $_.FullName).Hash}},LastWriteTime,FullName | Export-csv "$path\recycleBinFiles.csv" -NoTypeInformation
}

#endregion

#region collect browser data - Chrome/Edge

# This could be expanded to cover all chromium browsers.. maybe by testing for a file or file we expect in the structure.
@('Google\Chrome','Microsoft\Edge') | Where-Object { Test-Path "C:\Users\$Username\AppData\Local\$_\User Data\Default" } | ForEach-Object {
    $browserFiles = "C:\Users\$Username\AppData\Local\$_\User Data\Default"
    $destPrefix = $_ -replace "\\",""

    Write-Verbose $destPrefix

    #https://pupuweb.com/solved-how-open-google-chrome-history-file/
    Copy-Item "$browserFiles\History" -Destination "$path\$($destPrefix)History.sqlite"
    if(Get-Command Invoke-MySQLiteQuery) {
        #Query history
    }

    Get-Content "$browserFiles\History" | Select-String -Pattern '(htt(p|s))://([\w-]+\.)+[\w-]+(/[\w- ./?%&=]*)*?' -AllMatches | ForEach-Object { ($_.Matches).Value } | Select -Unique | Add-Content -Path "$path\$($destPrefix)HistoryURL.txt"

    #this will fail on files in use
    Copy-Item "$browserFiles\Sessions" -Destination "$path\$($destPrefix)Sessions" -Recurse -Container -ErrorAction SilentlyContinue
}

#endregion

#region collect browser data - internet explorer

if (Get-Process iexplore -ErrorAction SilentlyContinue) {

    Write-Verbose "Internet Explorer"

    # Internet Explorer
    if(Test-Path "C:\Users\$Username\AppData\Local\Microsoft\Windows\INetCache") {
        Copy-Item "C:\Users\$Username\AppData\Local\Microsoft\Windows\INetCache" -Destination "$path\INetCache"
    }

    #shell:history

    # Borrow from: https://github.com/freeload101/CrowdStrike_RTR_Powershell_Scripts/blob/main/Get-BrowserData.ps1
    #better yet.. https://gist.github.com/PolarBearGod/8e6990948c78792148db83c022310284

}

#endregion

#region collect browser data - mozilla firefox

if ((Test-Path "C:\Program Files\Mozilla Firefox\")) {
    # Mozilla Firefox

    $browserFiles = (Get-ChildItem "C:\Users\$Username\AppData\Roaming\Mozilla\Firefox\Profiles" | Sort-Object LastWriteTime -Descending | Select -First 1).FullName
    Write-Verbose "Firefox"
    
    if(Get-Command Invoke-MySQLiteQuery) {
        #Query history
        Invoke-MySQLiteQuery -Path "$browserFiles\places.sqlite" -Query "SELECT last_visit_date,title,url from moz_places" | Select @{N="last_visit_date_readable";E={(Get-Date -Date '1970-01-01 00:00:00').AddMilliseconds($_.last_visit_date/1000)}},* | Export-Csv -Path "$path\firefoxHistory.csv" -NoTypeInformation
    }
    else {
        Copy-Item "$browserFiles\places.sqlite" -Destination "$path\firefoxHistory.sqlite"
    }
}

#endregion

#region collect windows events for last 6 hours

Get-EventLog -LogName * -ErrorAction SilentlyContinue -After (Get-Date).AddHours(-6) | Select -ExpandProperty Entries | Export-csv "$path\windowsEvents.csv" -NoTypeInformation 

#endregion

#region compress results

Compress-Archive -Path "$path\*" -DestinationPath "$path.zip" -CompressionLevel Optimal

#endregion

#region output parameter for CrowdStrike

@{'Path' = "$path.zip"} | ConvertTo-Json -Compress

#endregion

#region attempt 'get' command in RTR

If(Get-Command "get" -ErrorAction SilentlyContinue) {
    # Command not available
    Write-Host "Uploading to CrowdStrike..."
    get "$path.zip"
}

#endregion