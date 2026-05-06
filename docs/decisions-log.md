# Decisions Log

*A log of significant decisions made during this project. The point of this doc is so future-you (or a future Claude session) doesn't re-litigate decisions that have already been made — and so when someone in an interview asks "why did you choose Postgres for this?" you have the answer ready, with the alternatives you considered.*

Each decision is dated by approximate session, not exact timestamp. Decisions are listed roughly chronologically so you can read this top-to-bottom for the project's architectural narrative.

---

## Postgres over DuckDB for the warehouse

**Date**: Project kickoff, late April 2026.

**Alternatives considered**: DuckDB (single-process embedded analytics database), SQLite, MySQL, Snowflake free tier.

**Reasoning**: One of the things this project explicitly demonstrates is concurrent-user handling — query queueing, timeouts, row caps, audit logging across sessions. DuckDB is single-process by design and cannot host a multi-user concurrent workload. SQLite has the same problem. Snowflake free tier would work but adds cloud-account complexity and cost concerns for a personal project. Postgres is the closest match to what most healthcare warehouses actually look like in production (Postgres, SQL Server, Snowflake — SQL Server is most common in the industry). Running it locally on the M1 means free, fast, and offline-capable.

**Reversibility**: Moderate. Switching to a different SQL database would require swapping the dbt adapter (`dbt-postgres` → `dbt-snowflake` or similar), translating any Postgres-specific functions, and re-running the data load. A few hours of work, not days.

---

## Synthea over real CMS data for the dataset

**Date**: Project kickoff, late April 2026.

**Alternatives considered**: CMS public physician performance data, MIMIC-III/IV (requires credentialing), Kaggle healthcare datasets, generating fake data with Faker/Mockaroo.

**Reasoning**: Synthea produces EHR-shaped CSVs — patients, encounters, conditions, procedures, observations, medications, claims, claim line items, providers, payers — using realistic disease modules and clinical guidelines. This is the right shape for the project. CMS public data is more aggregate and less clinically rich; you can't ask "which patients have diabetes and hypertension and were prescribed metformin." MIMIC requires credentialing and a research-use license — overkill for a portfolio project. Kaggle datasets are mostly toy. Faker would have required hand-designing the schema and clinical relationships, defeating the purpose.

Trade-off accepted: Synthea simplifies real-world complexity. Most consequentially, encounters in real EHRs can have multiple provider roles (ordering, rendering, attending) with different business rules; Synthea collapses to a single `provider` per encounter. The README will call this out, and a marts model that simulates multi-provider semantics may be added later.

