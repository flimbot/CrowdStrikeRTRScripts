# CrowdStrike RTR Scripts
Real Time Response is one feature in my CrowdStrike environment which is underutilised.
I wanted to start using my PowerShell to augment some of the gaps for collection and response.
Each script will contain an inputschema or outputschema if neccessary, with the intended purpose to use them in Falcon Fusion Workflows.

Hopefully the files are self explanatory.

### Collect-User-Information
This was born from the need to attribute user actions to detections or incidents by capturing their screen, their browser history, download directory and more at the time it occurred. This is a work in progress as it does not yet upload the captured information to CrowdStrike.

An upshot of the code:
* Currently attempts to install the PSSQLite module. I dislike that, and would like to replace it to deploy an assembly at some point.
* Temporary path is set to c:\windows\temp\collect-user-information\ because couldn't get the output path from CrowdStrike Fusion to then download
* Collects:
  * Script variables and environment variables, noting this is collected as SYSTEM
  * Screenshots of all monitors, noting that 2k and 4k screens mess with this. The work around to execute as a user creates a scheduled task and runs in the users context. That will look bad if you are not aware of it.
  * Open TCP connections
  * PowerShell history
  * DNS cache
  * Running processes
  * Cached outlook files
  * List of files in recycle bin and downloads folder, along with SHA256 hashes
  * All Chromium variant browser history and download history as CSV (with PSSQLite module) or fallback to grabbing whole sqlite file and dump url strings for quick lookup.
  * INetCache files, this needs to be improved for Internet Explorer (yes, it's still in use in places)
  * Firefox browser history as CSV (with PSSQLite module) or fallback to grabbing whole sqlite file and dump url strings for quick lookup.
  * Windows Event log for past hour

This is all compressed into file c:\windows\temp\collect-user-information.zip


Execute from Real Time Response:
```
runscript -CloudFile=Collect-User-Information
```
or
```
runscript -CloudFile=Collect-User-Information -CommandLine=```'{"Username": "USERNAMEHERE"}'```
```

### Message-User
This script is simple and uses Remote Desktop messaging to present a messagebox to the user.
It's not very robust, as I cannot get the user session dynamically just yet and it would be better as a toast popup.
It was just thrown together as a proof of concept for use with automatic containment to inform the user, but can be used for anything.

Execute from Real Time Response:
```
runscript -CloudFile=Message-User -CommandLine=```'{"message": "test"}'```
```
