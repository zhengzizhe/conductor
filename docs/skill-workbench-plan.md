# Skill Workbench Plan

## Goal

Build Conductor's Skill Workbench as a real management console, not as an enlarged right-side panel and not as a visual copy of `xingkongliang/skills-manager`.

The reference project is useful because of its product structure:

- Dashboard gives the operator status and next actions.
- My Skills is the central asset library.
- Install Skills owns all acquisition flows.
- Workspace views show what each agent can actually see.
- Projects are first-class sync targets.
- Presets are reusable skill sets.
- Settings owns agents, paths, backup, diagnostics, and app-level behavior.
- Detail sheets keep deep inspection out of list pages.

Our UI should keep Conductor's visual language, but adopt this management model.

## Current Direction

The right panel stays small:

- Health summary
- Top action shortcuts
- Recent library preview
- Agent preview
- Button to open the full workbench

The modal becomes the real Skill Workbench:

- It should feel like a standalone app inside Conductor.
- It should have persistent navigation and page-level workflows.
- It should not render every module as one long scroll.

## Workbench Shell

### Layout

Use a three-layer shell:

- Left navigation/object rail
- Main page work area
- Detail sheet / inspector overlay

The left rail should not be a flat tab list. It should be a management tree:

- Home
- Library
- Install
- Global Workspace
- Presets
- Projects
- Agents
- Backup & Activity

Dynamic groups should live under the static entries when useful:

- Presets: recent/custom presets
- Projects: tracked projects
- Agents: installed/enabled agents with sync counts

### Top Bar

Every page shares:

- Global search
- Add menu: skills.sh, local, Git, scan
- Sync mode selector
- Refresh
- Current context badges

The top bar changes only with context-specific secondary actions.

## Pages

### Home

Purpose: answer "what should I do now?"

Content:

- Library count
- Sync coverage
- Enabled agents
- Source/update status
- Next actions queue
- Recent skills
- Recent activity
- Workspace health preview

Primary actions:

- Install Skill
- Scan local skills
- Deploy unsynced skills

### Library

Purpose: manage central library assets.

Content:

- Grid/list toggle
- Search
- Source filters
- Tag filters
- Update-state filters
- Multi-select toolbar
- Skill cards/rows with sync dots, source, tags, and update state

Actions:

- Open detail sheet
- Sync/unsync by agent
- Batch sync
- Batch tag
- Batch delete
- Batch export
- Check updates
- Refresh from source

Detail sheet tabs:

- Overview
- Deploy
- Docs
- Source/Diff
- Activity

### Install

Purpose: all acquisition flows.

Tabs:

- Market
- Local
- Git
- Scan

Market:

- skills.sh search
- hot/trending/all-time boards
- installed state
- install action

Local:

- import folder/bundle/zip
- scan local agent folders
- discovered-skill list
- batch import

Git:

- repo URL
- optional subdirectory
- optional ref
- install multiple skills when repo contains several

### Global Workspace

Purpose: show what agents actually see.

Modes:

- All Agents overview
- Single Agent detail

All Agents:

- agent cards with installed/enabled/path/synced count
- coverage
- actions: reveal, enable/disable, open agent detail

Agent Detail:

- central skills synced to that agent
- local-only skills discovered in that agent directory
- sync status: in sync, missing, stale, diverged, local only
- actions: pull to center, deploy from center, remove local target, reveal

### Presets

Purpose: reusable sets of skills.

Content:

- preset list
- create/rename/delete
- skill membership editor
- drag reorder inside preset
- agent target summary

Actions:

- apply to selected agents
- remove from selected agents
- apply to project
- use preset as Library filter

### Projects

Purpose: project-local skill sync.

Content:

- tracked project list
- per-project health
- agent target dots
- add/remove/reveal project

Project detail:

- skills in the project grouped by relative path
- enabled/disabled by agent
- project-only vs center-only vs diverged status
- import project skill to center
- deploy center skill to project
- apply/remove preset to project

### Agents

Purpose: manage adapters and paths.

Content:

- installed agent catalog
- enabled state
- skills directory
- project-relative directory if supported
- category
- custom agents
- path override state

Actions:

- enable/disable
- reveal path
- add custom agent
- edit/reset custom paths when backend supports it
- reorder favorite agents later

### Backup & Activity

Purpose: migration, audit, and history.

Content:

- import bundle
- export selected/all
- audit log
- recent operations

Later, if backend supports it:

- git backup setup/status
- snapshot list
- restore snapshot
- clear/export logs

## Core Flows

### First Run

1. User opens right panel.
2. Right panel shows empty state and two actions: Install and Scan.
3. User opens workbench directly into Install.
4. Local scan or market install adds skills.
5. Workbench recommends deploying unsynced skills.

### Skill Inspection

1. User opens Library.
2. Filters by source/tag/status.
3. Opens a skill detail sheet.
4. Checks docs/source/activity/deploy state.
5. Syncs to selected agents without leaving detail.

### Agent-Centric Management

1. User opens Global Workspace.
2. Selects an agent.
3. Sees central synced skills and local-only skills.
4. Pulls local-only skills into Library or removes stale targets.

### Project-Centric Management

1. User opens Projects.
2. Adds a project.
3. Applies a preset or selected skills.
4. Uses project detail to resolve drift.

## Implementation Plan

### Phase 1: Shell

- Replace current workbench sidebar with static navigation plus dynamic groups.
- Make page selection independent from compact panel state.
- Keep current detail sheet.
- Make modal dimensions stable and content page-based.

### Phase 2: Library And Install

- Split Library into real page header, filter bar, list/grid area, and multi-select toolbar.
- Split Install into Market/Local/Git/Scan tabs instead of one continuous section.
- Preserve existing backend calls.

### Phase 3: Workspace And Agents

- Move agent cards into Global Workspace overview.
- Add single-agent drilldown state inside the workbench.
- Keep Agents as adapter/path/settings management, not deployment status.

### Phase 4: Presets And Projects

- Make Presets a full editor, not just a deployment section.
- Make Projects a navigation object group plus detail page.
- Keep project sync controls inside project context.

### Phase 5: Backup And Activity

- Keep bundle import/export visible in Backup.

### Phase 6: Polish

- Add motion to page transitions, sheet opening, filter changes, batch toolbar, and scan/install states.
- Keep animation purposeful: navigation context, selection state, and async operation feedback.
- Remove heavy dividers and nested cards.

## Non-Goals

- Do not copy the reference project's visual style.
- Do not force every capability into the right panel.
- Do not make the modal one giant scrolling page.
- Do not put every action in every page.

## Success Criteria

- A new user can answer: "Where do I install, where do I manage, where do I deploy, where do I fix?"
- A power user can batch manage skills without opening each skill.
- Agent, preset, and project management feel like first-class objects.
- The right panel remains a dashboard/launcher, not the management surface.
