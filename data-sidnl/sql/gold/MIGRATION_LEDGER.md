# Gold migration ledger

The confirmed live Gold changes are migrations 060–063. Their changes are
summarized in [Gold metric views](../../docs/gold/GOLD_METRIC_VIEWS.md).

The exact Supabase migration versions, names, statement bodies, and hashes for
060–063 were not provided in the repository snapshot. Do not invent ledger
metadata or apply reconstructed SQL. Export the exact statements and migration
metadata from the applied migration history before recording parity or using
these changes in a clean-install baseline.

## Archived alternative

`archive/102_lean_metric_tables.sql` is a table-based design and is **not**
part of the confirmed live schema. It must not be applied or used as a
baseline. Its rollback is retained beside it for historical reference only.
