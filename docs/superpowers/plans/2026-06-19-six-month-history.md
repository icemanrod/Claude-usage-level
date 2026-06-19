# Six-Month History with Month Drill-Down — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a 6-month usage history view to the Analytics tab with daily→weekly→monthly granularity and a clickable month drill-down detail screen.

**Architecture:** Add a second, 180-day background scan (`historyStats`) to `UsageManager`, leaving the existing 30-day `monthStats` (and its Models/Projects/sessionCount cards) untouched. Add pure, testable bucketing helpers to `SessionAnalyzer`. Extend the Analytics range picker and branch the row list by granularity, with a month detail subview.

**Tech Stack:** Swift 5.9, SwiftUI, AppKit, Foundation. Build via XcodeGen + the cloud GitHub Actions pipeline (no local Xcode). Pure-logic tests run with the `swift` CLI (Swift 6.3.1 present).

## Global Constraints

- **Display/brand:** app is "Claude Usage Level"; never reintroduce "Claude God" / "ClaudeGod" / "Lcharvol". The Keychain service string `Claude Code-credentials` must stay exactly as-is.
- **Deployment target:** macOS 13.0 → use the single-parameter `.onChange(of:) { newValue in }` form (the two-parameter form is macOS 14+).
- **Code style (CLAUDE.md):** prefer pure functions, `let`/value types, `map`/`reduce`; no force-unwraps (`!`); UI state mutation on the main queue; heavy work on background queues; keep parsing logic in pure static functions.
- **Do NOT change** the 30-day Analytics cards: "30 days" stat card (incl. `sessionCount`), **Models** (`byModel`/`aggregatedModels`), **Projects** (`byProject`), copy-stats. They keep reading `monthStats`.
- **Verification model:** no local Xcode and no XCTest target (out of scope). Pure helpers (Task 1) are verified by a runnable standalone `swift` script. SwiftUI/ObservableObject changes (Tasks 2–4) are verified by the CI Debug build (`.github/workflows/ci.yml`, runs on push to `main`) plus the manual runtime matrix in Task 5.
- **Version bump:** `2.24.0` → `2.25.0` in `project.yml` for BOTH `ClaudeUsageLevel` and `ClaudeUsageLevelWidget` targets, plus `CHANGELOG.md`.

## File Structure

- `Sources/SessionAnalyzer.swift` — add `PeriodBucket` struct, `monthLabelFormatter`/`monthKeyFormatter`, and pure `monthlyBuckets(from:)` / `weeklyBuckets(from:)`. (Task 1)
- `Sources/UsageManager.swift` — add `historyWindowDays`, `@Published var historyStats`, second scan in `refreshStats()`. (Task 2)
- `Sources/MenuBarView.swift` — extend picker; point range cards at `historyStats`; branch row granularity; `selectedMonth` state + `monthDetailView`; generalized bar-scale. (Tasks 3–4)
- `project.yml`, `CHANGELOG.md` — version + changelog. (Task 5)

---

## Task 1: Pure aggregation helpers in SessionAnalyzer

**Files:**
- Modify: `Sources/SessionAnalyzer.swift` (add struct + formatters + two static funcs; near the other structs ~line 165–229 and the formatters block ~line 373–391)
- Test (throwaway, not committed): `/tmp/bucket_test.swift`

**Interfaces:**
- Consumes: existing `DailyUsage { let date: Date; var cost: Double; var messageCount: Int; var tokens: TokenUsage; var dateLabel: String }`; existing `static let dayLabelFormatter` (`"MMM d"`) and `private static let dayKeyFormatter` (`"yyyy-MM-dd"`).
- Produces (used by Tasks 3–4):
  - `struct PeriodBucket: Identifiable { let id: String; let label: String; let cost: Double; let messageCount: Int; let days: [DailyUsage] }`
  - `static func monthlyBuckets(from daily: [DailyUsage]) -> [PeriodBucket]` — calendar-month groups, newest-first, `days` newest-first, `id` = `"yyyy-MM"`, `label` = `"MMM yyyy"`.
  - `static func weeklyBuckets(from daily: [DailyUsage]) -> [PeriodBucket]` — Monday-start week groups, newest-first, `id` = week-start `"yyyy-MM-dd"`, `label` = `"MMM d–MMM d"`.

