# DUNS CLI — Prompt Library (Manual Execution Path)

Use these as starting prompts with the agent, once GEMINI.md / the four project
files are loaded. Replace bracketed placeholders with real values. Each prompt
maps to a stage or checkpoint in the lifecycle — feed the real schema/table name
in, don't run these as generic examples once you're on a real table.

---

## 0. Session start

```
Study the current schema for [database name]. I want to [refresh the cached
copy from the live database / use the existing cached copy as-is].
```

```
Set my standing preference: always [refresh from live / use cached copy]
at session start unless I say otherwise.
```

---

## 1. Impact analysis (Section 3, CLI instructions / Section 7, policy)

```
Run full impact analysis on [schema.table].[column]. I want all eight
Section 7 dependency checks, plus every SP that references this column
directly or via dynamic SQL. Flag anything unresolved for manual review,
don't clear it automatically.
```

```
Before this table is proposed for any change: which stage of the DUNS
lifecycle is it currently in — has a new column already been added,
has data been migrated, has dependency review happened? Tell me what
you can determine from the schema itself vs. what you can't tell without
checking the checkpoint table.
```

```
List every stored procedure across the database that references any
column matching %DUN%, not just ones tied to [table]. I want the full
blast radius before I decide which table to work on next.
```

---

## 2. Stage 1 — Add column (Phase A)

```
Draft the Phase A package to add [new_DUNS] to [schema.table] as
[CHAR(9) NULL]. I'm running this manually — give me the forward script,
the dry run, and the rollback script as separate files, plus a standalone
verification script I can run inside the open transaction before I decide
COMMIT or ROLLBACK.
```

```
Before drafting anything: does duns_cli.migration_checkpoint already
exist in this database? If not, that needs its own approved setup plan
first — draft that instead.
```

---

## 3. Stage 2 — Data migration (Phase A, manual path)

```
Draft the Stage 2 migration script for [schema.table].[old_column] ->
[new_column], converting [numeric(9)] to [char(9) zero-padded]. I'm
executing manually, so do NOT write this as an auto-looping WHILE block —
give me a single batch statement I can re-run by hand, batch size
[10000], with the checkpoint update inside the same transaction as the
data write. Make the predicate idempotent so re-running it never
double-applies.
```

```
Show me the resume logic: if I check duns_cli.migration_checkpoint for
plan [plan-id] / table [table] and find status = 'in_progress' or
'failed', what are my three options and what does each one actually do?
Don't pick one for me.
```

```
Give me the verification script for this batch — all five Section 4a
checks — as its own file, meant to run in the same session as the write
before I commit.
```

---

## 4. Recovery snapshot (Section 4b)

```
Before I execute [plan-id] against [table], give me the snapshot
creation script and check-before-create logic — I want to confirm no
valid snapshot already exists for this plan_id before creating one.
Also tell me plainly: does this edition of SQL Server support native
database snapshots, or do I need a manual backup instead?
```

---

## 5. Dependency review — before AND after migration

```
Re-run the full Section 7 dependency discovery against [schema.table].
[old_column] now that data migration is complete, before I touch
anything related to cutover. I want to see if anything changed since
the original impact analysis — new SPs, new indexes, anything.
```

```
Now run the same Section 7 checks against [new_column] specifically —
I want to know what, if anything, already depends on the new column
before I rename anything.
```

---

## 6. Stage 3 — Review everything that depends on the column

```
Walk me through every SP flagged in impact analysis for [table].
[old_column]. For each one: does it break at cutover, does it need
updating after cutover, or is it unaffected? Don't lump them together —
give me a per-SP verdict.
```

```
Which indexes, constraints, or FKs on [old_column] will carry over
automatically once the column names are swapped, and which ones won't?
I don't want an assumption either way — confirm each one individually.
```

---

## 7. Stage 4 — Cutover (rename / swap)

```
Draft the Phase A package for the cutover on [table]: swapping
[old_column] and [new_column] so [new_column] takes the original name.
Confirm first that Stage 2 migration shows 100% completion in the
checkpoint table and that Stage 3 review is actually finished — don't
let me skip either.
```

```
After the rename script, what's the follow-through checklist — which
SPs reference the old name and need updating, and which indexes/
constraints need individual confirmation rather than being assumed
safe or broken?
```

---

## 8. Stage 5 — Cleanup (later, deliberate)

```
It's been [timeframe] since cutover on [table]. Don't propose dropping
the old column automatically — just tell me what's still referencing it,
if anything, so I can decide separately whether cleanup is safe now.
```

---

## 9. Unexpected scenarios (Section 5, CLI instructions)

```
Immediately before I execute this plan, re-verify the live schema for
[table] still matches what the impact analysis was run against. If
anything drifted, stop and tell me — don't proceed on the old analysis.
```

```
If my session disconnects mid-transaction during this migration, what
should I check to confirm the transaction actually rolled back, and how
should that get logged?
```

---

## 10. Guardrail / trust-boundary check-ins

```
Before we go further — restate what you will and won't do autonomously
on this table, per the strict review policy. I want to confirm you're
not going to execute, commit, or rollback anything without me explicitly
saying so.
```

```
I'm taking this script away to run manually myself. Confirm your
responsibility ends at delivering the approved script and its rollback —
you won't be producing a terminal report or log file for this one, correct?
```

---

## Notes on using these well

- Always name the **real schema.table.column** — don't let a generic
  example slide into being treated as a real plan.
- Ask for dependency review **twice** explicitly: once during initial
  impact analysis, once again right before cutover. The agent won't
  assume the second pass on its own unless prompted.
- If a prompt result ever reads like permission to move to the next
  stage, double check it actually said so — Section 00 manifest is
  explicit that the lifecycle file (03) is context only, not a source
  of approval.
