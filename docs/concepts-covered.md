# Concepts Covered

*A reference document of the actual concepts discussed during this project, organized by topic. Read this when you need a refresher on what something is and why we're using it.*

---

## Synthetic healthcare data — Synthea

Synthea is an open-source synthetic patient generator from MITRE. It produces EHR-shaped CSVs — patients, encounters, conditions, procedures, observations, medications, claims, claim line items, providers, payers — using realistic disease modules and clinical guidelines. The simulation runs lifespans from birth, so a 10K-patient run with seed 12345 produces patients spanning 1917 to 2026, including 1,077 deaths during the simulation. This is great for longitudinal analysis ("average age at first hypertension diagnosis").

Why it matters here: zero HIPAA risk, byte-reproducible with a fixed seed, recognizable to anyone in healthcare as "the right kind of data." It's the standard starting point for healthcare-data-stack portfolio projects.

What to remember about its limitations: Synthea simplifies real-world complexity. Most consequentially for this project, encounters in real EHRs can have multiple provider roles (ordering, rendering, attending) with different business rules; Synthea collapses to a single `provider` per encounter. Geography is finite — Houston has a fixed provider pool of ~1,100, so providers don't scale linearly with patients (a feature, not a bug — closer to real-world data shape). And small subpopulations produce sampling artifacts: `imaging_studies` scaled 2,750× from a 100-patient run to a 10K run because the imaging-prone subpopulation was barely represented at 100. The marts layer should probably include a model that simulates multi-provider semantics so the agent can be tested against more realistic schema complexity.

## PostgreSQL on macOS

Postgres is the warehouse for this project. Installed via Homebrew (`postgresql@16`), runs as a `brew services` background process, listens on port 5432.

The relevant commands: `brew services start postgresql@16` (start), `brew services stop postgresql@16` (stop), `pg_isready` (one-line health check), `psql -U <user> -d <db>` (connect).

Gotcha encountered during setup: a leftover EDB-installed Postgres 17 was sitting on port 5432 from an October 2024 install, conflicting with the Homebrew Postgres 16. The EDB install registers a launchd daemon that auto-starts on boot, so the conflict reappeared every reboot until `launchctl bootout` was used to unload it. **Lesson**: on a Mac that has had Postgres on it before, `lsof -i :5432` is the first thing to run when something behaves weirdly.

Why Postgres specifically (not DuckDB, MySQL, SQLite): the project explicitly demonstrates concurrent-user handling — query queueing, timeouts, row caps, audit logging across sessions. That requires a real client-server database. Postgres is also the closest match to what most healthcare warehouses look like in production (Postgres, SQL Server, Snowflake — SQL Server is most common in the industry).

## Python virtualenv

A virtualenv is an isolated directory containing its own Python interpreter and package set. Activating it modifies `PATH` so `python` and `pip` point inside the venv instead of at system Python.

The flow: `python3 -m venv .venv` creates the venv directory, `source .venv/bin/activate` activates it (prompt gains a `(.venv)` prefix), `deactivate` exits. `which python` is the canonical sanity check — should return a path inside `.venv/bin/`, not `/opt/homebrew/bin/python` or `/usr/bin/python`.

Why it matters here: dbt is a Python package. Different projects use different dbt versions. Without venvs, you'd be stuck with one global dbt across every project on your machine, which breaks the moment one project upgrades. With a venv, the project owns its tooling and can be reproduced cleanly on any machine.

The general principle goes beyond dbt — every Python project should have a venv. The venv directory itself is gitignored; what's tracked is `requirements.txt` (or `pyproject.toml`), so anyone can reproduce the environment. This project's venv is at `~/projects/synthea-warehouse/.venv/`.

## dbt — what it is

dbt (data build tool) is the transformation layer of the modern data stack. It's an open-source Python package (dbt Core) plus database-specific adapters (`dbt-postgres` for this project). You write SQL `SELECT` statements as `.sql` files in a git repo, declare dependencies between them with the `ref()` function, and dbt does the rest: parses the dependency graph, executes models in correct order, materializes results as tables or views in the warehouse, runs tests, generates a documentation site with a lineage graph.

