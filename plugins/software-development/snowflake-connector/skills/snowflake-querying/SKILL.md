---
name: snowflake-querying
license: MIT
description: "Writing and reviewing safe queries against a Snowflake warehouse, where the hazard is cost rather than correctness: bounding every query by time and row count, warehouse sizing and auto-suspend as spend controls, why SELECT * on a wide table is expensive, reading a query profile for pruning and spilling, and the rule that a query whose expected row count you cannot state has not been thought through."
---

# Querying Snowflake

## The hazard is the bill, not the error

A bad query against most systems fails, and the failure teaches you something. A bad query
against Snowflake **succeeds**. It returns correct rows, takes eleven minutes on a large
warehouse, and produces no signal at all until someone reads the invoice. Compute is billed
per second while a warehouse runs, and warehouse size is a multiplier on that rate.

So the discipline here is the same shape as the discipline for reading production logs
during an incident: never issue an unbounded read, and know roughly what is coming back
before you ask for it.

## The rule

**If you cannot state the expected row count before running the query, you have not
thought it through.**

Say the number — "a few hundred", "one row per customer per day for 30 days, so about
90,000" — then run it, then compare. The comparison is where you find out that your join
key was not unique, that the date filter did not apply, or that the table is two orders of
magnitude larger than you assumed. All three are cheaper to learn from a bounded query
than from a slow one.

## Bound every query

Two bounds, doing two different jobs. Both, every time.

```sql
SELECT order_id, customer_id, total_amount, created_at
FROM   <DATABASE>.<SCHEMA>.orders
WHERE  created_at >= DATEADD(day, -7, CURRENT_TIMESTAMP())
  AND  created_at <  CURRENT_TIMESTAMP()
ORDER BY created_at DESC
LIMIT  100;
```

| Bound | What it protects | What it does **not** do |
| --- | --- | --- |
| **A time predicate on the clustering column** (usually a date or timestamp) | The bill. It lets Snowflake skip micro-partitions entirely, so the warehouse reads a fraction of the table. | Nothing else will prune for you — a filter on a non-clustered column still scans. |
| **`LIMIT`** | Your session and your patience: the size of the result set travelling back. | It does **not** cap the scan when the query aggregates, sorts, or joins first. `SELECT COUNT(*) ... LIMIT 10` still aggregates the whole filtered set. |

The common mistake is believing `LIMIT` is the cost control. It is not. The `WHERE` clause
is. A `LIMIT 10` on a query with `ORDER BY` over three years of data sorts three years of
data and then shows you ten rows.

Start narrow and widen deliberately: one day before one month, one customer before all of
them, `LIMIT 100` before the full result. Every widening step should be a decision, not a
default.

## Warehouse sizing and auto-suspend

Warehouse size is the cost multiplier, and the steps are doublings: each size up is
roughly twice the credits per hour of the one below it. A query that takes 60 seconds on
a small warehouse and 30 on a medium one costs **the same**; a query that takes 60 seconds
on both costs twice as much on the medium one. Sizing up only saves money when the work is
genuinely parallel and the time actually halves.

| Setting | Sensible default | Why |
| --- | --- | --- |
| `WAREHOUSE_SIZE` | The smallest that completes the work without spilling | Bigger is only cheaper when it is proportionally faster, which is rarer than people expect |
| `AUTO_SUSPEND` | 60 seconds | Idle warehouses bill. This is the single highest-yield setting in the account. |
| `AUTO_RESUME` | `TRUE` | Otherwise queries fail while the warehouse is suspended, and someone "fixes" it by disabling auto-suspend |
| `STATEMENT_TIMEOUT_IN_SECONDS` | A few hundred for interactive use | A ceiling on what one runaway query can spend |
| Resource monitor | Whatever your finance function can live with | The ceiling on the whole warehouse, per month, with notification and suspend actions |

Two billing details that change how you work:

- **Resuming bills a minimum of 60 seconds**, so ten small queries spread across a suspended
  hour cost more than ten run together. Batch exploratory work into a session rather than
  drip-feeding it.
- **A suspended warehouse loses its local cache.** The first query after a resume re-reads
  from storage and is slower; that is expected, not a problem to solve by keeping the
  warehouse hot.

Sizing a warehouse up because a query is slow is the wrong first move. Find out *why* it is
slow first — see the profile section — because the usual answer is a missing filter, and a
missing filter on a bigger warehouse is just a more expensive missing filter.

## Why `SELECT *` is expensive

Snowflake stores data **by column**. A query reads only the columns it names, so the cost
of a scan is roughly proportional to the width of the selection, not the width of the
table. On a table with 200 columns, selecting 4 of them reads about 2% of the data.

`SELECT *` gives that up entirely. On a wide fact table it can be an order of magnitude
more scanned bytes, more time, and more credits, for columns nobody looked at. It also:

- pulls large `VARIANT` / semi-structured columns you almost certainly did not want, which
  are frequently the biggest columns in the table;
- produces a result set that has to travel back and be rendered;
- breaks silently when a column is added upstream, because every consumer's column
  positions shift.

Name your columns. If you are exploring and do not know them yet, that is what the cheap
metadata path is for:

```sql
DESCRIBE TABLE <DATABASE>.<SCHEMA>.<TABLE>;
SHOW TABLES IN SCHEMA <DATABASE>.<SCHEMA>;
SELECT column_name, data_type
FROM   <DATABASE>.INFORMATION_SCHEMA.COLUMNS
WHERE  table_schema = '<SCHEMA>' AND table_name = '<TABLE>';
```

`SHOW` and `DESCRIBE` read metadata and do not consume warehouse compute. Neither does a
plain whole-table `COUNT(*)` on most tables, which Snowflake can often answer from
micro-partition metadata. Exploration should live in that cheap layer for as long as
possible; drop into the warehouse only when you need actual values.

To see real values cheaply, sample rather than limit:

```sql
SELECT * FROM <DATABASE>.<SCHEMA>.<TABLE> SAMPLE (100 ROWS);
```

## Reading a query profile

When something is slow or expensive, open the query profile in Snowsight rather than
guessing. Four things to look at, in this order:

| What to read | Bad looks like | What it means |
| --- | --- | --- |
| **Partitions scanned vs partitions total** | scanned ≈ total | No pruning happened. Your filter is not on the clustering column, or it is wrapped in a function that defeats pruning (`WHERE DATE(created_at) = ...` rather than a range on `created_at`). This is the highest-value thing on the page. |
| **Bytes spilled to local storage / to remote storage** | Anything, especially remote | The warehouse ran out of memory for a sort, join or aggregation. Remote spilling is dramatically slower than local. Either reduce the data first or size up — this is the one case where sizing up is the right answer. |
| **The most expensive node, by percentage** | One node at 80%+ | Where the time actually goes. Usually a join or an aggregation, rarely the scan people assume. |
| **Rows out vs rows in on a join** | Output much larger than either input | An exploding join — a non-unique key on the side you assumed was unique. This is also the query that quietly returns wrong numbers, so it is a correctness bug as well as a cost one. |

Then, for what things actually cost, the history views:

```sql
-- Recent expensive queries (account-level view; data is delayed, often by 45 minutes or more)
SELECT query_id, user_name, warehouse_name, warehouse_size,
       total_elapsed_time/1000 AS seconds,
       bytes_scanned, rows_produced, query_tag
FROM   SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
WHERE  start_time >= DATEADD(day, -1, CURRENT_TIMESTAMP())
  AND  total_elapsed_time > 60000
ORDER BY total_elapsed_time DESC
LIMIT  50;
```

`SNOWFLAKE.ACCOUNT_USAGE` is account-wide with **latency** — it is not where you check
whether the query you just ran was expensive. For that, use the `INFORMATION_SCHEMA` table
functions (`QUERY_HISTORY`, `WAREHOUSE_METERING_HISTORY`), which are near-real-time over a
shorter retention window. Confusing the two produces the conclusion that a query "did not
run", when it ran two minutes ago and the view has not caught up.

Tag your sessions so cost is attributable later:

```sql
ALTER SESSION SET QUERY_TAG = '<team>/<purpose>';
```

## Expensive shapes, and what to do instead

| Shape | Why it costs | Instead |
| --- | --- | --- |
| `SELECT *` on a wide or `VARIANT`-heavy table | Reads every column | Name the columns you need |
| No time predicate | Full table scan every run | A range predicate on the clustering column |
| A function wrapped around the filter column | Defeats partition pruning | Compare the raw column against a computed bound |
| `ORDER BY` over a large unfiltered set | Sorts everything, often spills | Filter first; sort the filtered set |
| `SELECT DISTINCT` used to paper over a join that duplicates rows | Full sort or hash of the result, and hides the real bug | Fix the join key |
| `COUNT(DISTINCT ...)` on a high-cardinality column, repeatedly | Expensive and exact when you may not need exact | `APPROX_COUNT_DISTINCT` for exploration |
| A correlated subquery per row | Re-executes per row | Rewrite as a join or a window function |
| The same expensive query re-run with a cosmetic change | Defeats the result cache, which needs an exact text match | Materialise the intermediate result once, then query it |
| A cross join from a missing join condition | Row counts multiply | State the expected row count first — this is exactly the mistake the rule catches |

The result cache returns results for free for 24 hours when the query text matches exactly,
the role has the same access, and the underlying data has not changed. Reformatting a query
between runs — adding a comment, changing whitespace — is enough to miss it.

## Before you run it

- [ ] I can state the expected row count
- [ ] There is a time predicate, on a column that prunes
- [ ] There is a `LIMIT`, or the aggregate genuinely returns few rows
- [ ] Columns are named; no `SELECT *` on a wide table
- [ ] I know which warehouse this runs on, and its size
- [ ] Joins have keys I have checked for uniqueness on at least one side
- [ ] This is a read. It does not `INSERT`, `UPDATE`, `DELETE`, `MERGE`, `CREATE` or `DROP`

That last one is not a formality. The right posture for an agent-issued query is a
read-only role, so that a misread instruction produces a permissions error rather than a
changed table. If a write is genuinely intended, it is a deliberate act performed by a
person who said so — see `snowflake-setup` for the role design that makes the distinction
real rather than aspirational.
