# Claude Branch — Conversation Branching for Claude Code

## Overview

A Claude Code plugin that adds git-style branching/merging to conversations. Fork a conversation to explore alternative approaches, revert to checkpoints, merge the best results. Three modes: on-demand branching, auto-snapshot on error correction, and multi-agent exploration.

## Architecture

### Plugin Type
Hooks-based + Skills (slash commands). Node.js runtime (standard for Claude Code plugins). SQLite for metadata storage.

### Storage Model
All data stored in `~/.claude-branch/` — never modifies Claude Code's JSONL session files. Branches are stored as patches (divergent messages) indexed in a local SQLite database.

```
~/.claude-branch/
├── claude-branch.db        # SQLite: branches, snapshots, tree structure
├── patches/                # Divergent messages per branch
│   ├── <session-id>/
│   │   ├── main.jsonl      # Copy from fork point → end
│   │   ├── try-redux.jsonl
│   │   └── explore-1.jsonl
└── settings.json           # Config (auto-snapshot on/off, explore parallelism, etc.)
```

### SQLite Schema

```sql
CREATE TABLE branches (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    session_id TEXT NOT NULL,
    name TEXT NOT NULL,
    parent_branch TEXT,
    fork_message_index INTEGER NOT NULL,
    created_at INTEGER NOT NULL,
    is_active BOOLEAN DEFAULT 0,
    UNIQUE(session_id, name)
);

CREATE TABLE snapshots (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    session_id TEXT NOT NULL,
    branch_id INTEGER NOT NULL,
    message_index INTEGER NOT NULL,
    label TEXT,
    created_at INTEGER NOT NULL,
    FOREIGN KEY(branch_id) REFERENCES branches(id) ON DELETE CASCADE
);
```

## Slash Commands (Skills)

| Command | Description |
|---------|-------------|
| `/branch <name>` | Fork the conversation at the current message |
| `/branches` | List all branches with visual tree |
| `/checkout <name>` | Switch to a branch (restore context) |
| `/merge <name>` | Merge a branch into the current one |
| `/snapshot` | Manual save of current point (named automatically) |
| `/explore <prompt>` | Launch 2-3 subagents with different approaches in parallel |
| `/diff <branch>` | Compare current branch with another (divergent messages) |
| `/delete-branch <name>` | Delete a branch and its patches |

## Hooks

### PostToolUse
Detects user corrections ("no not that", "go back", "instead do...") and auto-creates a snapshot before the correction. Pattern matching on user messages following assistant tool use.

### SessionStart
Loads branch state for the current session. If a branch was active, injects context summary.

### SessionEnd
Saves the final state of the active branch. Appends new messages to the branch patch file.

## Core Flows

### 1. Branch on Demand
```
User works on main
→ /branch try-hooks
→ Plugin copies messages from fork point into patches/session/try-hooks.jsonl
→ Creates DB entry (session_id, name="try-hooks", parent="main", fork_index=current)
→ User continues, new messages appended to try-hooks.jsonl
→ /checkout main → plugin injects main context summary
→ /merge try-hooks → plugin presents diff, applies file changes
```

### 2. Branch on Error (Auto-Snapshot)
```
Claude makes a tool call
→ User says "no, that's wrong, instead..."
→ PostToolUse hook detects correction pattern
→ Auto-creates snapshot at message before the correction
→ User can later: /checkout snapshot-42 to try a different approach
```

### 3. Branch for Exploration
```
/explore "implement authentication"
→ Plugin creates 3 branches: explore-auth-1, explore-auth-2, explore-auth-3
→ Launches 3 subagents in parallel with different approach prompts
→ Each subagent works in its own branch
→ Plugin presents comparative summary when all complete
→ User picks the best: /merge explore-auth-2
```

## Checkout: Context Restoration

Checkout cannot "rewind" Claude Code's conversation. The plugin:

1. Summarizes the target branch messages (key facts, decisions, files modified)
2. Injects this summary as context via the SessionStart hook
3. If inside a git repo, restores workspace files to the branch state (via git stash + checkout)
4. Sets the branch as active in DB

## Distribution

Published to the official Anthropic marketplace (`claude-plugins-official`).

## Tech Stack

- **Runtime**: Node.js (standard for Claude Code plugins)
- **Database**: SQLite via better-sqlite3
- **Hooks**: JSON lifecycle hooks (PostToolUse, SessionStart, SessionEnd)
- **Skills**: Markdown SKILL.md files for slash commands

## File Structure

```
claude-branch/
├── .claude-plugin/
│   └── plugin.json
├── hooks/
│   └── hooks.json
├── skills/
│   ├── branch/SKILL.md
│   ├── branches/SKILL.md
│   ├── checkout/SKILL.md
│   ├── merge/SKILL.md
│   ├── snapshot/SKILL.md
│   ├── explore/SKILL.md
│   ├── diff/SKILL.md
│   └── delete-branch/SKILL.md
├── scripts/
│   ├── setup.sh
│   ├── branch-manager.js      # Core logic: DB, patch management
│   ├── snapshot-detector.js    # PostToolUse correction detection
│   ├── context-restorer.js     # Checkout context injection
│   └── explorer.js             # Multi-agent exploration
├── package.json
├── README.md
└── LICENSE
```