**Reversibility**: Easy at the data layer (regenerate with different params) but painful at the modeling layer (every staging and mart model is shaped to Synthea's column names). Switching datasets late would mean rewriting staging models. Don't switch.

---

## Generation parameters: seed 12345, 10K patients, Houston TX

**Date**: Project kickoff, late April 2026.

**Alternatives considered**: Larger patient counts (50K, 100K), no fixed seed (different data each run), other geographies.

**Reasoning**: 10K patients produces 9.5M `claims_transactions`, 6.9M `observations`, 1.6M `procedures` — large enough to demonstrate real query performance characteristics, small enough to load in <2 minutes and keep the warehouse at 7.5 GB on disk. Larger runs add load time without changing the architecture being demonstrated. Fixed seed (12345) is critical for reproducibility — the README documents the exact regeneration command, so anyone cloning the repo gets byte-identical data. Houston TX matches the personal context (and Synthea's geographic modeling handles it well — finite provider pool feels realistic).

**Reversibility**: Trivial. Regenerate at any time with different params. Worth doing later as a stress test (regenerate at 100K patients) to validate the materialization tradeoffs at higher scale.

---

## dbt over hand-written SQL/Python for the transformation layer

**Date**: Project kickoff, late April 2026.

**Alternatives considered**: Plain SQL scripts run sequentially, Python ETL with pandas/SQLAlchemy, stored procedures, an ELT-style "everything in one giant view," SQLMesh.

**Reasoning**: dbt is the de-facto industry standard for SQL transformation in 2026 and appears on most healthcare BI manager job descriptions. The project explicitly tries to make the eventual text-to-SQL agent work against clean, tested, documented marts — dbt produces all three for free (declarative tests in YAML, auto-generated docs site with lineage graph, dependency-managed builds). Hand-written SQL scripts would require building dependency management, testing, and documentation infrastructure from scratch. Python ETL is the wrong abstraction (the work is fundamentally SQL, not row-by-row Python). SQLMesh is newer and less battle-tested; mentioning dbt in interviews is a known signal.

A secondary consideration: the previous public GitHub had a dbt skeleton with placeholder text and no real models, which was a credibility gap visible to recruiters. Building an end-to-end dbt project closes that gap.

**Reversibility**: Hard. The whole project structure assumes dbt — switching would mean rewriting all model files, removing dbt config, and rebuilding the dependency-resolution and testing infrastructure manually. Don't switch.

---

## Staging materialization: views; Marts materialization: tables

**Date**: dbt scaffold session, May 2026.

**Alternatives considered**: All views, all tables, incremental for everything.

**Reasoning**: Standard dbt convention because it matches the actual cost characteristics. Staging models are thin (renames + casts only), so views are cheap to read — Postgres pushes filters through the view to the base table and uses base-table indexes. Marts contain joins and aggregations, which would re-execute on every query if materialized as views. Tables let those joins run once during `dbt run` and serve queries fast thereafter. Configured at the folder level in `dbt_project.yml`, overridable per-model with `{{ config(materialized='table') }}` if a specific staging model needs heavier transforms.

**Reversibility**: Trivial. Change a line in `dbt_project.yml` or a per-model config and re-run.

---

## Schema names: `synthea`, `synthea_staging`, `synthea_marts` (clean compound names)

**Date**: dbt scaffold session, May 2026.

**Alternatives considered**: Default dbt-init behavior (`synthea_marts_staging` and `synthea_marts_marts` with the suffix system), single schema for everything (`synthea_dbt`), no suffixes (drop `+schema:` entirely).

**Reasoning**: dbt's `+schema:` config in `dbt_project.yml` *appends* the value to the profile's base schema. With base schema set to `synthea_marts` (the dbt-init default) and `+schema: staging`, the actual schema becomes `synthea_marts_staging` — awkward, hard to read in DBeaver. Changing the base schema in `profiles.yml` to just `synthea` produces clean compound names. Took 30 seconds and avoids seeing ugly names every time we query.

**Reversibility**: Trivial. Change `schema:` in `~/.dbt/profiles.yml` and the suffixes in `dbt_project.yml`. dbt would build new schemas on next run; old ones could be dropped manually.

---

## LLM strategy: hosted API first, local Ollama (Qwen 2.5 Coder, Llama 3.3) eventually

**Date**: Architecture planning, late April 2026.

**Alternatives considered**: Local-only from the start, hosted-only end-to-end, multiple hosted providers (Anthropic, OpenAI, Bedrock).

**Reasoning**: Iteration speed matters early — hosted APIs have no setup cost and the highest accuracy out of the box. Build the eval harness against a hosted model first, get to a measurable accuracy baseline, then swap in local models and measure the accuracy delta. For real healthcare deployment, local-or-private-cloud inference is often required (HIPAA, BAA constraints, data residency), so the local LLM story isn't academic — it's the production-realism part of the portfolio narrative. The specific local models (Qwen 2.5 Coder for SQL, Llama 3.3 for general reasoning) are the current state-of-the-art for the M1 / 64 GB hardware target.

**Reversibility**: Easy. The agent's architecture separates the LLM call from everything else — swapping providers is a config change. The eval harness is what makes the swap measurable.

---

## Build at "scale to 50 concurrent users" architecture from day one

**Date**: Architecture planning, late April 2026.

**Alternatives considered**: Demo-first architecture (single-user, bolt on production concerns later), build only what's needed for the current single user.

**Reasoning**: The interesting parts of this project are exactly the things you'd need for 50 users — real auth, query queueing and timeouts, row caps, parsed-SQL validation, separation of metadata from inference layer, audit logging. Building a single-user demo first means doing all of that work later, and "later" usually means "never" for portfolio projects. The harder version of the architecture is what teaches you something. The demo version doesn't.

It's also the version that's defensible in interviews. Saying "I built this with auth and audit logging from day one because that's how production systems are built" reads better than "I built a demo and was planning to add those things."

**Reversibility**: Easy — strip out auth and queueing if you wanted a simpler demo. But there's no reason to.

---

## Auth, audit logging, and query guardrails from day one

**Date**: Architecture planning, late April 2026.

**Alternatives considered**: Add later when needed, no audit (just live execution), permissive guardrails.

**Reasoning**: All three are expensive to bolt on later. Auth means the user identity is in scope from the start, which affects how every other component is structured. Audit logging means every prompt, generated SQL, error code, and result count goes into a Postgres table — and that table doubles as the source of evaluation data later (every real prompt becomes a candidate test case). Guardrails mean SQL is parsed with `sqlparse` to enforce read-only, validated against an allowlist of objects, and capped at a row limit + 30-second timeout; without these, a typo from a user can crash production or pull a billion-row table. The cost of building these in early is small; the cost of retrofitting is high.

**Reversibility**: Hard once data flows have been built. Easy at the start. Hence "from day one."

---

## Manual scaffolding now, Claude Code for bulk work later

**Date**: dbt scaffold session, May 2026.

**Alternatives considered**: All Claude Code (delegate everything), all manual (avoid AI for legitimacy reasons).

**Reasoning**: Manual work is how you build muscle memory for a tool you don't know yet — every command typed and file edited reinforces what dbt actually does. Claude Code abstracts that learning. So for the first dbt model and first mart, manual is correct. Once the work becomes mechanical (write 17 more staging models following the same pattern, add YAML tests to every primary key), Claude Code is dramatically faster and there's nothing left to learn from typing it out by hand.

A meta-consideration: being deliberate about *when* to use AI agents versus when to do work yourself is itself a senior-engineering skill. The blog write-up will mention this — "I use AI coding agents thoughtfully" reads as more credible than "I use AI for everything" or "I avoid AI to prove I'm legitimate." Both extremes look junior.

**Reversibility**: Trivial — flip back and forth as needed.

---

## Secrets handling: env var via `~/.zshrc`, not plaintext in `profiles.yml`

**Date**: dbt scaffold session, May 2026.

**Alternatives considered**: Plaintext in `profiles.yml` (dbt-init default), `direnv` for project-scoped vars, a secrets manager (1Password CLI, Vault).

**Reasoning**: `profiles.yml` is a real file on disk that backup tools (Time Machine), sync tools (Dropbox/iCloud), and screen-shares can pick up. Even though it lives outside the repo at `~/.dbt/`, putting plaintext credentials in any file invites accidental exposure. Env vars via `~/.zshrc` are slightly less leaky — anyone with shell access can `echo $SYNTHEA_DB_PASSWORD`, but the surface area is smaller than a file backed up by three different tools.

`direnv` would be cleaner for project-scoped vars (auto-loads `.envrc` when you `cd` into the project directory) but adds a tool to install and manage. Not worth it for one variable. A real secrets manager is overkill for a local dev setup.

This decision applies to local dev only — production deployment will use a real secrets manager (AWS Secrets Manager, GCP Secret Manager, or whatever the deployment target uses).

**Reversibility**: Trivial.

---

## Postgres password rotation after paste-in-chat exposure

**Date**: dbt scaffold session, May 2026.

**Alternatives considered**: Leave it (low risk on localhost), full key rotation (overkill).

**Reasoning**: The password got pasted into a Claude conversation. Localhost-only Postgres has near-zero blast radius (the listener is bound to localhost, not exposed externally), but the discipline of rotating any exposed credential is a good habit. Generated a new password with `openssl rand -base64 24`, updated via `ALTER USER`, updated `.env` and `~/.zshrc`. Total cost: 5 minutes.

A separate (now-stopped) MySQL RDS instance also had its password exposed in the same paste — the instance was already shut down so the risk was zero, but the dead `dbt_mysql_project` block was removed from `~/.dbt/profiles.yml` to clean up.

**Reversibility**: Trivial.

---

## Public GitHub repo from day one (vs. private until polished)

**Date**: dbt scaffold session, May 2026.

**Alternatives considered**: Private until "ready" (some indeterminate future polish point), public from day one with honest in-progress framing.

**Reasoning**: Private repos don't show on the GitHub contribution graph in a way that's visible to recruiters. They count for streak purposes but aren't visible to anyone visiting your profile. The "1.5-year credibility gap" flagged in the career research report is partially closed by *commit history showing motion*, not just final code. Showing 8 weeks of consistent commits leading up to a polished v1 looks dramatically different from a single "drop everything" commit.

Public commitment also changes how you work — README gets written more carefully, commit messages get tighter, half-broken stuff doesn't get left lying around. Useful pressure.

The only real argument for private was "I don't want it judged before it's polished." That's addressable with an honest README: "Building in public, current state: dbt scaffold, staging models in progress." Recruiters who care about authentic engineering work respect that more than a polished-but-stale repo.

**Reversibility**: Trivial — flip a setting on github.com.

---

## Documentation strategy: four separate files, regenerated on demand

**Date**: dbt scaffold session, May 2026.

**Alternatives considered**: One mega-doc, no docs (just rely on conversation history), README-only.

**Reasoning**: The four docs serve different purposes and get consulted at different times — `project-state.md` for "where am I?", `command-reference.md` for "what was that command?", `concepts-covered.md` for "wait, what's a materialization again?", `decisions-log.md` for "why did I pick X?". A single mega-doc would bury each. The conversation history isn't reliable across sessions — it gets dropped, summarized, or out of context.

Regenerating the docs on demand (rather than incrementally maintaining them) is more robust — every session ends with a fresh snapshot, and `git diff` between versions is its own form of progress tracking.

**Reversibility**: Trivial. The prompt is reusable; regenerate at natural milestones (every 2–3 sessions, after major phases).

---

## Boundary: company schema details and production environment specifics never go into Claude

**Date**: Throughout, ongoing.

**Alternatives considered**: Share work-context for richer Claude responses, share generic redacted context.

**Reasoning**: There's a deliberate split between the personal/portfolio version of the project (Synthea, public, in Claude conversations) and the work version (real EMR data, internal, scoped privately). The strategic context for *both* is shared — the career research report, the four-week plan, the manager-conversation playbook are all in the project files. But the schema names, table names, business rules, performance characteristics of the actual work warehouse stay out of Claude. Same data shape, different specifics.

This protects the employer (no leak of internal architecture), protects the project (the public artifact stays free of any "wait, this is suspiciously close to my actual job" smell), and keeps the boundary clear.

**Reversibility**: N/A — this is a discipline, not a technical choice.

---

## Decisions deferred (still open)

These haven't been decided yet and are noted in `project-state.md` under "Open questions":

- **Repo name**: `synthea-text-to-sql` vs `healthcare-text-to-sql` vs alternatives.
- **Whether to build a `fct_operation` mart** as a Synthea equivalent of work's unified fact table.
- **Whether to include a multi-provider semantics model** in marts to compensate for Synthea's single-provider simplification.
- **When to publish Part 1 of the blog write-up** publicly (current lean: hold until n8n + Claude artifact is also ready).
- **Eventual hosted LLM provider** for v1 of the agent (defer until eval harness exists, pick whichever scores best).

These are tracked here so they don't get lost — but no decision is needed yet.
