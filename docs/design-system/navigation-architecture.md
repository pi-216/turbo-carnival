# Navigation Architecture

**Status:** Approved  
**Date:** 2025-11-25

## Design Principles

1. **Fully RESTful/Stateless** - URL is source of truth
2. **No collapse/expand state** - Each level is a separate page
3. **Back navigation** - Simple back links instead of breadcrumbs
4. **Persona-first** - Top level is persona selection

## Navigation Levels

### Level 1: Persona Selection
**URL:** `/personas`  
**Sidebar:** List of personas + "New Persona" button  
**Action:** Click persona → navigate to persona dashboard

### Level 2: Persona Dashboard
**URL:** `/personas/:id`  
**Header:** Persona name (no back link - this is top level)  
**Sidebar:** Dashboard, Strategy, Generation, Schedule, Library  
**Action:** Click section → navigate to section overview

### Level 3: Section Overview
**URL:** `/personas/:id/strategy`  
**Header:** ← Back | Strategy  
**Sidebar:** Pillars, Next Post, Gap Analysis  
**Action:** Click sub-section → navigate to detail page

### Level 4+: Detail Pages
**URL:** `/personas/:id/strategy/pillars`  
**Header:** ← Back | Pillars  
**Content:** List/detail view with actions

## Persona Dashboard (Future)

**Deferred until merge-fluffy-train implementation**

Initial vision:
- Current state (Instagram stats, etc.)
- Pillar & cluster states
- Next post preview
- Last post summary
- 3 primary calls-to-action

Will be designed with real data during merge.

## URL Structure Reference

```
/personas                           # Level 1: All personas
/personas/new                       # Create persona
/personas/:id                       # Level 2: Persona dashboard
/personas/:id/strategy              # Level 3: Strategy section
/personas/:id/strategy/pillars      # Level 4: Pillar management
/personas/:id/generation            # Level 3: Generation section
/personas/:id/generation/pipelines  # Level 4: Pipeline list
/personas/:id/generation/runs       # Level 4: Active runs
/personas/:id/generation/voting     # Level 4: Voting interface
/personas/:id/schedule              # Level 3: Schedule section
/personas/:id/schedule/calendar     # Level 4: Calendar view
/personas/:id/library               # Level 3: Content library
/personas/:id/library/clusters      # Level 4: Cluster browser
```

## Component Implications

### Layout::SidebarComponent
- **Simple flat list** of links (no nesting)
- Active state highlighting
- Icon + label layout
- Responsive drawer for mobile
- No state persistence needed

### Layout::HeaderComponent
- Back link (contextual)
- Page title
- Quick action buttons (contextual to current page)
- No persona switcher (use back navigation)

### Layout::BreadcrumbHelper (optional)
- Calculate back link from current URL
- Could show full trail if needed
- Keep it simple for now