- [ ] **Step 1: Write the failing test**

Create `/tmp/bucket_test.swift`. It inlines a minimal `DailyUsage` and copies the bucket logic so it can run without the app. (This file is a test harness only — the real implementation goes into `SessionAnalyzer` in Step 3. Keep the logic identical between the two.)

```swift
import Foundation

// --- minimal stand-ins for the app types ---
struct DailyUsage { let date: Date; let cost: Double; let messageCount: Int
    var dateLabel: String { Self.df.string(from: date) }
    static let df: DateFormatter = { let f = DateFormatter(); f.dateFormat = "MMM d"; return f }()
}
struct PeriodBucket: Identifiable { let id: String; let label: String; let cost: Double; let messageCount: Int; let days: [DailyUsage] }

let dayLabelFormatter: DateFormatter = { let f = DateFormatter(); f.dateFormat = "MMM d"; return f }()
let dayKeyFormatter: DateFormatter = { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f }()
let monthLabelFormatter: DateFormatter = { let f = DateFormatter(); f.dateFormat = "MMM yyyy"; return f }()
let monthKeyFormatter: DateFormatter = { let f = DateFormatter(); f.dateFormat = "yyyy-MM"; return f }()

func monthlyBuckets(from daily: [DailyUsage]) -> [PeriodBucket] {
    let cal = Calendar.current
    let groups = Dictionary(grouping: daily) { day in cal.dateComponents([.year, .month], from: day.date) }
    return groups.compactMap { (comps, days) -> PeriodBucket? in
        guard let monthDate = cal.date(from: comps) else { return nil }
        let sorted = days.sorted { $0.date > $1.date }
        return PeriodBucket(
            id: monthKeyFormatter.string(from: monthDate),
            label: monthLabelFormatter.string(from: monthDate),
            cost: sorted.reduce(0) { $0 + $1.cost },
            messageCount: sorted.reduce(0) { $0 + $1.messageCount },
            days: sorted)
    }.sorted { $0.id > $1.id }
}

func weeklyBuckets(from daily: [DailyUsage]) -> [PeriodBucket] {
    var cal = Calendar.current
    cal.firstWeekday = 2 // Monday
    let groups = Dictionary(grouping: daily) { day -> Date in
        cal.dateInterval(of: .weekOfYear, for: day.date)?.start ?? cal.startOfDay(for: day.date)
    }
    return groups.map { (weekStart, days) -> PeriodBucket in
        let sorted = days.sorted { $0.date > $1.date }
        let weekEnd = cal.date(byAdding: .day, value: 6, to: weekStart) ?? weekStart
        return PeriodBucket(
            id: dayKeyFormatter.string(from: weekStart),
            label: "\(dayLabelFormatter.string(from: weekStart))–\(dayLabelFormatter.string(from: weekEnd))",
            cost: sorted.reduce(0) { $0 + $1.cost },
            messageCount: sorted.reduce(0) { $0 + $1.messageCount },
            days: sorted)
    }.sorted { $0.id > $1.id }
}

// --- tests ---
func day(_ iso: String, _ cost: Double, _ msgs: Int) -> DailyUsage {
    let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.timeZone = TimeZone.current
    return DailyUsage(date: f.date(from: iso)!, cost: cost, messageCount: msgs)
}
var failures = 0
func check(_ cond: Bool, _ msg: String) { if !cond { failures += 1; print("FAIL: \(msg)") } else { print("ok: \(msg)") } }

let sample = [
    day("2026-06-19", 3, 10), day("2026-06-18", 5, 20),   // Jun (two days, same week)
    day("2026-05-20", 4, 8),  day("2026-05-01", 2, 4),     // May (two days)
    day("2026-04-15", 6, 12),                               // Apr (one day)
]

let months = monthlyBuckets(from: sample)
check(months.count == 3, "3 month buckets")
check(months.first?.id == "2026-06", "newest month first is 2026-06")
check(months.first?.cost == 8, "June cost = 3+5 = 8")
check(months.first?.messageCount == 30, "June msgs = 30")
check(months.first?.days.first?.dateLabel == "Jun 19", "June days newest-first")
check(months.last?.id == "2026-04", "oldest month last is 2026-04")
let totalMonthCost = months.reduce(0) { $0 + $1.cost }
check(totalMonthCost == 20, "sum of month costs == sum of day costs (20)")

let weeks = weeklyBuckets(from: sample)
check(weeks.count >= 4, "at least 4 week buckets (Jun pair shares one week)")
let jun = weeks.first!
check(jun.cost == 8 && jun.days.count == 2, "newest week groups Jun 18+19")
check(jun.label.contains("–"), "week label has a dash range")
let totalWeekCost = weeks.reduce(0) { $0 + $1.cost }
check(totalWeekCost == 20, "sum of week costs == 20")

print(failures == 0 ? "ALL PASS" : "\(failures) FAILURES")
exit(failures == 0 ? 0 : 1)
```

