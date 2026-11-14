# status

Written by .github/workflows/status.yml from the e2e runs on main, every day. Not edited by hand.

`inspect/` holds the latest run's evals as Inspect logs, one per model: `inspect view --log-dir inspect`. `history.md` lists every run on main since 2026-10-20 and the runs before it whose artifacts GitHub still kept, one file each in `history/`; `series.json` is the same runs as numbers, oldest first, for charts.
