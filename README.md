# CrowdStrike RTR Scripts
Real Time Response is one feature in my CrowdStrike environment which is underutilised.
I wanted to start using my PowerShell to augment some of the gaps for collection and response.
Each script will contain an inputschema or outputschema if neccessary, with the intended purpose to use them in Falcon Fusion Workflows.

Hopefully the files are self explanatory.

### Collect-User-Information
This was born from the need to attribute user actions to detections or incidents by capturing their screen, their browser history, download directory and more at the time it occurred. This is a work in progress as it does not yet upload the captured information to CrowdStrike.

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
