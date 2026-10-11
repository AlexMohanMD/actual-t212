# actual-t212

A lightweight app that syncs your Trading212 spending pot to Actual Budget.

## Architecture

1. **Trading212 Sync (`SyncTrading212` & `SyncWithBalance`)**:
   - Fetches transactions via the Trading212 export API.
   - Normalises transactions (strip/bundle cashback & interest, balance drift detection).
   - Inserts transactions into the database (`transactions` table) with `synced_to_actual: false`.

2. **Actual HTTP API Client (`ActualClient` / `ActualHttpClient`)**:
   - Queries unsynced transactions from the DB (`Transaction.unsynced`).
   - Converts transactions to Actual format (minor currency units / cents, `YYYY-MM-DD` date, payee, notes, idempotency `imported_id`).
   - Imports them via Actual HTTP API (`POST /v1/budgets/{budgetSyncId}/accounts/{accountId}/transactions/import`).
   - Marks imported records in the DB as `synced_to_actual: true`.

## Configuration (Environment Variables)

Copy `.env.example` to `.env` and fill in the values:

```bash
cp .env.example .env
```

### Trading 212

| Variable | Description | Example / Notes |
|---|---|---|
| `TRADING212_API_CLIENT_ID` | Trading 212 personal API token / client ID | *(Required)* |
| `TRADING212_API_CLIENT_SECRET` | Trading 212 personal API secret | *(Required)* |

### Actual Budget / Actual HTTP API

| Variable | Description | Default / Example |
|---|---|---|
| `ACTUAL_API_URL` | Base URL for Actual HTTP API | `https://api.actual.int.alexmmd.com` |
| `ACTUAL_API_KEY` | Secret API key passed in `x-api-key` header | *(Required)* |
| `ACTUAL_BUDGET_SYNC_ID` | Actual Budget Sync ID (from Settings &rarr; Advanced &rarr; Sync ID) | *(Required)* |
| `ACTUAL_ACCOUNT_ID` | Target Account ID in Actual Budget | *(Required unless `ACTUAL_ACCOUNT_NAME` is set)* |
| `ACTUAL_ACCOUNT_NAME` | Alternative: Account name to resolve automatically via API | `Trading 212` |
| `ACTUAL_BUDGET_ENCRYPTION_PASSWORD` | Optional encryption password if budget is encrypted | *(Optional)* |

### Background Scheduling & Dashboard

| Variable | Description | Default / Example |
|---|---|---|
| `SYNC_FREQUENCY` | Recurrence frequency for `SyncAllJob` | `daily` (`hourly`, `weekly`, or `every 6 hours`, `0 0 * * *`) |
| `MISSION_CONTROL_USER` | Optional HTTP Basic Auth username for `/jobs` | *(Optional)* |
| `MISSION_CONTROL_PASSWORD` | Optional HTTP Basic Auth password for `/jobs` | *(Optional)* |

## Dashboard (Mission Control Jobs)

The only web UI in the application is the **Mission Control Jobs** dashboard.
- Navigating to `/` automatically redirects to `/jobs`.
- Inspect job queues, in-progress runs, finished jobs, retries, and recurring schedules (`SyncAllJob`).
- Optional HTTP Basic Authentication can be enabled by setting `MISSION_CONTROL_USER` and `MISSION_CONTROL_PASSWORD`.

## Background Job & Recurring Scheduling

`SyncAllJob` runs the `sync:all` rake task in the background using Active Job with Solid Queue.
- It is scheduled automatically via `config/recurring.yml`.
- The run frequency is controlled by the `SYNC_FREQUENCY` environment variable (default: `daily`).
- When running Puma in single-server / development mode, Solid Queue supervisor runs automatically.

## Usage

### In Ruby Code

```ruby
# Enqueue sync in background:
SyncAllJob.perform_later

# Sync all unsynced transactions from DB to Actual Budget:
ActualClient.call
# or:
ActualClient.new.sync_unsynced_transactions

# Direct client operations:
client = ActualClient.new
client.get_accounts
client.get_transactions(since_date: "2026-10-01")
client.import_transactions([...])
```

### Via Rake Tasks

```bash
# Sync unsynced transactions from DB to Actual Budget
bin/rake actual:sync

# Run Trading212 fetch followed by Actual Budget sync
bin/rake sync:all
```
