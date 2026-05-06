# Project State — Healthcare Text-to-SQL Agent

*Last updated: end of session, May 2026 — dbt scaffold complete, no models written yet.*

---

## 1. Project goal

A natural-language-to-SQL agent for a healthcare data warehouse. A non-technical user (Finance, Operations, clinical leadership) types a question in plain English — "which providers had the highest no-show rate last quarter?" — and gets a real answer back, computed against typed and tested marts, with audit logging, query timeouts, parsed-SQL guardrails, and a measurable accuracy number from an eval harness. The architecture is built to handle ~50 concurrent users from day one because the surrounding system (auth, queueing, row caps, separation of metadata from inference) is what makes a text-to-SQL deployment real rather than a demo. The portfolio version uses Synthea synthetic data on local Postgres; a parallel work version targets the actual SQL Server warehouse and is scoped separately.

## 2. Architecture decisions made so far

- **Warehouse: PostgreSQL 16.13** — real client-server database, supports concurrency and queueing demos. Chosen over DuckDB, which is single-process by design.
- **Dataset: Synthea synthetic patient data** — recognizable as EHR-shaped to anyone in healthcare, free of HIPAA risk. Chosen over CMS public data, which is more aggregate and less clinically rich.
- **Generation seed: 12345, 10,000 patients, Houston TX** — fixed for reproducibility.
- **Transformation layer: dbt** — industry standard for SQL transformation in 2026, gives tests/docs/lineage for free. Chosen over hand-written stored procedures or Python ETL.
- **Staging materialization: views** — staging models are thin (renames + casts only), so views are cheap.
- **Marts materialization: tables** — joins and aggregations get materialized once, queried many times.
- **Schema names: `synthea_staging`, `synthea_marts`, `synthea_raw`** — set base schema in `profiles.yml` to `synthea`, use `+schema:` suffixes in `dbt_project.yml` for clean compound names.
- **LLM: hosted API first, local Ollama (Qwen 2.5 Coder, Llama 3.3) eventually** — iterate fast, then measure accuracy delta when swapping to local for HIPAA-friendly deployment story.
- **UI: FastAPI backend + Streamlit frontend** — Streamlit for the demo UI, FastAPI underneath so the architecture is ready for production-style deployment.
- **Auth, audit logging, and query guardrails: from day one** — bolting these on later is expensive. Even at single-user scale.
- **Secrets handling: env var via `~/.zshrc`, not plaintext in `profiles.yml`** — pattern is `password: "{{ env_var('SYNTHEA_DB_PASSWORD') }}"`.
- **Repo visibility: public from day one** — contribution graph signal matters more than polish; honest "in-progress" README is acceptable.
- **Workflow: manual scaffolding now, Claude Code for bulk work later** — manual through first staging + first mart model, then flip when work becomes repetitive.

## 3. What's built and working

### Hardware and OS
M1 MacBook Pro, 64 GB RAM, 1 TB SSD, macOS 26.3.1.

### Software stack

| Tool | Version | Install method | Location |
|---|---|---|---|
| PostgreSQL | 16.13 | Homebrew (`postgresql@16`) | `/opt/homebrew/var/postgresql@16` |
| Java OpenJDK | 17.0.19 | Homebrew | `/opt/homebrew/opt/openjdk@17` |
| Python | 3.13.1 | system / Homebrew | venv at `~/projects/synthea-warehouse/.venv` |
| Synthea | latest main | git clone + gradle build | `~/projects/synthea-warehouse/synthea/` (gitignored) |
| DBeaver | current | brew cask | GUI app |
| dbt-core | 1.11.8 | pip in venv | inside venv |
| dbt-postgres | 1.10.0 | pip in venv | inside venv |
| psycopg2-binary | current | pip in venv | inside venv |
| python-dotenv | current | pip in venv | inside venv |

A leftover EDB Postgres 17 install at `/Library/PostgreSQL/17/` was conflicting on port 5432; stopped via `launchctl bootout` but not yet uninstalled. Can be removed via `/Library/PostgreSQL/17/uninstall-postgresql.app` when convenient.

### Database

- Database name: `synthea_warehouse`
- App user: `synthea_app`, password stored in `.env` and `~/.zshrc` as `SYNTHEA_DB_PASSWORD` (rotated after a paste-in-chat incident — current value not in conversation history)
- Connection: `postgresql://synthea_app:***@localhost:5432/synthea_warehouse`
- Schemas:
  - `synthea_raw` — raw CSV load, all columns TEXT
  - `synthea_staging` — will hold dbt staging views (empty so far)
  - `synthea_marts` — will hold dbt marts tables (empty so far)

### Data loaded

10,000-patient Synthea run, seed 12345, Houston TX. Total runtime ~4 min 20 sec (2:19 generation, 1:55 Postgres `COPY` load). Database size 7.5 GB.

Row counts in `synthea_raw`:

| Table | Rows |
|---|---|
| claims_transactions | 9,477,364 |
| observations | 6,859,134 |
| procedures | 1,552,738 |
| claims | 998,403 |
| imaging_studies | 965,453 |
| encounters | 573,725 |
| medications | 424,678 |
| payer_transitions | 394,095 |
| conditions | 357,817 |
| supplies | 255,285 |
| immunizations | 169,181 |
| devices | 55,605 |
| careplans | 34,718 |
| allergies | 11,442 |
| patients | 11,077 (10,000 alive + 1,077 deceased) |
| providers | 1,136 |
| organizations | 1,136 |
| payers | 10 |

