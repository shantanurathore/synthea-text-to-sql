# synthea-text-to-sql
A healthcare text-to-SQL agent — natural-language questions in, SQL-computed answers out, with proper guardrails and audit logging. Built on dbt, Postgres, and Synthea synthetic patient data.

## Why?

A text-to-sql agent which takes natural language questions as input and produces SQL computed answers. The goal is to provide data and analysis to the users who want to look at the data as per their own needs. The target audience of the agent will be different departments within a healthcare organization. For example, it could be a doctor looking to identify trends in collections over a period of time. Or, it could be someone from finance looking at which procedures are bringing in the most revenue and how they are trending over time. Or, it could be some in revenue and collections, looking for denial trends. Or, it could be the Chief Operating Officer asking which doctors are perfroming well and which doctors need help to bring up their numbers. 

## Current Status: In Progress

As of May 7, 2026.
- dbt scaffolding in place.
- underlying data is generated
- connected to GUI based SQL execution tools for verification and experimentation
- dbt staging models in progress


## The Data
The underlying data is the key here. I wanted a dataset which as close to real life data as possible. The Synthea dataset stood out for two reasons. One, it is really close to the real thing. The database structure is similar to how EMRs actually save data in real life. Two, Synthea allows for scaling the dataset to a desirable size. I was able to build a 10000 patient dataset very quickly. I could have built a much bigger dataset reflecting actual mid size companies but I dont want this project to be of that scale. This project is a reflection of the kind of projects I have worked on in my job.

Plus, there is no HIPAA risk here. Everything is fake data but tries to mirror real life. There are no patients who live up to 200 years. And there is no over abundance of one single kind of patient. 


## Architecture decisions
- **Postgres, not DuckDB** — the project demonstrates concurrency handling, which DuckDB can't do (single-process by design).
- **Synthea, not real or aggregated data** — EHR-shaped, recognizable, no HIPAA risk, byte-reproducible with a seed.
- **dbt for transformations** — industry standard for SQL transformation in 2026; gives tests, docs, and lineage for free.
- **Auth, audit logging, and guardrails from day one** — Doing this at the very end will be time consuming so doing it from the start.
- **Hosted LLM first, local Ollama later** — iterate fast, then measure accuracy delta when swapping for a HIPAA-friendly local deployment.
Full reasoning for these and other choices is in [`docs/decisions-log.md`](docs/decisions-log.md).

Full disclosure. While the core ideas are mine, brainstorming on these aspects has been done at great length along with Claude. It was very helpful in finding gaps in my initial plans as well as thinking through some deeper questions. Claude also helped greately with simplifying the proposed workflow. My intital ideas were wide ranging enough to lose focus from my goal of reflecting what kind of projects I have worked on at my workplace.


## Running it Locally
> Note: this is a personal portfolio project. The setup is documented for reference, not as a polished installer. 
I gathered all the commands I ran intitally on my machine and I have put them together here and in a more detailed commands-reference document. 
 
Prereqs (macOS):
- Homebrew
- PostgreSQL 16 (`brew install postgresql@16`)
- OpenJDK 17 (`brew install openjdk@17`) — required by Synthea
- Python 3.13+
Setup:
 
```bash
git clone git@github.com:shantanurathore/synthea-text-to-sql.git
cd synthea-text-to-sql
 
# Python venv + dependencies
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt   # NOTE: requirements.txt not yet committed; coming next
 
# Start Postgres
brew services start postgresql@16
 
# Create database and user (one-time)
psql -U postgres
# In psql:
#   CREATE DATABASE synthea_warehouse;
#   CREATE USER synthea_app WITH PASSWORD '...';
#   GRANT ALL PRIVILEGES ON DATABASE synthea_warehouse TO synthea_app;
 
# Generate Synthea data
git clone https://github.com/synthetichealth/synthea.git
cd synthea
./gradlew build check test
./run_synthea -s 12345 -p 10000 Texas Houston
cp output/csv/*.csv ../data/
 
# Load into Postgres
cd ..
.venv/bin/python load/load_synthea.py
```
 
Full step-by-step including dbt setup is in [`docs/command-reference.md`](docs/command-reference.md).

## Roadmap
In rough order:
 
1. dbt staging models — one per source table, thin renames + casts ✳️ in progress ( as of May 2026, I am here)
2. dbt marts — `dim_patient`, `dim_provider`, `dim_payer`, `fct_encounter`, `fct_operation`
3. Schema metadata extraction for LLM prompts
4. First version of the SQL agent (FastAPI + Streamlit, hosted LLM)
5. Evaluation — 30–50 test questions, accuracy tracking
6. SQL guardrails — `sqlparse`-based validation, row caps, timeouts
7. Audit logging
8. Local LLM swap — Qwen 2.5 Coder, Llama 3.3 — and accuracy delta measurement
9. Deployment to Hugging Face Spaces
10. Write-up series on [Finding the Method in the Madness](https://findingmethodinthemadness.com/)

## Caveats
- **The architecture targets ~50 concurrent users** as a deliberate design choice — not because there are 50 users, but because the things you have to do for 50 users are a different category of project from a single-user demo.


## License
MIT (license file pending — coming with the next commit).

## About Me!
I'm a manager of BI and analytics in healthcare. This project is partly to teach myself parts of the modern data stack I don't use day-to-day (dbt end-to-end, LLM agent deployment, evaluation harnesses) and partly to build something which reflects what I have been building at work.
Comments and opinions welcome — open an issue or reach me at [LinkedIn](https://www.linkedin.com/in/shantanurathore/).


