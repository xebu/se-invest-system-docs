# Workspace: Sport England review

Everything written about the repo lives here, never in it.

## First action in any session
Before writing anything, check the folder structure below exists and create
whatever is missing (mkdir -p; never overwrite or delete existing files):
docs/sportsengland/InvestEngland/, reviews/, sessions/, .claude/rules/.
Create docs/sportsengland/InvestEngland/00-index.md if absent. Report what you created.

## Layout
- docs/sportsengland/InvestEngland/   00-index, 01-architecture, 02-data-model, 03-apis,
                       04-dependencies, 05-deployment, 06-testing
- reviews/             YYYY-MM-DD-investengland.md (one living file, revised in place)
- sessions/            YYYY-MM-DD-<slug>.md
- Every doc starts with <!-- reviewed at commit abc1234 on YYYY-MM-DD -->

## Rules
- Mark each claim [verified] or [assumed]. Never present inference as fact.
- Record corrections made mid-review, not just conclusions.
- reviews/ files open with a Summary readable on its own.
- Commit this workspace locally as you go (feat/docs/chore prefixes);
  git log is your review history.