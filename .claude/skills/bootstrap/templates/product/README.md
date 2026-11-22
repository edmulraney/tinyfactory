# Product brain

What we know about users and what we have decided, as plain files so both people and agents can read them.

- `research/`: one file per interview or research note, written by the `intake` skill, or by the `research` skill from public sources and marked synthetic.
- `state.md`: where the product stands today, which work is sized to: what is scarce and what the product needs next. How many people use it is counted when an agent needs it, and never written down.
- `journeys/<journey>.md`: one file per journey, such as onboarding: its screens in order, and a row for each state a person can reach each screen in, written `- <screen>, <state>: <what the person sees>, then <where they go next>`. It says what the app does now: a ticket that lists the file under "Docs to update" writes or changes its rows in the same pull request.
- `signals.md`: problems and requests we are watching, each with its evidence. A signal with three independent sources is ready to become an Initiative; evidence marked synthetic does not count towards the three.
- `decisions.md` and `decisions/`: product decisions, including what we chose not to build and what would change our mind. A choice in building code or a test goes in `architecture/decisions.md`. One row each, in the format the header of `decisions.md` gives, in a file per ticket (`decisions/<ticket>.md`); `factory/scripts/decisions.sh product/decisions.md` prints them all.