- [ ] **Step 2: Run the test to verify it fails**

The implementation in `SessionAnalyzer` does not exist yet; first run the harness alone to confirm the *test logic* is wired and currently red against the real code path. Run:

```bash
swift /tmp/bucket_test.swift; echo "exit=$?"
```

Expected: prints `ALL PASS` / `exit=0` for the inlined copy. (This proves the algorithm is correct.) The "failing" state we care about is in the app: confirm the symbols are absent so Task 3 can't yet compile against them:

```bash
grep -n "monthlyBuckets\|weeklyBuckets\|struct PeriodBucket" Sources/SessionAnalyzer.swift || echo "ABSENT (expected red)"
```

Expected: `ABSENT (expected red)`.

- [ ] **Step 3: Add the implementation to SessionAnalyzer**

In `Sources/SessionAnalyzer.swift`, add the `PeriodBucket` struct immediately after the `DailyUsage` struct (after its closing brace, ~line 178):

```swift
struct PeriodBucket: Identifiable {
    let id: String            // "2026-02" (month) or week-start "2026-02-24"
    let label: String         // "Feb 2026" or "Feb 24–Mar 1"
    let cost: Double
    let messageCount: Int
    let days: [DailyUsage]    // member days, newest-first
}
```

Add the two formatters next to the existing `dayKeyFormatter` (after it, ~line 389):

```swift
static let monthLabelFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "MMM yyyy"
    return f
}()

static let monthKeyFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM"
    return f
}()
```

Add the two pure functions as `static` members of `enum/struct SessionAnalyzer` (place them right after the `dayKeyFormatter`/formatters block). Note: inside `SessionAnalyzer` these reference `Self`-scoped formatters directly by name:

```swift
/// Group daily usage into calendar-month buckets, newest-first.
static func monthlyBuckets(from daily: [DailyUsage]) -> [PeriodBucket] {
    let cal = Calendar.current
    let groups = Dictionary(grouping: daily) { day in
        cal.dateComponents([.year, .month], from: day.date)
    }
    return groups.compactMap { (comps, days) -> PeriodBucket? in
        guard let monthDate = cal.date(from: comps) else { return nil }
        let sorted = days.sorted { $0.date > $1.date }
        return PeriodBucket(
            id: monthKeyFormatter.string(from: monthDate),
            label: monthLabelFormatter.string(from: monthDate),
            cost: sorted.reduce(0) { $0 + $1.cost },
            messageCount: sorted.reduce(0) { $0 + $1.messageCount },
            days: sorted
        )
    }
    .sorted { $0.id > $1.id }
}

/// Group daily usage into Monday-start week buckets, newest-first.
static func weeklyBuckets(from daily: [DailyUsage]) -> [PeriodBucket] {
    var cal = Calendar.current
    cal.firstWeekday = 2 // Monday
    let groups = Dictionary(grouping: daily) { day -> Date in
        cal.dateInterval(of: .weekOfYear, for: day.date)?.start ?? cal.startOfDay(for: day.date)
    }
    return groups.map { (weekStart, days) -> PeriodBucket in
        let sorted = days.sorted { $0.date > $1.date }
        let weekEnd = cal.date(byAdding: .day, value: 6, to: weekStart) ?? weekStart
        return PeriodBucket(
            id: dayKeyFormatter.string(from: weekStart),
            label: "\(dayLabelFormatter.string(from: weekStart))–\(dayLabelFormatter.string(from: weekEnd))",
            cost: sorted.reduce(0) { $0 + $1.cost },
            messageCount: sorted.reduce(0) { $0 + $1.messageCount },
            days: sorted
        )
    }
    .sorted { $0.id > $1.id }
}
```

