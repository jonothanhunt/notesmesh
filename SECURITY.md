# Security and privacy

Notes Mesh reads your notes, so anything that could expose them counts as a security problem,
including:

- note content written anywhere outside the Notes library;
- anything sent over the network;
- changes made to the Notes library;
- locked notes being read.

## Reporting

Please report security or privacy problems privately, through GitHub's
**Security → Report a vulnerability** on this repository, rather than in a public issue.
Include the macOS version and steps to reproduce. Please don't attach real notes; the sample
library (launch with `--sample`) is usually enough to show a problem.

## What Notes Mesh touches

| Location | Access | Why |
|---|---|---|
| `~/Library/Group Containers/group.com.apple.notes/` | Read (needs Full Disk Access) | The Notes database, copied and read |
| `~/Library/Caches/NotesMesh/snapshot/` | Write, then deleted | The temporary copy, removed after each read |
| `~/Library/Application Support/NotesMesh/` | Read/write | Topics, profile types, similarity vectors |
| Notes app (Apple Events) | Ask to show a note | Opening a note you double-click |

There is no networking code.