Sanity checks passed: distinct patient count, date range (1917–2026, full lifespans), provider count scaling correctly with Synthea's fixed-pool geographic model. Quirk filed: `imaging_studies` scaled 2,750× from 100-patient run because of small-denominator subpopulation effects.

### Project structure

```
~/projects/synthea-warehouse/
├── .env                    # gitignored, holds SYNTHEA_DB_PASSWORD
├── .gitignore
├── .venv/                  # gitignored, Python venv
├── config/
│   └── synthea.properties  # Synthea generation settings
├── data/                   # gitignored, regenerable CSVs
├── load/
│   └── load_synthea.py     # idempotent Postgres loader
├── synthea/                # gitignored, source repo
└── synthea_dbt/            # the dbt project
    ├── .gitignore          # dbt-specific (target/, logs/)
    ├── README.md           # default from dbt init, will replace later
    ├── dbt_project.yml     # configured: staging→view, marts→table
    ├── analyses/.gitkeep
    ├── macros/.gitkeep
    ├── models/
    │   ├── staging/
    │   │   └── _sources.yml  # 18 source tables declared
    │   └── marts/            # empty
    ├── seeds/.gitkeep
    ├── snapshots/.gitkeep
    └── tests/.gitkeep
```

dbt profile lives outside the repo at `~/.dbt/profiles.yml`, points to the local Postgres, reads password from `SYNTHEA_DB_PASSWORD` env var.

`dbt debug` passes all green. `dbt parse` succeeds (with a benign "unused configuration paths" warning for `staging` and `marts` because no `.sql` models exist yet). `dbt list --resource-type source` returns all 18 declared sources.

### Git state

Local git repo initialized at `~/projects/synthea-warehouse/`. Most recent commit (or about to be): scaffold dbt project + sources YAML + updated `.gitignore` for dbt artifacts. **Not yet pushed to GitHub.** Decision made to push to public repo at next session opening — naming TBD, candidates `synthea-text-to-sql` or `healthcare-text-to-sql`.

## 4. What's in progress

Nothing actively half-finished as of session end. The project is at a clean checkpoint: dbt scaffolded, sources declared and verified, repo staged and ready to commit + push.

The four documentation files (this one, `command-reference.md`, `concepts-covered.md`, `decisions-log.md`) are the last unit of work in this session.

## 5. What's next

In order:

1. **Commit the dbt scaffold and these four docs.** Single commit (or two — scaffold and docs separately) at the local repo. Don't lose track of which files are part of which logical change.

2. **Create the public GitHub repo and push.** Includes writing a minimal repo-root `README.md` describing the project at its current state ("in progress, dbt scaffold complete, staging models next"). Move the four docs to `synthea-warehouse/docs/` before pushing.

3. **Structured exploration in DBeaver.** ~30–45 min. Five specific checks: patient lifecycle integrity (do deceased patients have post-death encounters?), encounter fan-out (for one encounter, how many condition/procedure/observation/medication/claim/transaction rows?), provider relationships (Synthea has only one provider per encounter — confirm and call out in README vs. real-world multi-provider model at work), code system inventory (distinct counts of SNOMED/RxNorm/LOINC codes), and cost data sanity (avg/min/max/median claim cost, distribution shape).

4. **Write the first staging model: `stg_patients.sql`.** Renames + type casts only. Materialized as a view in `synthea_staging`. Then `dbt run --select stg_patients` to verify it builds against Postgres.

After those, the rest of the staging models (probably 17 more, mostly mechanical) becomes the right moment to flip to Claude Code per the workflow plan.

## 6. Open questions / deferred decisions

These are deliberately unanswered for now:

- **Workplace context questions** — what the existing ChatGPT Enterprise BI Agent at work actually does, whether SSAS cubes are well-annotated for DAX generation, whether Finance VPs self-serve in Power BI today. These get answered when scoping the work version of the project, not the personal one. Personal project doesn't need them.
- **Repo name** — `synthea-text-to-sql` vs `healthcare-text-to-sql` vs something else. Decide before pushing.
- **Naming of `fct_operation`** — Synthea equivalent of work's `fOperation` unified fact table. Whether to call it that, name it differently, or build it at all is undecided until DBeaver exploration informs the marts design.
- **Whether to include a multi-provider semantics model** in the marts to compensate for Synthea's single-provider simplification. Mentioned in Part 1 of the public write-up as "probably." Decide during marts design.
- **Whether to publish Part 1 of the blog write-up now** or wait until the dbt layer is in. Current lean: hold the public publish until the n8n + Claude workflow is also ready, so external signaling happens once and coherently. The GitHub commit is fine to push anytime.
- **Eventual hosted LLM provider** for the v1 agent (Anthropic vs OpenAI vs Bedrock). Defer until eval harness exists — pick whichever scores best.

## 7. Time/scope notes

- **Cadence**: ~8–10 hrs/week (two evenings + one weekend session). Sustainable, not heroic.
- **Hard deadline**: visa timeline makes Jan–Mar 2027 the realistic active-market window. Portfolio needs to be polished and proven by then. Roughly 8 months of runway from now.
- **Soft milestones (informal targets, not commitments)**:
  - End of May: dbt staging + marts complete, first version of agent prototype running locally.
  - End of June: eval harness in place, accuracy baseline measured.
  - End of July: deployed to Hugging Face Spaces / Fly.io, repo polished, blog Part 1 published.
  - August onward: iterate, swap in local LLMs, measure accuracy delta, write Parts 2–N.
- **Boundary**: company schema details and production environment specifics never go into Claude conversations. Personal project uses Synthea exclusively; work version is scoped in private notes.