- [ ] **Step 4: Re-run the standalone test to verify the logic passes**

```bash
swift /tmp/bucket_test.swift; echo "exit=$?"
```

Expected: `ALL PASS` and `exit=0`.

- [ ] **Step 5: Commit**

```bash
cd /Users/rod/Desktop/usage-tracker/Claude-usage-level
git add Sources/SessionAnalyzer.swift
git commit -m "feat: add PeriodBucket + monthly/weekly aggregation helpers"
```

---

## Task 2: 180-day historyStats in UsageManager

**Files:**
- Modify: `Sources/UsageManager.swift` (published props ~line 274–276; `refreshStats()` window + scan ~line 929–960; constants ~line 739–740)

**Interfaces:**
- Consumes: `SessionAnalyzer.analyzeWithSessions(since:until:recentLimit:) -> AnalysisResult` (`.stats: UsageStats`).
- Produces (used by Tasks 3–4): `@Published var historyStats: UsageStats` on `UsageManager`, holding up to 180 days of `daily`.

- [ ] **Step 1: Add the published property**

After `@Published var monthStats = UsageStats()` (~line 276) add:

```swift
    @Published var historyStats = UsageStats()  // up to 180 days, for long-range trend + month drill-down
```

- [ ] **Step 2: Add the window constant**

Next to `private static let statsWindowDays = 30` (~line 740) add:

```swift
    private static let historyWindowDays = 180
```

- [ ] **Step 3: Add the 180-day scan in refreshStats()**

In `refreshStats()`'s `DispatchWorkItem`, just after the line
`let monthStart = cal.date(byAdding: .day, value: -Self.statsWindowDays, to: now) ?? now` (~line 931) add:

```swift
            let historyStart = cal.date(byAdding: .day, value: -Self.historyWindowDays, to: now) ?? now
```

