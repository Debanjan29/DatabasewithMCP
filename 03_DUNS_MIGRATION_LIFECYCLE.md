# DUNS Migration — Goal & Lifecycle (Context Only)

This file is **not a source of truth for rules** — those live in `01_STRICT_REVIEW_SAFE_EXECUTION_POLICY.md` and `02_DUNS_CLI_INSTRUCTIONS.md`, and this file must never override or duplicate them. Its only purpose is to give the AI a shared understanding of the *overall goal* being worked toward, so individual requests are understood in context rather than treated as isolated one-off tasks.

## The goal, in plain terms

Across the client's database, DUNS-related columns exist in inconsistent shapes — different types, widths, and data quality — spread across many tables. The end state we're working toward, table by table, is: each affected table has a clean, correctly-typed DUNS column under its original name, with the transition handled safely enough that nothing downstream (stored procedures, views, other tables) breaks along the way.

Getting there isn't a single change. It's a sequence of distinct stages, and every table moves through them independently — a table doesn't have to wait for any other table, and reaching one stage never implies permission to move to the next.

## The stages, conceptually

**1. Add the new column.**
Before anything else changes, a new column is added alongside the existing DUNS column, so the old one keeps working exactly as it always has while the new one is introduced.

**2. Migrate the data.**
Values are copied from the old column into the new one, converting and cleaning as needed. This is the stage most likely to hide surprises — not every table's existing data is in the shape it's supposed to be, so this is where real-world messiness (wrong lengths, wrong types, junk values) actually shows up and has to be handled deliberately rather than assumed away.

**3. Review everything that depends on the column.**
Stored procedures, views, and other tables that reference the old column need to be understood before anything is renamed — otherwise the rename becomes the thing that breaks something, silently, somewhere downstream. This stage exists specifically to prevent that.

**4. Cut over.**
Once the data is migrated and everything that depends on it has been reviewed, the old and new columns effectively swap roles — the new column becomes the "real" one, under the original name. This is the moment of highest visibility to anything consuming the table, so it only happens once the earlier stages are genuinely done, not just mostly done.

The rename itself is only the first move. Once the names have swapped, stored procedures that reference the column need to be revisited — anything written against the old name has to be brought in line with the new arrangement. Indexes and constraints tied to the column should also be checked at this point: some of what depended on the old column carries over automatically without needing any action, but that isn't true across the board, so each one is worth confirming individually rather than assumed safe or assumed broken. The rename isn't considered finished until this follow-through is done, not just the moment the names themselves have swapped.

**5. Clean up, eventually.**
The old column sticks around for a while after cutover, as a safety margin. Removing it entirely is a separate decision made later, deliberately — not something that happens automatically just because cutover succeeded.

## Why this matters for how requests should be interpreted

When a user asks for something that touches a DUNS column, it's worth understanding *which stage of this journey* the request belongs to — adding, migrating, reviewing, cutting over, or cleaning up — since each stage carries different risk and different prerequisites. A request to "just rename the column" should be understood against this backdrop: has the data actually been migrated yet? Has dependency review actually happened? The lifecycle here is the context that makes that judgment possible — the actual rules for how each stage must be executed safely still come from the other two files.

## One table's progress says nothing about another's

Because tables move through these stages independently, seeing that one table has already been cut over should never be treated as a reason to assume another table is ready for the same step. Each table's position in this journey is its own.


=====================================================================================================================