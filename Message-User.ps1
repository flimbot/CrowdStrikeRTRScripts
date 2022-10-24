# runscript -CloudFile=Message-User -CommandLine=```'{"message": "test"}'```

$message = $args[0] | ConvertFrom-Json | Select -ExpandProperty 'message'
if($message) {
    Send-RDUserMessage -MessageTitle 'CrowdStrike' -MessageBody $message -HostServer $env:COMPUTERNAME -UnifiedSessionID 1
}