After the existing `let today = month.filtered(since: todayStart)` line (~line 937) add the second scan (recentLimit: 0 — the timeline keeps using the 30-day scan's sessions):

```swift
            let history = SessionAnalyzer.analyzeWithSessions(since: historyStart, recentLimit: 0).stats
```

- [ ] **Step 4: Publish it on the main queue**

In the `DispatchQueue.main.async { ... }` block, after `self?.monthStats = month` (~line 942) add:

```swift
                self?.historyStats = history
```

- [ ] **Step 5: Verify compilation via CI**

```bash
cd /Users/rod/Desktop/usage-tracker/Claude-usage-level
git add Sources/UsageManager.swift
git commit -m "feat: add 180-day historyStats scan to UsageManager"
git push origin main
gh run list --repo icemanrod/Claude-usage-level --limit 2
```

Then watch the CI "Build" run to green:

```bash
gh run watch "$(gh run list --repo icemanrod/Claude-usage-level --workflow CI --limit 1 --json databaseId --jq '.[0].databaseId')" --repo icemanrod/Claude-usage-level --exit-status
```

Expected: exit 0 (Debug build compiles). If red, read the log: `gh run view --log-failed --repo icemanrod/Claude-usage-level`.

---

## Task 3: Extend picker, point range cards at historyStats, branch granularity

**Files:**
- Modify: `Sources/MenuBarView.swift` — sparkline card (~1037–1055), Daily card (~1245–1288), `maxDailyCost` (~1466–1468), add computed helpers + `breakdownBar` to `MenuBarView`.

**Interfaces:**
- Consumes: `manager.historyStats.daily`; `SessionAnalyzer.weeklyBuckets(from:)`, `SessionAnalyzer.monthlyBuckets(from:)`, `SessionAnalyzer.PeriodBucket`; existing `@AppStorage(UDKey.dailyRange) dailyRange`, `formatCost`, `Theme`.
- Produces (used by Task 4): `private func breakdownBar(label:cost:sub:maxCost:labelWidth:) -> some View`; computed `displayedDaily`, `displayedWeekly`, `displayedMonthly`, `displayedMax`.

- [ ] **Step 1: Add computed helpers + shared row builder**

Replace the `maxDailyCost` computed property (~1466–1468):

```swift
    private var maxDailyCost: Double {
        manager.monthStats.daily.prefix(dailyRange).map(\.cost).max() ?? 1
    }
```

with:

```swift
    private var displayedDaily: [DailyUsage] {
        Array(manager.historyStats.daily.prefix(dailyRange))
    }
    private var displayedWeekly: [SessionAnalyzer.PeriodBucket] {
        SessionAnalyzer.weeklyBuckets(from: displayedDaily)
    }
    private var displayedMonthly: [SessionAnalyzer.PeriodBucket] {
        SessionAnalyzer.monthlyBuckets(from: displayedDaily)
    }
    private var displayedMax: Double {
        switch dailyRange {
        case 0...30: return displayedDaily.map(\.cost).max() ?? 1
        case 90:     return displayedWeekly.map(\.cost).max() ?? 1
        default:     return displayedMonthly.map(\.cost).max() ?? 1
        }
    }

    @ViewBuilder
    private func breakdownBar(label: String, cost: Double, sub: String, maxCost: Double, labelWidth: CGFloat = 60) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.secondary)
                .frame(width: labelWidth, alignment: .leading)
                .lineLimit(1)

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Theme.muted)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Theme.accent.opacity(0.5))
                        .frame(width: max(0, geo.size.width * CGFloat(maxCost > 0 ? cost / maxCost : 0)))
                }
            }
            .frame(height: 5)

            Text(formatCost(cost))
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .frame(width: 46, alignment: .trailing)
        }
        .help(sub)
    }
```

- [ ] **Step 2: Point the sparkline card at historyStats**

In the sparkline card (~1037–1055), change the guard and the `SparklineView` data source from `monthStats` to `historyStats`:

```swift
                // Sparkline
                if manager.historyStats.daily.count >= 2 {
                    SHCard {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                SHLabel("Usage Trend")
                                Spacer()
                                Text(rangeLabel)
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary)
                            }
                            SparklineView(
                                data: Array(manager.historyStats.daily.prefix(dailyRange).reversed().map(\.cost)),
                                labels: Array(manager.historyStats.daily.prefix(dailyRange).reversed().map(\.dateLabel))
                            )
                            .frame(height: 50)
                        }
                    }
                }
```

Add a `rangeLabel` helper next to the other computed props (from Step 1):

```swift
    private var rangeLabel: String {
        switch dailyRange {
        case 90:  return "90 days"
        case 180: return "6 months"
        default:  return "\(dailyRange) days"
        }
    }
```

- [ ] **Step 3: Extend the picker and branch the Daily card by granularity**

Replace the Daily card body (~1245–1288, from `// Daily with period selector` through its closing `}` before `// Actions`) with:

```swift
                // Daily / weekly / monthly with range selector
                if !manager.historyStats.daily.isEmpty {
                    SHCard {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                SHLabel(dailyRange <= 30 ? "Daily" : dailyRange == 90 ? "Weekly" : "Monthly")
                                Spacer()
                                Picker("Range", selection: $dailyRange) {
                                    Text("7d").tag(7)
                                    Text("14d").tag(14)
                                    Text("30d").tag(30)
                                    Text("90d").tag(90)
                                    Text("6M").tag(180)
                                }
                                .labelsHidden()
                                .pickerStyle(.segmented)
                                .frame(width: 210)
                                .controlSize(.mini)
                            }

                            if dailyRange <= 30 {
                                ForEach(displayedDaily) { day in
                                    breakdownBar(
                                        label: day.dateLabel,
                                        cost: day.cost,
                                        sub: "\(day.dateLabel): \(formatCost(day.cost)) · \(day.messageCount) msgs · \(formatTokens(day.tokens.totalTokens)) tokens",
                                        maxCost: displayedMax
                                    )
                                }
                            } else if dailyRange == 90 {
                                ForEach(displayedWeekly) { bucket in
                                    breakdownBar(
                                        label: bucket.label,
                                        cost: bucket.cost,
                                        sub: "\(bucket.label): \(formatCost(bucket.cost)) · \(bucket.messageCount) msgs",
                                        maxCost: displayedMax,
                                        labelWidth: 88
                                    )
                                }
                            } else {
                                ForEach(displayedMonthly) { bucket in
                                    Button {
                                        selectedMonth = bucket
                                    } label: {
                                        HStack(spacing: 6) {
                                            breakdownBar(
                                                label: bucket.label,
                                                cost: bucket.cost,
                                                sub: "\(bucket.label): \(formatCost(bucket.cost)) · \(bucket.messageCount) msgs — click to break down",
                                                maxCost: displayedMax,
                                                labelWidth: 72
                                            )
                                            Image(systemName: "chevron.right")
                                                .font(.system(size: 9, weight: .semibold))
                                                .foregroundColor(.secondary)
                                        }
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                }
```

> Note: `selectedMonth` is introduced in Task 4. This step references it; if implementing strictly task-by-task, add the `@State private var selectedMonth` line from Task 4 Step 1 now so this compiles.

- [ ] **Step 4: Verify compilation via CI**

```bash
cd /Users/rod/Desktop/usage-tracker/Claude-usage-level
git add Sources/MenuBarView.swift
git commit -m "feat: 6-month range picker with daily/weekly/monthly granularity"
git push origin main
gh run watch "$(gh run list --repo icemanrod/Claude-usage-level --workflow CI --limit 1 --json databaseId --jq '.[0].databaseId')" --repo icemanrod/Claude-usage-level --exit-status
```

Expected: exit 0.

---

## Task 4: Month drill-down detail screen

**Files:**
- Modify: `Sources/MenuBarView.swift` — add `@State selectedMonth` (~near line 26), branch `statsView` (~983–984), add `monthDetailView`, reset on range/tab change.

**Interfaces:**
- Consumes: `SessionAnalyzer.PeriodBucket`, `breakdownBar(...)`, `SparklineView`, `SHCard`, `SHLabel`, `SHStatCard`, `SHButton`, `formatCost`.
- Produces: `@State private var selectedMonth: SessionAnalyzer.PeriodBucket?`.

- [ ] **Step 1: Add navigation state**

Near the other `@State` vars in `MenuBarView` (~line 26), add:

```swift
    @State private var selectedMonth: SessionAnalyzer.PeriodBucket?
```

- [ ] **Step 2: Branch statsView to show the detail screen**

Change the top of `statsView` (~983–985) from:

```swift
    private var statsView: some View {
        VStack(spacing: 10) {
            if manager.monthStats.totalMessages == 0 {
```

to:

```swift
    private var statsView: some View {
        VStack(spacing: 10) {
            if let month = selectedMonth {
                monthDetailView(month)
            } else if manager.monthStats.totalMessages == 0 {
```

(The existing `else`/cards chain stays as-is; this adds the leading `if let` branch.)

- [ ] **Step 3: Add the monthDetailView builder**

Add this method to `MenuBarView` (e.g. right after `statsView`):

```swift
    @ViewBuilder
    private func monthDetailView(_ bucket: SessionAnalyzer.PeriodBucket) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                SHButton(label: "Back", icon: "chevron.left", style: .outline) {
                    selectedMonth = nil
                }
                Spacer()
                Text(bucket.label)
                    .font(.system(size: 13, weight: .semibold))
            }

            HStack(spacing: 6) {
                SHStatCard(label: "Total", value: formatCost(bucket.cost), sub: "\(bucket.messageCount) msgs")
            }

            if bucket.days.count >= 2 {
                SHCard {
                    VStack(alignment: .leading, spacing: 8) {
                        SHLabel("Daily Trend")
                        SparklineView(
                            data: bucket.days.reversed().map(\.cost),
                            labels: bucket.days.reversed().map(\.dateLabel)
                        )
                        .frame(height: 50)
                    }
                }
            }

            SHCard {
                VStack(alignment: .leading, spacing: 6) {
                    SHLabel("Daily")
                    ForEach(bucket.days) { day in
                        breakdownBar(
                            label: day.dateLabel,
                            cost: day.cost,
                            sub: "\(day.dateLabel): \(formatCost(day.cost)) · \(day.messageCount) msgs",
                            maxCost: bucket.days.map(\.cost).max() ?? 1
                        )
                    }
                }
            }
        }
    }
```

- [ ] **Step 4: Reset selection on range change and when leaving the tab**

On `statsView`, attach a reset when the range changes. Add to the end of the `statsView` `VStack` (after its closing content, before the property's closing brace) — macOS 13 single-param form:

```swift
        }
        .onChange(of: dailyRange) { _ in selectedMonth = nil }
    }
```

And on the top-level `body` `VStack` (after `.animation(.easeOut(duration: 0.15), value: manager.selectedTab)` at ~line 98) add:

```swift
        .onChange(of: manager.selectedTab) { _ in selectedMonth = nil }
```

- [ ] **Step 5: Verify compilation via CI**

```bash
cd /Users/rod/Desktop/usage-tracker/Claude-usage-level
git add Sources/MenuBarView.swift
git commit -m "feat: month drill-down detail screen in Analytics"
git push origin main
gh run watch "$(gh run list --repo icemanrod/Claude-usage-level --workflow CI --limit 1 --json databaseId --jq '.[0].databaseId')" --repo icemanrod/Claude-usage-level --exit-status
```

Expected: exit 0.

---

## Task 5: Version bump, changelog, release & deploy

**Files:**
- Modify: `project.yml` (both `MARKETING_VERSION` occurrences), `CHANGELOG.md`.

- [ ] **Step 1: Bump version in project.yml**

Replace both occurrences of `MARKETING_VERSION: "2.24.0"` with `MARKETING_VERSION: "2.25.0"` (one under `ClaudeUsageLevel`, one under `ClaudeUsageLevelWidget`).

- [ ] **Step 2: Add changelog entry**

In `CHANGELOG.md`, directly under `All notable changes to this project will be documented in this file.`, insert:

```markdown

## [2.25.0] - 2026-06-19

### Added
- **6-month history** — the Analytics range selector now goes 7d / 14d / 30d / 90d / **6M**. Long ranges aggregate the breakdown so it stays readable: 90d shows weekly bars, 6M shows monthly bars, while the trend sparkline always plots the full daily curve.
- **Month drill-down** — click any month in the 6M view to open a detail screen with that month's total, a daily-trend sparkline, and a day-by-day breakdown.
```

- [ ] **Step 3: Commit, push, and confirm CI compiles**

```bash
cd /Users/rod/Desktop/usage-tracker/Claude-usage-level
git add project.yml CHANGELOG.md
git commit -m "release: v2.25.0 — 6-month history with month drill-down"
git push origin main
gh run watch "$(gh run list --repo icemanrod/Claude-usage-level --workflow CI --limit 1 --json databaseId --jq '.[0].databaseId')" --repo icemanrod/Claude-usage-level --exit-status
```

Expected: exit 0.

- [ ] **Step 4: Tag and trigger the universal release build**

```bash
cd /Users/rod/Desktop/usage-tracker/Claude-usage-level
git tag v2.25.0
git push origin v2.25.0
gh run watch "$(gh run list --repo icemanrod/Claude-usage-level --workflow 'Build and Release' --limit 1 --json databaseId --jq '.[0].databaseId')" --repo icemanrod/Claude-usage-level --exit-status
```

Expected: exit 0; release `v2.25.0` gains `ClaudeUsageLevel.dmg`.

- [ ] **Step 5: Download, verify arch, install, launch**

```bash
gh release download v2.25.0 --repo icemanrod/Claude-usage-level --pattern 'ClaudeUsageLevel.dmg' --dir /tmp --clobber
hdiutil attach /tmp/ClaudeUsageLevel.dmg -nobrowse -quiet
lipo -archs "/Volumes/Claude Usage Level/Claude Usage Level.app/Contents/MacOS/Claude Usage Level"   # expect: x86_64 arm64
rm -rf "/Applications/Claude Usage Level.app"
cp -R "/Volumes/Claude Usage Level/Claude Usage Level.app" /Applications/
xattr -cr "/Applications/Claude Usage Level.app"
hdiutil detach "/Volumes/Claude Usage Level" -quiet
open "/Applications/Claude Usage Level.app"
```

Expected: `lipo` prints `x86_64 arm64`; the menu-bar "C" icon appears.

- [ ] **Step 6: Manual runtime verification matrix**

Open the popover (⌥⌘C) → **Analytics** tab and confirm:
- Range picker shows **7d / 14d / 30d / 90d / 6M**.
- 7/14/30 show **daily** rows; 90d shows **weekly** rows; 6M shows **monthly** rows.
- Usage Trend sparkline updates for each range; header reads "90 days" / "6 months".
- In 6M, clicking a month opens the **detail screen** (Back, title, total, daily sparkline, day rows); **Back** returns to the months list.
- Switching range or leaving/re-entering the tab clears the detail screen.
- The **"30 days"** stat card, **Models**, and **Projects** cards are unchanged.

---

## Self-Review

**Spec coverage:**
- 180-day window + `historyStats` (additive, monthStats untouched) → Task 2. ✓
- Picker 7/14/30/90/180 + widened frame → Task 3 Step 3. ✓
- Granularity daily/weekly/monthly + sparkline always daily → Task 3. ✓
- `PeriodBucket` + pure `monthlyBuckets`/`weeklyBuckets` (calendar-aligned, newest-first) → Task 1. ✓
- Month drill-down detail screen (back, title, total, sparkline, day rows) → Task 4. ✓
- Bar scaling over displayed rows (`displayedMax`; month detail uses month max) → Task 3 Step 1, Task 4 Step 3. ✓
- Reset selection on range/tab change → Task 4 Step 4. ✓
- 30-day Models/Projects/sessionCount preserved (still read `monthStats`) → unchanged by design. ✓
- Sparse/empty data guards (`historyStats.daily.count >= 2`, `!isEmpty`) → Task 3 Steps 2–3. ✓
- Version bump both targets + changelog → Task 5. ✓

**Placeholder scan:** No TBD/TODO/"handle edge cases"; every code step shows full code. ✓

**Type consistency:** `SessionAnalyzer.PeriodBucket` (with `id/label/cost/messageCount/days`), `monthlyBuckets(from:)`, `weeklyBuckets(from:)`, `historyStats`, `breakdownBar(label:cost:sub:maxCost:labelWidth:)`, `displayedDaily/Weekly/Monthly/Max`, `rangeLabel`, `selectedMonth` are named identically across Tasks 1–4. ✓

**Cross-task ordering note:** Task 3 Step 3 references `selectedMonth` (defined in Task 4 Step 1). The note in Task 3 instructs adding that line early if implementing strictly in order, so each task compiles standalone. ✓
