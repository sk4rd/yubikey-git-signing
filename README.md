# setup-yubikey-git-signing

One PowerShell script that sets up **YubiKey-signed git commits and tags on a fresh
Windows machine**, using the GnuPG that ships with Git for Windows, and fixes the
failure mode that makes people think their key is broken.

```
Please insert the card with serial number: 25 123 456
```

...on screen while that exact key is plugged in and working. That happens when a
machine has more than one GnuPG installation (say Git for Windows plus Gpg4win, both
shipped with a YubiKey setup). Each GnuPG opens a PC/SC smart card *exclusively*, so
whichever one touches the card first locks the other one out. The script puts every
GnuPG it finds into shared mode, so they take turns.

## Requirements

* Windows 10 or 11
* [Git for Windows](https://git-scm.com/download/win) (its GnuPG is what git will use)
* A YubiKey with keys on its OpenPGP applet, plugged in
* No administrator rights

## Usage

Copy `setup-yubikey-git-signing.ps1` and `setup-yubikey-git-signing.cmd` anywhere,
double-click the `.cmd`, or:

```powershell
powershell -ExecutionPolicy Bypass -File setup-yubikey-git-signing.ps1 `
    -GitName "Your Name" -GitEmail you@example.com -Test
```

| Parameter | Meaning |
|---|---|
| `-GitName`, `-GitEmail` | git identity to set (left alone if omitted and already set) |
| `-SigningKey` | key to sign with, default: the card's signature subkey |
| `-GitRoot` | Git for Windows install root, if it is somewhere unusual |
| `-Test` | make one throwaway signature and verify it (asks for your PIN) |
| `-WithSshSupport` | let gpg-agent also serve as an ssh-agent |

Re-running is safe: existing settings are never clobbered, and anything it does write
is additive (a backup is taken if it has to touch a `scdaemon.conf` you already had).

## What it does

1. finds git and the GnuPG that ships with Git for Windows
2. writes `scdaemon.conf` with `pcsc-shared` for that GnuPG **and** for every other
   GnuPG installation it finds. This has to happen *before* the card is touched: a
   GnuPG without it cannot see a card another GnuPG is holding
3. makes sure the card's public key is in the keyring (fetching it from the URL stored
   on the card, or printing the exact import commands if there is none), which creates
   the shadow key stubs used for signing
4. sets `gpg.program`, `commit.gpgsign`, `tag.gpgsign` and `user.signingkey` in git
5. installs `%USERPROFILE%\bin\start-gpg-agent.cmd` plus an HKCU Run entry
   (`GpgAgentYubiSSH`) so the agent is up after every reboot, with a repair pass that
   clears wedged daemons and dead socket files when the card is not visible
6. prints a summary, and with `-Test` proves a signature round-trips

## Notes for anyone writing similar scripts

Found the hard way, all of them verified on a real machine:

* Git for Windows' GnuPG is a Msys build: pass it **POSIX paths** (`/c/Users/...`) and
  a POSIX `HOME`. `-H`/`--homedir C:\...` or `HOME=C:\...` silently resolves to a
  nonsense directory and everything after that fails in confusing ways.
* `pcsc-shared` must be in place before the first card access, otherwise the keyring
  cannot see a card another GnuPG holds.
* `$Home` is a read-only automatic variable in PowerShell; a function parameter named
  `-Home` fails at bind time and (with default error handling) the whole function body
  is skipped silently. Verify what you wrote.
* gpg only parses options that come **before** the first filename. `--local-user` after
  the input file is read as another filename.
* A pinentry window can open behind other windows; commits from GUI clients need the
  GUI pinentry (`pinentry-program /usr/bin/pinentry-w32`), not the console one.

## Troubleshooting

See [the troubleshooting section of the guide](setup-yubikey-git-signing.md); the short
version:

* card not reachable: replug the YubiKey. Windows sometimes fails to load the CCID
  driver at boot (`WUDFRd failed to load`, event 219 in the System log) and only
  re-enumeration fixes it
* still asking for the card after a reboot: run `%USERPROFILE%\bin\start-gpg-agent.cmd`
  and read what it says, then check `%USERPROFILE%\.gnupg\gpg-agent.log`
* a second GnuPG install can be re-armed by reinstalling it: re-run this script

## Uninstalling

* `git config --global --unset commit.gpgsign` (and `tag.gpgsign`)
* `reg delete HKCU\Software\Microsoft\Windows\CurrentVersion\Run /v GpgAgentYubiSSH`
* delete the `pcsc-shared` line from the `scdaemon.conf` files the script lists

## Licence

MIT, see [LICENSE](LICENSE).
