# Command Reference

*A runbook of every meaningful command run during this project, organized by phase. Use this if you have to set the project up again from scratch on a new machine.*

---

## 1. Environment setup

### Homebrew packages

```bash
brew install postgresql@16
```
Installs Postgres 16 via Homebrew. Listens on port 5432 by default. Lifecycle managed via `brew services`.

```bash
brew install openjdk@17
```
Installs OpenJDK 17, required by Synthea (which is a Java application). May require additional symlink/`JAVA_HOME` setup; Homebrew prints instructions at the end of install.

```bash
brew services start postgresql@16
```
Starts the Postgres service in the background. Persists across reboots until explicitly stopped. Use `brew services stop postgresql@16` to stop, `brew services restart postgresql@16` to bounce it.

```bash
pg_isready
```
One-line health check — returns "accepting connections" if Postgres is up and listening on the default port. Fast way to confirm the service is actually running.

### Postgres 17 conflict cleanup

```bash
sudo launchctl bootout system /Library/LaunchDaemons/com.edb.launchd.postgresql-17.plist
```
Stops a leftover EDB-installed Postgres 17 that was conflicting with the Homebrew Postgres 16 on port 5432. The EDB install adds a launchd daemon that auto-starts on boot. The `bootout` command unloads it without uninstalling. **Gotcha**: this was the entire reason port 5432 wasn't behaving as expected during the initial setup — `lsof -i :5432` first showed two processes, one Homebrew, one EDB.

The full uninstall, when convenient:

```bash
open /Library/PostgreSQL/17/uninstall-postgresql.app
```

### Database and user creation

```bash
psql -U postgres
```
Connects to Postgres as the superuser. Used once to create the application database and user.

In psql (one-time setup):
```sql
CREATE DATABASE synthea_warehouse;
CREATE USER synthea_app WITH PASSWORD '<random-password>';
GRANT ALL PRIVILEGES ON DATABASE synthea_warehouse TO synthea_app;
\q
```

Password later rotated (see "Secrets handling" below) after a paste-in-chat incident.

### Python virtualenv

```bash
cd ~/projects/synthea-warehouse
python3 -m venv .venv
source .venv/bin/activate
```
Creates a Python 3.13.1 virtualenv at `.venv/` and activates it. The `source` command modifies `PATH` so `python` and `pip` point inside the venv. Prompt changes to show `(.venv)` prefix when active. Deactivate with `deactivate`.

```bash
which python
which pip
```
Sanity check — both should return paths inside `~/projects/synthea-warehouse/.venv/bin/`. If they point at system Python (`/opt/homebrew/bin/python` or `/usr/bin/python`), the venv didn't activate.

```bash
pip install psycopg2-binary python-dotenv
```
Postgres driver and `.env` file loader for the Synthea data loader script.

## 2. Synthea generation and loading

### Clone and build Synthea

```bash
cd ~/projects/synthea-warehouse
git clone https://github.com/synthetichealth/synthea.git
cd synthea
./gradlew build check test
```
Clones the Synthea repo (gitignored at the warehouse-project level), builds the Java application, runs its test suite. Build takes a few minutes the first time.

### Generate patient data

```bash
cd ~/projects/synthea-warehouse/synthea
./run_synthea -s 12345 -p 10000 Texas Houston
```
Generates 10,000 synthetic patients geographically located in Houston, TX, with seed 12345 for reproducibility. Outputs CSV files into `synthea/output/csv/`. Runtime: about 2 min 19 sec on M1 / 64 GB.

The seed matters — every run with `-s 12345 -p 10000 Texas Houston` produces byte-identical output. Without a seed, results vary run to run.

```bash
cp output/csv/*.csv ../data/
```
Moves the generated CSVs into the `data/` folder where the loader script reads from. `data/` is gitignored.

### Load into Postgres

```bash
cd ~/projects/synthea-warehouse
.venv/bin/python load/load_synthea.py
```
Idempotent loader script. Creates the `synthea_raw` schema if not present, drops and recreates each table, bulk-loads the corresponding CSV via `COPY`. Runtime: about 1 min 55 sec for the 10,000-patient dataset.

All columns load as `TEXT` — type casting and column renaming is deferred to the dbt staging layer.

