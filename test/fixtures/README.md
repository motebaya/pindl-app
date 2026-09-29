# Fixtures

All fixtures are **synthetic** (shapes hand-written to satisfy the parser regex
contracts, cross-checked against the JS reference shapes in
`audits/parity/*.md`). No real user data, no live captures.

## Categories

```text
html/       pin/profile page relay payloads (config strategies, image/video/notfound/stub)
api/        user-pins API JSON envelopes (success/bookmark/empty/bad-status)
hls/        m3u8 playlists (variants + audio, muxed, media playlist)
metadata/   metadata JSON v1 samples (resume stats)
```

## Adding a real capture (opportunistic, PII-safe)

If a real Pinterest response is ever captured while debugging:

1. Strip all personal data (usernames, user ids, image URLs may be kept only if
   synthetic-looking; replace tokens with `fixture-…`).
2. Shrink to the minimal structure that still satisfies the regex contract.
3. Name it `*_captured.html|json` and reference it in a test that documents the
   real-world shape it proves.
4. Never commit raw captures — the JS repo's PII history is the cautionary tale.

The suite must remain offline-deterministic: any test needing live traffic does
not belong here.
