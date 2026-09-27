```
# POSIX Shell
curl -fsSL https://raw.githubusercontent.com/V-Sekai-fire/contract-bootstrap/main/main/bootstrap.sh | sh
# Windows Powershell
irm https://raw.githubusercontent.com/V-Sekai-fire/contract-bootstrap/main/main/bootstrap.ps1 | iex
```

Run on a bare machine to get a synced, tooled workspace. The bootstrap scripts,
the pixi environment and their pins live in `V-Sekai-fire/contract-bootstrap`,
which this manifest places and linkfiles to the workspace root. This repository
carries the manifest (`default.xml`) and its gates.
