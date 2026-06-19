# Six-Month History with Month Drill-Down — Design

**Date:** 2026-06-19
**Status:** Approved (pending spec review)

## Goal

Let the user view usage/cost history further back than the current 30-day ceiling — up to **6 months** — in the Analytics tab. For long ranges, show an aggregated (weekly/monthly) breakdown so the list stays readable, and let the user **click a month to drill into a detail screen** showing that month's daily breakdown.

## Background (current behavior)

- A single constant, `UsageManager.statsWindowDays = 30`, caps the entire stats scan.
- `UsageManager.refreshStats()` (background, deferred to popover-open) calls
  `SessionAnalyzer.analyzeWithSessions(since: monthStart)` where
  `monthStart = now - statsWindowDays`. The result populates `@Published var monthStats`.
- `weekStats` and `todayStats` are **derived** from `monthStats` via `UsageStats.filtered(since:)`
  (no extra scan).
- The Analytics tab renders two range-aware cards driven by `@AppStorage(UDKey.dailyRange)`
  (default 7), via a segmented picker with tags **7d / 14d / 30d** (`MenuBarView.swift:1252`):
  - **Usage Trend** sparkline (`~1048`): plots `monthStats.daily.prefix(dailyRange)` costs.
  - **Daily** list (`~1262`): one row per day (`label + bar`) for `monthStats.daily.prefix(dailyRange)`.
- `monthStats` also feeds **30-day** cards that the new feature must NOT change: the "30 days"
  stat card (totals + `sessionCount`), the **Models** card (`byModel` / `aggregatedModels`), the
  **Projects** breakdown (`byProject`), and copy-stats. `UsageStats.filtered(since:)` rebuilds
  totals/daily for a sub-window but **zeroes** `sessionCount`/`byModel`/`byProject` (daily rows
  carry no per-model/per-project detail).

## Data model (existing, reused)

- `DailyUsage { id, date, tokens, cost, messageCount, dateLabel }` — `daily` is newest-first.
- `UsageStats { totalCost, totalTokens, totalMessages, sessionCount, byModel, daily, byProject, … }`
  with `filtered(since:) -> UsageStats` and `aggregatedModels`.

## Design

### 1. Data layer — add a 180-day history dataset (additive, behavior-preserving)

- Add `static let historyWindowDays = 180` to `UsageManager`. Keep `statsWindowDays = 30` exactly
  as-is.
- In `refreshStats()`, keep the existing 30-day `analyzeWithSessions` call that produces
  `monthStats` (and `recentSessions`) **unchanged** — so every 30-day card / Models / Projects /
  `sessionCount` / copy-stats keeps its exact current meaning.
- Add a **second** scan for the long-range data:
  `let history = SessionAnalyzer.analyzeWithSessions(since: now - historyWindowDays, recentLimit: 0)`
  and publish `@Published var historyStats = UsageStats()` ← `history.stats` on the main queue,
  inside the same `DispatchWorkItem` (background, cancellable, deferred).
  - `recentLimit: 0` keeps the timeline/session collection coming from the existing 30-day scan;
    the history scan only needs aggregate `daily`/totals.
- **Cost:** the 30-day files are read by both scans (~16% overhead vs. an ideal single pass).
  Acceptable: background thread, deferred to popover-open, files already skipped early by date.
  A future optimization (out of scope) is dual-accumulating both windows in one file traversal.

### 2. Range picker — extend to 6 months

- Segmented picker tags become **7d / 14d / 30d / 90d / 6M**, stored in `dailyRange` as day counts
  **7 / 14 / 30 / 90 / 180** (no migration needed — existing stored values 7/14/30 still valid).
- Widen the picker frame (currently `width: 120`) so 5 segments fit (≈ 200–210pt, `.mini`).
- Default `dailyRange` stays **7**.

### 3. Granularity by range

The **Usage Trend sparkline always plots daily points** for the selected range, now reading from
`historyStats.daily.prefix(dailyRange)` (so it can show up to 180 daily points). The **row list**
branches on range:

| Range (days) | Row list granularity | Source |
|---|---|---|
| 7 / 14 / 30 | Daily rows (unchanged) | `historyStats.daily.prefix(range)` |
| 90 | Weekly bars (~13 rows) | `SessionAnalyzer.weeklyBuckets(from:)` |
| 180 | Monthly bars (6 rows), clickable | `SessionAnalyzer.monthlyBuckets(from:)` |

