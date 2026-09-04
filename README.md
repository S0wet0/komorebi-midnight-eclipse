# komorebi · Midnight Eclipse preset

A keyboard-first [komorebi](https://github.com/LGUG2Z/komorebi) setup for Windows 11: tight 2px gaps, a soft blue focus border, nine workspaces, and Alt-based keybindings that leave Windows' own Win-key shortcuts alone. It leaves the top 44px free for the [Midnight Eclipse Zebar bar](https://github.com/S0wet0/midnight-eclipse).

## Install

```powershell
git clone https://github.com/S0wet0/komorebi-midnight-eclipse.git
cd komorebi-midnight-eclipse
powershell -NoProfile -ExecutionPolicy Bypass -File .\install.ps1
komorebic start --whkd
```

`install.ps1` copies `komorebi.json` and `whkdrc` into place, backing up any existing files, and downloads komorebi's community app rules (`applications.json`).

## License

[MIT](LICENSE) © 2026 S0wet0
