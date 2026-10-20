# Migrating background jobs to Styx

Background jobs use `styx ~> 0.1.1`, the Oban fork maintained at
[gsmlg-dev/styx](https://github.com/gsmlg-dev/styx). Worker names, queues, arguments,
retry policies and pruning retention remain the same.

Fresh databases create the Styx v1 schema directly. The original migration
filenames and module names remain in place to preserve Ecto migration history.
The old Oban v14 upgrade is a no-op because Styx v1 includes those changes.

Existing databases use `20261020000000_replace_oban_with_styx.exs` to rename
`oban_jobs`, `oban_peers` and `oban_job_state` to their Styx equivalents. The
transition preserves job IDs, worker names, payloads, states, retry history and
the ID sequence. Existing index and sequence names may retain the `oban_` prefix;
Styx uses the renamed tables without requiring those physical names to change.

## Upgrade

1. Back up PostgreSQL and stop all application instances processing Oban jobs.
2. Run migrations using the new release before starting its application:

   ```sh
   ./bin/gsmlg_umbrella eval "GSMLG.Release.migrate()"
   ```

3. Start the new release and verify Styx queues and worker processing.

Old Oban instances and new Styx instances cannot process the same queue during a
rolling overlap: their table names and PostgreSQL notification channels differ.
Telemetry handlers outside this repository must use `[:styx, ...]` event names.

## Rollback

Stop Styx instances, then use the new release to roll back the transition before
starting the old release:

```sh
./bin/gsmlg_umbrella eval \
  "GSMLG.Release.rollback(GSMLG.Repo, 20261020000000)"
```

For databases upgraded from Oban, rollback restores the original table and enum
names and the Oban v14 schema marker. For fresh Styx databases, rolling back the
transition leaves their Styx schema intact.