Both range-aware cards (sparkline + list) switch their data source from `monthStats` to
`historyStats`. The 30-day stat/Models/Projects cards keep reading `monthStats`.

### 4. Aggregation — new pure, testable helpers

Add to `SessionAnalyzer` (pure `static`, no side effects — testable per CLAUDE.md):

```swift
struct PeriodBucket: Identifiable {
    let id: String            // stable key, e.g. "2026-02" or "2026-W08"
    let label: String         // "Feb 2026"  /  "Feb 24–Mar 1"
    let cost: Double
    let messageCount: Int
    let days: [DailyUsage]    // member days, newest-first (for drill-down / scaling)
}

static func monthlyBuckets(from daily: [DailyUsage]) -> [PeriodBucket]  // calendar months, newest-first
static func weeklyBuckets(from daily: [DailyUsage]) -> [PeriodBucket]   // calendar weeks (Mon start), newest-first
```

- Buckets are **calendar-aligned** (months by year-month; weeks Mon-start) for natural labels.
- Newest-first ordering matches the existing daily list.
- A bucket's `cost`/`messageCount` are the sums over its member `days`; `days` retained for the
  month-detail screen and bar scaling.

### 5. Month drill-down — detail screen

- Add `@State private var selectedMonth: PeriodBucket?` to the view that owns the Analytics body
  (the one holding `@AppStorage dailyRange`).
- In the 6M monthly list, each month row is a `Button` that sets `selectedMonth = bucket`.
- When `selectedMonth != nil`, the Analytics content shows a **`monthDetailView(bucket:)`** instead
  of the range cards:
  - Back arrow (clears `selectedMonth`) + title (`bucket.label`).
  - Total `cost · messages` for the month.
  - A sparkline of the month's daily costs (`bucket.days.reversed().map(\.cost)`).
  - Scrollable daily rows (`bucket.days`), same `label + bar` style as the existing Daily list,
    with bar scaling against `bucket.days.map(\.cost).max()`.
- Weekly (90d) rows are **not** clickable (scope: month drill-down only).
- `selectedMonth` resets to `nil` when leaving/re-entering the Analytics tab and on range change,
  so stale month detail never shows.

### 6. Bar scaling

Bar width currently scales against `maxDailyCost` (max over `monthStats.daily.prefix(dailyRange)`).
Generalize to the **max over the currently displayed rows**:
- daily ranges → max over displayed daily costs (from `historyStats`),
- weekly/monthly → max over displayed bucket costs,
- month detail → max over that month's daily costs.

## Components & isolation

- **`SessionAnalyzer`** (pure): `PeriodBucket`, `monthlyBuckets(from:)`, `weeklyBuckets(from:)`.
  Inputs `[DailyUsage]` → outputs `[PeriodBucket]`. No I/O. Unit-testable in isolation.
- **`UsageManager`**: `historyWindowDays`, `@Published historyStats`, second scan in `refreshStats()`.
  Existing `monthStats`/`weekStats`/`todayStats` untouched.
- **`MenuBarView`** (Analytics body): extend picker; branch row rendering by granularity;
  `selectedMonth` state + `monthDetailView` builder; generalized bar-scale helper.

## Edge cases

- **Sparse data (current reality):** only ~30 days exist locally today, so 6M shows the 1–2 month
  buckets that have data; earlier months simply aren't rendered (no empty rows). Sparkline is shorter.
- **Empty history:** if `historyStats.daily` is empty, the range cards hide exactly as today
  (existing `count >= 2` / `!isEmpty` guards reused).
- **Bar scaling div-by-zero:** guard `max > 0` (existing pattern).
- **Calendar boundaries:** buckets keyed/labelled via `Calendar.current`; partial current
  month/week labelled normally (e.g. "Jun 2026").
- **Performance:** one extra 180-day scan, background + deferred; bucketing is O(days).

## Out of scope

- Analytics **Models/Projects** breakdowns stay on the 30-day window (`monthStats`) — not changed.
- No new test target added (helpers kept pure so a target can be added later).
- Single-pass dual-window accumulation (future perf optimization).
- Drill-down on weekly (90d) rows.

## Testing / verification

- Pure bucket helpers verified by reasoning + (if a target is later added) unit tests:
  correct grouping, newest-first order, sums equal to member-day sums, label formatting.
- Manual: build via cloud pipeline (universal), install, open Analytics → cycle 7d/14d/30d/90d/6M,
  confirm daily→weekly→monthly switch, click a month → detail screen → back; confirm 30-day/Models/
  Projects cards unchanged.
