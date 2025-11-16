# Setting up Automation to enable HoYoPass in HoYoPlay

All the files you need is in the root of the repository

## Preconfigure Setup

Download and run the `setup_official_client.ps1`

If for some reason PowerShell Core block downloaded script, run the following command:
```pwsh
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
```

Choose if you have either the global launcher or CN launcher. The Script will then configure:
- URI Protocols
- Startup Settings (if Launch Launcher on Startup is enabled)
- Desktop Shortcuts (or where you put your shortcut)

## Automation

Download `Monitor.ps1` and save it somewhere, preferably Root of your Windows Disk (C:/)

i.e: `C:/Scripts/Monitor.ps1`

You can rename it if you want

Open Task Scheduler and create a new task.

### General Tab

Name: Enable HoYoPass in HoYoPlay

Security Options:

- Run only when user is logged on: Check
- Run with highest privileges: Check

### Trigger Tab

Create a new Trigger

- Begin the task: At log on
- Settings: Depends if you want Any user or Specific User
- Make sure the last box "**Enabled**" is checked

### Actions Tab

Create a new action

- Action: Start a program
- Program/script: pwsh (Note: Must be PowerShell Core `pwsh` and not Windows PowerShell `powershell`)
- Arguments: `-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "C:\Path\ToYour\Script"`. Example: `-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "C:\Scripts\Monitor.ps1"`

### Conditions Tab

Make sure everything is unchecked!

### Settings Tab

Check the following boxes:

- Allow task to be run on demand
- Run task as soon as possible after a scheduled staer is missed
- If the running task does not end when requested, force it to stop.

### Notes

- After you reboot and login to your PC, you may see a PowerShell Window, this is expected behavior, the window will go away.
- Windows will always prioritze Services and Scheudled tasks first before any apps run. So you should have enough time before HoYoPlay's User Account Control Prompt appears.
- It may take a few seconds for HoYoPlay to enable HoYoPass. If for some reasons HoYoPlay doesn't enable HoYoPass for a long while, check the above if you have make any mistake when making this scheudled task. Otherwise, feel free to open an issue.
- You will need to rerun the setup script if you just disabled and reenable the startup on login in HoYoPlay Settings