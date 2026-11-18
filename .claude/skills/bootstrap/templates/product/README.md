# Product brain

What we know about users and what we have decided, as plain files so both people and agents can read them.

- `research/`: one file per interview or research note, written by the `intake` skill, or by the `research` skill from public sources and marked synthetic.
- `signals.md`: problems and requests we are watching, each with its evidence. A signal with three independent sources is ready to become an Initiative; evidence marked synthetic does not count towards the three.
- `decisions.md` and `decisions/`: product decisions, including what we chose not to build and what would change our mind. One row each, in the format the header of `decisions.md` gives, in a file per ticket (`decisions/<ticket>.md`); `factory/scripts/decisions.sh product/decisions.md` prints them all.
