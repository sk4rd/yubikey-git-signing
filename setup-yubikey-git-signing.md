# YubiKey commit signing on a fresh Windows install

Two files, no admin rights, safe to re-run:

    setup-yubikey-git-signing.ps1    the work
    setup-yubikey-git-signing.cmd    double-click launcher for it

## Use it

Copy both files to the new machine, plug the YubiKey in, then either double-click
the .cmd, or:

    powershell -ExecutionPolicy Bypass -File setup-yubikey-git-signing.ps1 `
        -GitName "Your Name" -GitEmail you@example.com -Test

Options: `-GitName`, `-GitEmail`, `-SigningKey <fingerprint>` (default: the card's
signature subkey), `-GitRoot <path>` (if Git is somewhere unusual), `-Test` (makes
one throwaway signature and verifies it, asks for your PIN), `-WithSshSupport`
(gpg-agent also acts as an ssh-agent).

## What it does

1. finds git and the GnuPG that ships with Git for Windows, which is the GnuPG git
   will be told to use
2. writes `scdaemon.conf` with `pcsc-shared` for that GnuPG and for every other
   GnuPG installation it finds (Gpg4win, GnuPG for Windows)
3. makes sure the card's public key is in the keyring (fetching it from the URL
   stored on the card, or telling you how to import it), which creates the shadow
   key stubs that let gpg sign with the card
4. sets `gpg.program`, `commit.gpgsign`, `tag.gpgsign` and `user.signingkey` in git
5. installs `%USERPROFILE%\bin\start-gpg-agent.cmd` plus an HKCU Run entry
   (`GpgAgentYubiSSH`) so the agent is up after a reboot, with a repair pass that
   clears wedged daemons and dead socket files when the card is not visible
6. prints a summary; with `-Test`, proves a signature works

## Why step 2 matters

Two GnuPG installations can both use the same YubiKey. By default each one opens a
PC/SC smart card exclusively, so whichever touches it first locks the other one out:
git then hangs on

    Please insert the card with serial number: 25 123 456

even though the YubiKey is plugged in and working. `pcsc-shared` puts them in shared
mode so they take turns. It has to be in place *before* the card is touched, because
a GnuPG without it cannot see a card another GnuPG is holding.

## Troubleshooting

`Looking for the YubiKey` says it is not reachable:

* is the key plugged in? (obvious, but check)
* unplug it and plug it back in. The Windows smart card driver sometimes fails to
  load at boot (`WUDFRd failed to load`, event 219 in the System log) and only
  re-enumeration fixes that
* close things that may hold it: Yubico Authenticator, Kleopatra, another gpg
  command that is stuck
* then re-run the script

Commits hang or ask for the card after a reboot:

* run `%USERPROFILE%\bin\start-gpg-agent.cmd` by hand and read what it prints
* the script already killed stale daemons and sockets; if that did not help, check
  `%USERPROFILE%\.gnupg\gpg-agent.log`

Signed commits work but from a GUI client nothing happens: the pinentry window may
be behind other windows, or a commit is running without a console - the script sets
`pinentry-program /usr/bin/pinentry-w32` (a GUI pinentry) for exactly that case.

## Undo

* git: `git config --global --unset commit.gpgsign` (and `tag.gpgsign`)
* logon entry: `reg delete HKCU\Software\Microsoft\Windows\CurrentVersion\Run /v GpgAgentYubiSSH`
* shared card mode: delete the `pcsc-shared` line from the `scdaemon.conf` files the
  script lists in its output (or the whole file, if it only has that line)
