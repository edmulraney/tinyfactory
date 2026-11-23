# The retro of a changed workflow's first run, or of a request for help

In place of steps 2 and 3 of the `retro` skill, follow the section for the run you were given.

## A changed workflow's first run

In the facts, `changed_by` holds the pull request that changed the workflow and its reviewers' assumptions, and `changed_steps` holds each step its diff names in that workflow: its job, its conclusion and the end of its log, or none of them when the run never reached it.

Compare what the pull request in `changed_by` claimed (`gh pr diff`) with what the run did (`changed_steps`). `summary` says whether it did, did not, or never reached the change. Only "did not" has a `change`. One that did has `cause` `one-off`, no `handling` and `retry` `not-applicable`.

## A request for help

In the facts, `ask` holds the comment that asked `@claude` and its link.

The owner asked `@claude` for what the factory did not do by itself. Find what would have made the ask unneeded: the event that should have started the work, the script that should have done it, or what a comment should have told the owner. An ask that cost the owner time and is likely to come again has `cost.kind` `stopped`. A one-off, such as a setup step, has `cause` `one-off` and proposes nothing.
