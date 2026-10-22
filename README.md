# pbs-resources

**Client:** Portage Bay Solutions (internal, published publicly)
**Built by:** Portage Bay Solutions
**Status:** active

Reusable scripts, tools, and FileMaker resources from Portage Bay Solutions, published under the MIT licence for anyone administering FileMaker Server.

## Contents

| Path | What it does |
|---|---|
| `server_management_scripts/Windows/FMS-Restart-Server.ps1` | Safely shuts down FileMaker Server on Windows (disconnects clients, closes hosted files, verifies) and then restarts the machine. If any step fails it reopens the databases and exits without restarting. If FileMaker Server is not detected it performs a plain restart. |

## Getting started

### FMS-Restart-Server.ps1

Prerequisites:

- Windows PowerShell 5.1 or later, run as an administrator
- FileMaker Server installed at the default path (`C:\Program Files\FileMaker\FileMaker Server\Database Server\fmsadmin.exe`)
- A FileMaker Server Admin Console account

Run:

```powershell
.\FMS-Restart-Server.ps1 "fmsadmin_user" "fmsadmin_password"
```

The script **restarts the computer** (`Restart-Computer -Force`) once the safe shutdown succeeds, or immediately if FileMaker Server is not detected. Read it before running it.

Behaviour worth knowing:

- Retries client disconnect and file close up to 10 times, 4 seconds apart.
- Logs to `C:\ProgramData\fms_restart\fms_shutdown.log`, rotated at 5 MB (three old copies kept). Credentials are not written to the log.
- A lock file in `%TEMP%` prevents concurrent runs.
- Credentials are passed to `fmsadmin.exe` as command-line arguments, so they are briefly visible in the process list to local administrators, and may be retained by whatever launched the script (shell history, scheduled-task definitions, RMM job logs). Use a dedicated Admin Console account and prefer a launcher that does not record parameters.

## Configuration

`FMS-Restart-Server.ps1` takes no environment variables. Paths, retry count, retry interval, and log size are constants at the top of the script.

## License

MIT. See `LICENSE`.

## Security

Report vulnerabilities privately to Portage Bay Solutions (info@portagebay.com). Do not open public issues for security problems.
