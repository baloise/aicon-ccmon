# ccmon data branch

Usage samples, one JSONL file per machine, appended by the ccmon poller and
pushed every 15 minutes. An orphan branch, so these commits never mix with the
code history on `main`, and GitHub Pages serves it directly.

Each line:

```json
{"t":1789458309,"five_hour":24.0,"seven_day":32.0,"scoped":{"Fable":16},"ok":true}
```

`t` is Unix epoch seconds; percentages are 0-100 of each window's quota. Files
are named by a random per-machine id, not a hostname - see `docs/findings.md` on
`main` for why. Do not edit by hand: ccmon appends here and rebases on push.
