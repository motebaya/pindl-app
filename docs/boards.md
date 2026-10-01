# Boards

_Applies to PinDL 3.1.0._

Boards mode downloads a Pinterest account's public boards — whole boards or selected sections.

## Flow

1. Flip the **Feed | Boards** switch to **Boards**.
2. Enter a `@username` and tap **Find boards**. The app lists that account's public boards with pin counts.
3. For each board choose:
   - **Whole** — download every pin on the board,
   - **Sections** — pick specific sections of the board first,
   - **Skip** — leave that board out.
4. Confirm. Boards are processed **one at a time** (sequentially), with aggregated progress shown for the whole run.

## Output

Each board gets its own folder under your username:

```text
Downloads/PinDL/@<username>/Boards/<board-slug>-<board-id>/
├── Images/…
└── Videos/…
```

The short id suffix keeps folders unique when two boards share a name.

## Resume and continue

- Progress is recorded **per board and per media type**. Boards that fully completed in a previous run are skipped on the next run; boards that failed or finished partially are re-run.
- The same completion rules as feed downloads apply: completed items never re-download, failed or cancelled ones are re-offered.

## Limitations

- Only **public** boards are discoverable; private or secret boards never appear.
- Boards mode runs boards sequentially — there is no parallel multi-board download.
