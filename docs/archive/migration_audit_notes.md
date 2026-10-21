# Migration Audit Notes - 2025-12-10

## Current State

### Cluster → Pillar Mapping
- **Total Clusters:** 22
- **Clusters with PRIMARY pillar:** 1 (Cluster #1 "Morning Coffee Moments")
- **Clusters with pillar assignments:** 22 (all have at least one pillar via join table)
- **Primary pillar is rarely used** - fallback to first pillar will be needed

### Data to Migrate
- **4 photos** - all have cluster assignments
  - Cluster #1: 2 photos (has primary pillar)
  - Cluster #11: 1 photo (no primary, fallback needed)
  - Cluster #8: 1 photo (no primary, fallback needed)

- **9 pipeline runs** with cluster_id (need migration)
- **24 pipeline runs** without cluster_id (leave NULL)

### Migration Strategy
Since most clusters don't have primary_pillar set, we'll use:
```ruby
pillar = cluster.primary_pillar || cluster.pillars.first
```

This is safe because:
1. All clusters have at least one pillar assignment
2. Most clusters have exactly one pillar anyway
3. Edge case: Cluster with multiple pillars but no primary → picks first

### Edge Cases Found
✓ No orphaned photos (all have cluster_id)
✓ No clusters without pillar assignments
✓ No critical data integrity issues

## Migration Plan Confirmed
Proceed with design.md strategy using fallback to first pillar.
