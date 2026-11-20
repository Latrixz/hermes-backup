# Hermes Backup

A Mac menu-bar app that keeps copies of [Hermes Agent](https://github.com/NousResearch/hermes-agent) (memories, skills, sessions, scheduled jobs, settings and logins) on this Mac, an external disk and cloud folders, and puts it back with one button.

## How it works

- **Backup** runs Hermes' own `hermes backup` (WAL-safe SQLite snapshot, integrity-checked, skips the codebase), adds the desktop app's chat images from `~/Library/Application Support/Hermes`, and locks it all in an AES-256 encrypted disk image. About 8 MB and 10 seconds.
- **Destinations** are plain folders. Cloud = a synced folder (iCloud Drive, Dropbox, Google Drive, OneDrive); the cloud app does the upload. External disks are backed up when plugged in. Copies land in a `Hermes Backups` folder, written under a hidden name and renamed when complete.
- **Schedule**: hourly by default, also on disk mount and on wake. Old copies thin out to: newest 24, daily for 2 weeks, weekly for 2 months, monthly for a year, plus the last 5 "before restore" copies (~60 files per destination).
- **Restore**: unlocks first (a wrong password changes nothing), saves the current Hermes as a "before restore" backup, quits the Hermes desktop app, stops the gateway, refuses if Hermes is still running elsewhere, runs `hermes import --force`, copies back the desktop extras, reopens Hermes.
- **Password** lives in the login Keychain. Without it a backup can't be opened, by design: each one holds API keys and OAuth tokens.
- **Without this app**, a backup still restores: double-click the `.dmg`, type the password, follow `How to restore.txt` inside.

## Build

    ./build.sh --local --install      # this Mac
    SIGN_IDENTITY="Developer ID Application: QUANTUM APES PTE. LTD. (ZT64LKJB82)" NOTARY_PROFILE=quantumape ./build.sh --dmg   # to send

Icon: `swift scripts/make-icon.swift && iconutil -c icns build/AppIcon.iconset -o Resources/AppIcon.icns`

## Testing without touching the live Hermes

    .build/debug/HermesBackup --test-backup <folder> <password>
    .build/debug/HermesBackup --test-unlock <dmg> <password> <outdir>
    HERMES_HOME=<sandbox> hermes import --force <outdir>/hermes-backup.zip

Settings: `~/Library/Application Support/HermesBackup/settings.json`.
