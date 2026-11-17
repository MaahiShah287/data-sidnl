# Windows (Task Scheduler): run in PowerShell from the project folder. Times are the PC's local time (set it to IST).
# The PC must be on and awake at those times; a always-on server/VM is more reliable.
$py  = (Resolve-Path ".\.venv\Scripts\python.exe").Path
$dir = (Get-Location).Path
$act = New-ScheduledTaskAction -Execute $py -Argument "-m zepto_fp.run fetch --mode daily" -WorkingDirectory $dir
foreach ($t in @(@("Zepto-FP-Morning","07:00"), @("Zepto-FP-Evening","19:00"))) {
  $trg = New-ScheduledTaskTrigger -Daily -At $t[1]
  Register-ScheduledTask -TaskName $t[0] -Action $act -Trigger $trg -Force -Settings (New-ScheduledTaskSettingsSet -StartWhenAvailable -WakeToRun)
}
