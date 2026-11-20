# Staying on the free tier

The factory's first job is to let a product hypothesis be tested without paying for infrastructure. Every entry in the log is a setting or design choice made to stretch a free limit, with the numbers that justify it and whether setup applies it by itself.

**Add an entry whenever a setting is changed for cost or quota reasons.** Say what was set, which limit it protects, the before and after in units someone can check, and why it could or could not be automated. A new entry goes in a file of its ticket's own, `free-tier/<ticket>.md` beside this file, so that two pull requests never edit the same file. It is headed `### #<ticket>. <title>` (`#62a`, `#62b` when one ticket adds several), ends with its one `- **Automated:**` line, and is cited as `entry #62`. The entries numbered in order (`entry 8`) came first: each is in `free-tier/entry-<n>.md` and keeps its number, and no new one is added.

**This file holds only how an entry is written, and the log's sections.** A file in `free-tier/` that starts with a section's heading holds that section; every entry is printed under Log. `factory/scripts/free-tier.sh` prints the whole log; `factory/scripts/check-free-tier.sh` checks its shape in `pnpm lint`.

**A change that adds a recurring cost to a free plan's allowance** (a schedule, a job on every run) names in its entry the event-driven way to do the same thing, and says why that way will not do.

## The limits

## Log

## When to start paying
