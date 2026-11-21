# Privacy

NoteMesh collects no data. It has no accounts, no analytics, no crash reporting and no network code, so nothing about you or your notes leaves your Mac.

## What it reads

With Full Disk Access, NoteMesh reads the Apple Notes database in `~/Library/Group Containers/group.com.apple.notes/`. It copies the database to a temporary folder in `~/Library/Caches/NoteMesh/`, reads the copy and deletes it straight away. It never writes to the Notes library, and it skips locked notes.

## What it stores

NoteMesh keeps what it works out from your notes in `~/Library/Application Support/NoteMesh/`:

- topics and profile types (person, organisation or note) for each note
- similarity vectors, so related notes can be found without re-reading everything
- your settings

File → Delete NoteMesh Data removes all of it. Deleting the app and that folder removes NoteMesh completely.

## Apple Intelligence

When Apple Intelligence is turned on, NoteMesh uses Apple's on-device model to read notes for topics. That runs on your Mac. You can switch to keyword topics at any time in the Apple Intelligence panel.

## Opening notes

When you open a note, NoteMesh asks the Notes app to show it. macOS asks your permission the first time.

## Contact

Report privacy problems privately through the repository's Security tab (see [SECURITY.md](SECURITY.md)).