### Verify the load

```bash
psql -U synthea_app -d synthea_warehouse
```
Connect as the app user. Used for spot checks (`SELECT count(*) FROM synthea_raw.patients;` etc.). Then `\q` to exit.

Notable result row counts (10K patient run): 9.5M `claims_transactions`, 6.9M `observations`, 1.6M `procedures`, 11K `patients` (10K alive + 1,077 deceased), 1,136 `providers`. Database size: 7.5 GB.

## 3. dbt installation and scaffold

### Install

```bash
source ~/projects/synthea-warehouse/.venv/bin/activate
pip install dbt-core dbt-postgres
dbt --version
```
Activates the venv (dbt lives in the project's venv, not globally), installs dbt-core 1.11.8 + dbt-postgres 1.10.0. The adapter package pulls dbt-core as a dependency; installing both explicitly is the documented pattern.

`dbt --version` confirms installation and adapter registration.

### Scaffold

```bash
cd ~/projects/synthea-warehouse
dbt init synthea_dbt
```
Interactive scaffold. Prompts for adapter (`postgres`), host (`localhost`), port (`5432`), user (`synthea_app`), pass (typed plaintext, fixed in next step), dbname (`synthea_warehouse`), schema (`synthea`), threads (`4`). Creates `~/projects/synthea-warehouse/synthea_dbt/` with the project skeleton, plus `~/.dbt/profiles.yml` outside the repo.

### Cleanup of init artifacts

```bash
cd ~/projects/synthea-warehouse/synthea_dbt
rm -rf models/example
mkdir -p models/staging models/marts
```
Removes the tutorial models that `dbt init` leaves behind. Creates the actual folder structure we'll use.

## 4. dbt configuration

### Edit `~/.dbt/profiles.yml`

```bash
open -e ~/.dbt/profiles.yml
```
Opens in TextEdit. Two changes from defaults:

1. Replace plaintext `pass:` line with env var lookup using Jinja:
   ```yaml
   password: "{{ env_var('SYNTHEA_DB_PASSWORD') }}"
   ```
2. Change `schema: synthea_marts` to `schema: synthea` so dbt's per-folder `+schema:` suffixes produce clean compound names (`synthea_staging`, `synthea_marts`) instead of `synthea_marts_staging` and `synthea_marts_marts`.

Also delete any leftover blocks from prior projects (an unused `dbt_mysql_project` block was removed during this cleanup — the password in it had been pasted to chat and the underlying RDS instance was already shut down, so just removed).

### Edit `dbt_project.yml`

```bash
cd ~/projects/synthea-warehouse/synthea_dbt
open -e dbt_project.yml
```

Replace the default `models:` block with:

```yaml
models:
  synthea_dbt:
    staging:
      +materialized: view
      +schema: staging
    marts:
      +materialized: table
      +schema: marts
```

Sets folder-level defaults: staging models become views in `synthea_staging` schema, marts become tables in `synthea_marts` schema.

### Set the env var

In `~/.zshrc` (added at the bottom):
```bash
# Synthea project
export SYNTHEA_DB_PASSWORD='<the-rotated-password>'
```

Reload the current shell:
```bash
source ~/.zshrc
echo $SYNTHEA_DB_PASSWORD
```

The `echo` prints the password, confirming the variable is set in the current shell. Without this, dbt can't authenticate. **Gotcha**: changes to `~/.zshrc` only affect new shells unless you `source` it explicitly.

### Rotate the Postgres password

After a paste-in-chat incident, rotated the password:

```bash
psql -U postgres -d synthea_warehouse
```
```sql
ALTER USER synthea_app WITH PASSWORD '<new-random>';
\q
```

Then updated `.env`, `~/.zshrc` `SYNTHEA_DB_PASSWORD` value. Generated new password with `openssl rand -base64 24`.

### Verify dbt connection

```bash
cd ~/projects/synthea-warehouse/synthea_dbt
dbt debug
```
Runs through every config check: profile found, project found, dependencies present, connection works. All green = ready to use.

```bash
dbt parse
```
Parses the project without running anything against the warehouse. Catches YAML errors and reference issues. Benign warning at this stage: "unused configuration paths" for `staging` and `marts` because no `.sql` models exist yet — goes away as soon as the first model is added.

### Declare sources

Created `models/staging/_sources.yml` declaring all 18 tables in the `synthea_raw` schema. Underscore prefix is convention for config files (sorts to top, signals "not a model"). Includes `database`, `schema`, table list with descriptions for the analytical core (patients, encounters, conditions, etc.).

Verify:
```bash
dbt list --resource-type source
```
Lists all 18 sources in the form `source:synthea_dbt.synthea_raw.<table>`. Confirms dbt can read the YAML and resolve every declared table.

## 5. Git and GitHub

### Initial repo setup (already done before this session)

```bash
cd ~/projects/synthea-warehouse
git init
```

### Pre-commit verification

```bash
git status --ignored
```
Lists tracked, untracked, and ignored files. Use this to confirm `.env`, `.venv/`, `data/`, `synthea/`, dbt's `target/` and `logs/` are all in the ignored section before a commit.

```bash
cat .gitignore
```
Quick read of current ignore patterns.

```bash
git check-ignore -v <path>
```
Tells you which line of `.gitignore` is matching a given path. Used to debug "is this file actually being ignored or not." Returns nothing if the path isn't ignored.

### `.gitignore` additions for dbt

Appended to `~/projects/synthea-warehouse/.gitignore`:

```
# dbt
logs/
synthea_dbt/logs/
synthea_dbt/target/
synthea_dbt/dbt_packages/
synthea_dbt/.user.yml
```

`logs/` at the root catches the case where dbt is accidentally run from the wrong directory (which happened once during this session).

### Stage and commit

```bash
cd ~/projects/synthea-warehouse
git add synthea_dbt/ .gitignore
git status
```
Reviews what would be committed. Verify the staged file list contains `dbt_project.yml`, `_sources.yml`, the `.gitkeep` placeholders — and does NOT contain anything from `target/`, `logs/`, or `dbt_packages/`.

```bash
git commit -m "chore: scaffold dbt project with synthea_raw sources

- Initialize dbt project at synthea_dbt/
- Configure profiles.yml to read password from SYNTHEA_DB_PASSWORD env var
- Set up staging (views) and marts (tables) materialization defaults
- Declare 18 synthea_raw source tables
- Add dbt artifacts (logs, target, dbt_packages) to .gitignore"
```
Multi-line message: first line summarizes for `git log --oneline`, body explains the why for future-you.

### Inspect history

```bash
git log --oneline
```
One-line-per-commit summary. Confirms the commit landed.

### GitHub push (pending — do at start of next session)

```bash
# After creating the repo on github.com:
git remote add origin git@github.com:shantanurathore/<repo-name>.git
git branch -M main
git push -u origin main
```
The `-u` sets upstream so future `git push` and `git pull` work without arguments. Replace `<repo-name>` with the chosen name (`synthea-text-to-sql` or similar — TBD).

---

## Useful one-liners (kept here for fast lookup)

### Postgres lifecycle
```bash
brew services start postgresql@16
brew services stop postgresql@16
brew services restart postgresql@16
pg_isready
psql -U synthea_app -d synthea_warehouse
```

### Synthea regeneration (any patient count)
```bash
cd ~/projects/synthea-warehouse/synthea
./run_synthea -s 12345 -p <count> Texas Houston
cp output/csv/*.csv ../data/
cd .. && .venv/bin/python load/load_synthea.py
```

### dbt daily commands
```bash
cd ~/projects/synthea-warehouse/synthea_dbt
source ../.venv/bin/activate

dbt debug          # connection sanity check
dbt parse          # compile and validate without running
dbt run            # execute all models
dbt test           # run all tests
dbt build          # run + test in dependency order (use this day-to-day)
dbt docs generate  # build the docs JSON
dbt docs serve     # serve docs at localhost:8080

# Selective runs:
dbt run --select stg_patients      # one model
dbt run --select +dim_patient      # this model and everything upstream
dbt run --select staging           # one folder
dbt run --select staging+          # folder and everything downstream
```

### Git status quick checks
```bash
git status                  # what's changed
git status --ignored        # also show ignored files
git log --oneline           # commit history, one line each
git check-ignore -v <path>  # why is this path ignored?
```