It's a developer tool, not a server — you invoke `dbt run` or `dbt build`, it does its work, and exits. Scheduling is whatever else you have (cron, Airflow, GitHub Actions, dbt Cloud, ADF).

Why it matters here: the project explicitly tries to make the eventual text-to-SQL agent work against clean, tested, documented marts. dbt produces all three for free. It's also the de-facto standard for SQL transformation in 2026 — appears on most healthcare BI manager job descriptions, and the previous public GitHub repo had only a dbt skeleton with placeholder text. Fixing that visible weakness is part of why this project exists.

dbt does not replace ingestion (you still need something to land raw data — for this project that's the Synthea CSV loader script; in production it might be Fivetran, Airbyte, or ADF). It also doesn't replace the BI semantic layer (Power BI, Cube, dbt's own Semantic Layer). It owns the middle: raw landed data → conformed dimensions and facts.

## dbt — sources, refs, and the DAG

The two key building blocks: **sources** are external tables dbt reads from but doesn't manage (declared in YAML), **refs** are how one model points to another (`{{ ref('upstream_model') }}` instead of hardcoded table names).

Sources are declared once in a `_sources.yml` (the underscore prefix is convention for "config, not a model"). The project's source declaration is at `synthea_dbt/models/staging/_sources.yml` and lists all 18 tables in `synthea_raw`. Once declared, models reference them as `{{ source('synthea_raw', 'patients') }}`, which dbt compiles to `"synthea_warehouse"."synthea_raw"."patients"` at runtime.

Refs are how dbt builds its dependency graph (the DAG). When you write a model that says `FROM {{ ref('stg_patients') }}`, dbt scans every model file, finds every ref/source call, and figures out execution order automatically. You never manually sequence anything.

The DAG enables selective execution: `dbt run --select stg_patients` (just one model), `dbt run --select +dim_patient` (this model and everything upstream), `dbt run --select staging+` (a folder and everything downstream). For a project of any real size, this is essential.

## dbt — staging and marts pattern

The conventional two-layer structure: **staging** models do thin transforms (rename columns to snake_case, cast TEXT to typed columns, filter obvious junk), **marts** models do business logic (joins, aggregations, conformed dimensions and facts).

The discipline: one staging model per source table, no joins in staging. If a source schema changes, you fix it in exactly one staging model and everything downstream keeps working. Marts depend on staging models, never directly on sources.

In this project: 18 sources → 18 staging models (`stg_patients`, `stg_encounters`, etc.) → a smaller number of marts (`dim_patient`, `dim_provider`, `dim_payer`, `fct_encounter`, possibly `fct_operation` as a Synthea equivalent of work's unified fact table).

Why this pattern specifically: it's what 90% of dbt projects look like, recruiters expect to see it, and it cleanly separates "data hygiene" from "analytical modeling." Some projects add an intermediate layer (`int_*` models) for complex transformations between staging and marts; not necessary at this project's scale.

## dbt — materializations (view, table, incremental)

Materialization controls how dbt physically stores a model's output. Three main options:

**View** (`+materialized: view`): dbt runs `CREATE VIEW <name> AS <your select>`. Zero storage cost, always fresh, but every query against the view re-runs its underlying SQL. Best for thin transforms — staging models — where the SQL is cheap to re-execute.

**Table** (`+materialized: table`): dbt runs `CREATE TABLE <name> AS <your select>`. Result is physically stored. Costs storage and gets stale until next `dbt run`, but reads are fast. Best for marts where joins and aggregations are expensive to redo on every query.

**Incremental** (`+materialized: incremental`): on first run, builds the full table. On subsequent runs, only inserts/updates rows newer than the last run (you tell dbt how to identify "new"). Critical for billion-row fact tables where rebuilding from scratch every night is impractical. Not needed for this project's scale.

The default in this project: staging → views, marts → tables. Configured in `dbt_project.yml`. Override per-model with `{{ config(materialized='table') }}` at the top of any `.sql` file.

When the convention breaks down: staging-as-view is fine when staging is *thin*. If a staging model needs a window function, deduplication, or expensive logic, materialize as table. Per-query-cost warehouses (BigQuery, Snowflake) are a stronger reason to materialize as tables than per-CPU warehouses (Postgres) — every view query in BigQuery is a billable scan. None of this changes the basic intuition: pick materialization based on how often the model is queried versus how expensive its SQL is.

## dbt — the project skeleton and folder roles

A dbt project is just a folder of SQL and YAML files. The standard layout (what `dbt init` produces, with our edits):

```
synthea_dbt/
├── dbt_project.yml      # project-level config
├── README.md
├── analyses/            # ad-hoc SQL not built as models (rarely used)
├── macros/              # reusable Jinja snippets (later)
├── models/              # the actual transformations
│   ├── staging/
│   │   ├── _sources.yml
│   │   └── stg_*.sql    # one per source table
│   └── marts/
│       ├── dim_*.sql
│       └── fct_*.sql
├── seeds/               # static CSVs loaded as tables (rarely used here)
├── snapshots/           # Type-2 SCD tracking (later, maybe never)
└── tests/               # custom SQL tests beyond what YAML supports
```

`dbt_project.yml` is the project-level config — references the profile name, declares per-folder materialization defaults, lists which directories contain what. Connection credentials live separately in `~/.dbt/profiles.yml` (outside the repo).

Empty folders in git get preserved with `.gitkeep` placeholder files (Git doesn't track empty directories). dbt's runtime artifacts — `target/` (compiled SQL), `logs/`, `dbt_packages/` (third-party packages), `.user.yml` — are gitignored. They're regenerated on every run and shouldn't be in version control.

## Environment variables and secrets handling

An environment variable is a key/value pair in the shell's environment that child processes inherit. When dbt runs, it inherits the shell's env, so `{{ env_var('SYNTHEA_DB_PASSWORD') }}` in `profiles.yml` reads whatever is exported there.

Two scopes: **temporary** (just the current shell — `export VAR=value`) and **persistent** (added to `~/.zshrc` so every new shell loads it). For this project, the password lives in `~/.zshrc` because it's needed every time dbt runs against the local Postgres.

Why not just put the password in `profiles.yml`: that file is on disk, can be backed up by Time Machine, synced by Dropbox, picked up by your shell history, captured in screen-shares. Env vars are slightly less leaky. They're not perfect — anyone with shell access to the same user account can `echo $SYNTHEA_DB_PASSWORD` — but they meaningfully reduce accidental exposure compared to plaintext config.

The harder rule: never put a real password in any file that might end up in git. `~/.dbt/profiles.yml` is outside the repo (lives in `~/.dbt/`, not the project folder), but if you ever copy it into the repo by mistake, the env var pattern means there's no actual secret to leak — just a Jinja expression.

A more sophisticated pattern (not used yet) is `direnv` — a tool that auto-loads project-specific env vars from a `.envrc` file when you `cd` into the directory. Cleaner than `~/.zshrc` for projects with many vars. Not worth the extra moving part for this project's scale.

## The materialization tradeoff at scale

This deserves its own section because it's where new dbt users get confused.

**The intuition that views are slow for big tables is partially right — but the reason isn't what people first assume.** A view in Postgres is just a saved query. When you `SELECT FROM view`, the database substitutes the view's SQL into your query and runs it fresh. So the cost of using a view is the cost of running its underlying SQL.

For a staging view that's a single-table scan with renames and casts (no joins, no aggregations), Postgres pushes any downstream filters through the view to the base table and uses the base table's indexes. The result is fast even on millions of rows. `stg_claims_transactions` over 9.5M rows with `SELECT * FROM stg_claims_transactions WHERE patient_id = 'x'` is essentially as fast as the same query on the base table.

What makes views genuinely slow is when their SQL contains joins, aggregations, or window functions. Then *every query* against the view re-does that work. That's the trap. The convention "staging is views, marts is tables" exists because staging is supposed to be thin and marts contain the joins.

When you'd override staging-as-view: (1) the source is queried so frequently that even cheap renames add up, (2) the source itself is slow to scan (federated tables, S3 externals, cross-database queries), (3) your staging model isn't actually thin (a window-function dedup, for instance), or (4) you're on a per-query-cost warehouse where every view query costs money.

In production with real-volume data, a typical pattern is: sources (raw landed data) → staging views (cheap) → marts tables (joined, materialized once on a schedule) → fact tables that are very large get incremental materialization (only new rows added per run) → hot aggregates queried by dashboards get tables, possibly with explicit indexes via post-hooks.

Knowing which materialization fits which layer is one of the core analytics-engineering skills.

## Claude Code — when to use it, when not

Two ways to work on this project: **manual** (typing every command, editing every file in your editor, running every dbt command yourself) or **with Claude Code** (delegating "create 18 staging models following this pattern" to an agent that writes the code and runs it).

Both work. The choice is about what you're optimizing for at any given moment.

**Stay manual when**: learning a tool you don't know yet, building the first instance of a pattern, debugging a tricky setup, or doing anything where the *muscle memory* of the work matters more than the speed. The first dbt model you write should be hand-typed because that's how you remember `ref()` vs `source()` vs `config()`. The first staging model and first marts model in this project are best done manually for that reason.

**Switch to Claude Code when**: the work is repetitive (write a staging model for each of these 18 source tables, following the same pattern), bulk (rename a column across 30 files), or mechanical (apply a YAML test to every primary key). At that point the manual approach becomes drudgery without learning, and Claude Code is dramatically faster.

The plan for this project: stay manual through the first staging model and first mart model, switch to Claude Code for the remaining staging models and bulk YAML test additions. Don't switch back and forth too often within a session — the context-switching costs more than either approach saves.

A meta-point that matters for the portfolio framing: being deliberate about *when* to use Claude Code versus when to do work yourself is itself a senior-engineering skill in 2026. The blog write-up will mention this. "I use AI coding agents thoughtfully" reads as more credible than "I use AI for everything" or "I avoid AI to prove I'm legitimate." Both extremes look junior.

## Git basics relevant to this project

Three commands form the daily core: `git status` (what's changed), `git add <path>` (stage changes), `git commit -m "..."` (record). Plus `git log --oneline` for history, `git diff` to see staged or unstaged changes, `git restore --staged <path>` to unstage.

`.gitignore` is a list of glob patterns for files git should ignore. Project-level lives in the repo root; global lives at `~/.gitignore` (for OS junk like `.DS_Store`). Lines starting with `#` are comments. The patterns we use:

```
.env              # credentials
.venv/            # Python venv
data/             # generated CSVs, regenerable
synthea/          # cloned source repo
synthea_dbt/logs/
synthea_dbt/target/
synthea_dbt/dbt_packages/
__pycache__/
*.pyc
```

`git status --ignored` shows what's being ignored, useful for sanity-checking that secrets aren't accidentally tracked. `git check-ignore -v <path>` tells you which line of `.gitignore` is matching a given path.

The hardest git rule to internalize: **once a secret is in git history, removing it is annoying** — you have to rewrite history with `git filter-repo` or BFG, force-push, and the secret is still in any clones anyone has made. Easier to never commit it in the first place. Two protective layers: (1) keep secrets in env vars, never in repo files, and (2) `git status` before every commit, scanning for anything sketchy.

Multi-line commit messages are good practice for non-trivial commits. First line is the summary that shows in `git log --oneline`; body explains the why for future-you (or a future recruiter reading commits).

## What's coming up that hasn't been covered yet

Concepts we'll add in future updates of this doc as the project progresses:

- dbt tests (declarative YAML tests, custom SQL tests, the `dbt test` command)
- dbt docs and lineage (`dbt docs generate`, `dbt docs serve`, the docs site at localhost:8080)
- dbt incremental materializations and merge strategies
- Schema metadata as LLM context (how to feed dbt's manifest to a prompt)
- SQL parsing and guardrails (using `sqlparse` to enforce read-only SQL, row caps, timeouts)
- Audit logging design (one row per LLM interaction, what to capture, how it doubles as the eval source)
- Eval harnesses for text-to-SQL (the difference between "right SQL" and "right answer," accuracy vs. exact-match metrics)
- Local LLMs via Ollama (model size vs. latency vs. accuracy tradeoffs on M1 hardware)
- FastAPI and Streamlit basics
- Hugging Face Spaces or Fly.io deployment
