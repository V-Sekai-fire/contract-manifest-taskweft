```
# POSIX Shell
curl -fsSL https://raw.githubusercontent.com/V-Sekai-fire/manifest-weftspun/main/main/bootstrap.sh | sh
# Windows Powershell
irm https://raw.githubusercontent.com/V-Sekai-fire/manifest-weftspun/main/main/bootstrap.ps1 | iex
```

Run on a bare machine to get a synced, tooled workspace.

```
# POSIX Shell
WEFTSPUN_GIT_LFS=1 sh bootstrap.sh
# Windows Powershell
$env:WEFTSPUN_GIT_LFS = '1'; ./bootstrap.ps1
```

The Hugging Face projects are git-lfs. To pull them as well, at a cost of tens of gigabytes do:
