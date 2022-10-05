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

if(-not (get-module PSSQLite -ListAvailable)) {
   #https://github.com/RamblingCookieMonster/PSSQLite
   Install-Module -name PSSQLite -repository PSGallery -Force -Scope AllUsers
}

#endregion

#region set output path
# This is largely driven from whether CrowdStrike Fusion (Workflow) can use an output parameter to "get" the file or it requires an arbitrary path
# Also the scriptblock used to get the screenshots may need a static path.
# Not having a dynamic path may mean that we cannot collect information periodically over time and later access it on the device.

# Use dynamic path
#$path = "$env:temp\Collection-$((Get-Date).ToFileTime())"

# Use static path - Also m
$path = "C:\windows\TEMP\Collect-User-Information"

# Remove old files and create new folder
if(Test-Path $path){
    Remove-Item $path -Recurse
}
if(Test-Path "$path.zip"){
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
Sleep -Seconds 2
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

#region collect download items from the last month

if (Test-Path "C:\Users\$Username\Downloads\") {
    Get-ChildItem -Path "C:\Users\$Username\Downloads\" -Force -Recurse -ErrorAction SilentlyContinue | ?{$_.Directory -and $_.LastWriteTime -gt (Get-Date).AddMonths(-1)}| Select @{N='SHA256';E={(Get-FileHash -Path $_.FullName).Hash}},LastWriteTime,FullName | Export-csv "$path\downloadFiles.csv" -NoTypeInformation
}

#endregion

#region collect browser data - Chromium browsers like Chrome or Edge

#Identify chromium browser paths, extended to support multiple profiles as long as there is a history file which is SQLite
$chromiumBrowserPaths = (Get-ChildItem "C:\Users\$Username\AppData\Local\*\*\User Data\*\" | Where-Object { (Test-Path "$_\History") -and [char[]](Get-Content "$($_.FullName)\History" -Encoding byte -TotalCount 'SQLite format'.Length) -join ''}).FullName

$chromiumBrowserPaths | ForEach-Object {
    $destPrefix = ($_ | Where-Object { $_ -match "([^\\]+\\[^\\]+)\\User Data\\(.+)\\" } | ForEach-Object { $matches[1] + $matches[2] }) -replace "\\|\s",""

    #https://pupuweb.com/solved-how-open-google-chrome-history-file/
    
    if(Get-Command Invoke-SqliteQuery) {
        #Query history
        
        #Downloads
        # Work around for locked database (hopefully)
        Copy-Item -Path "$_\History" -Destination "$_\History-copy"
        Invoke-SqliteQuery -Query "SELECT datetime(end_time/1000000-11644473600,'unixepoch','localtime'),current_path,referrer,mime_type,total_bytes FROM downloads" -Path "$_\History-copy" -QueryTimeout 100 | Export-Csv -Path "$path\$($destPrefix)Downloads.csv" -NoTypeInformation

        #History
        Invoke-SqliteQuery -Query "SELECT datetime(last_visit_time/1000000-11644473600,'unixepoch','localtime'),title,url FROM urls" -Path "$_\History-copy" -QueryTimeout 100 | Export-Csv -Path "$path\$($destPrefix)History.csv" -NoTypeInformation
        Remove-Item -Path "$_\History-copy"
    }
    else {
        Copy-Item "$_\History" -Destination "$path\$($destPrefix)History.sqlite"
    }

    #Fallback in case queries don't work as expected
    Get-Content "$_\History" | Select-String -Pattern '(htt(p|s))://([\w-]+\.)+[\w-]+(/[\w- ./?%&=]*)*?' -AllMatches | ForEach-Object { ($_.Matches).Value } | Select -Unique | Add-Content -Path "$path\$($destPrefix)HistoryURL.txt"
}

#endregion

#region collect browser data - internet explorer

if (Get-Process iexplore -ErrorAction SilentlyContinue) {
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
    
    if(Get-Command Invoke-SqliteQuery) {
        Copy-Item -Path "$browserFiles\places.sqlite" -Destination "$browserFiles\places.sqlite-copy"
        Invoke-SqliteQuery -Query "SELECT datetime(last_visit_date/1000000-11644473600,'unixepoch','localtime'),title,url from moz_places" -Path "$browserFiles\places.sqlite-copy" | Export-Csv -Path "$path\firefoxHistory.csv" -NoTypeInformation
        Remove-Item -Path "$browserFiles\places.sqlite-copy"
    }
    else {
        Copy-Item "$browserFiles\places.sqlite" -Destination "$path\firefoxHistory.sqlite"
    }
    Get-Content "$browserFiles\places.sqlite" | Select-String -Pattern '(htt(p|s))://([\w-]+\.)+[\w-]+(/[\w- ./?%&=]*)*?' -AllMatches | ForEach-Object { ($_.Matches).Value } | Select -Unique | Add-Content -Path "$path\$($destPrefix)PlacesUrl.txt"
}

#endregion

#region collect windows events for last hour

Get-EventLog -LogName * -ErrorAction SilentlyContinue -After (Get-Date).AddHours(-1) | Select -ExpandProperty Entries | Export-csv "$path\windowsEvents.csv" -NoTypeInformation 

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
