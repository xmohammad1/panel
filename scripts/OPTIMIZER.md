# PasarGuard Server Optimizer

`scripts/optimizer.sh` tunes an Ubuntu 22.04 host that runs the PasarGuard panel
for large deployments — the defaults target a box in the range of 8 cores /
32 GB RAM serving hundreds of thousands of users.

It is idempotent, backs up every file it touches, and can undo itself.

```bash
sudo ./scripts/optimizer.sh --check      # read-only report, changes nothing
sudo ./scripts/optimizer.sh --dry-run    # show every change, with diffs
sudo ./scripts/optimizer.sh              # apply
sudo ./scripts/optimizer.sh --rollback latest
```

## Profiles

| Profile | For | Difference |
| --- | --- | --- |
| `panel` (default) | The API/database host | Conntrack sized for API traffic |
| `node` | An Xray forwarding host | Doubles conntrack, enables IP forwarding |
| `all-in-one` | Panel and Xray on one box | Both of the above |

## Modules

Run a subset with `--only sysctl,limits` or exclude one with `--skip swap`.

| Module | What it changes |
| --- | --- |
| `sysctl` | `/etc/sysctl.d/99-pasarguard-optimizer.conf` — network stack, conntrack, VM, fd limits |
| `limits` | `limits.d` + systemd `DefaultLimitNOFILE` + per-service drop-ins |
| `thp` | Disables transparent huge pages (boot-persistent unit) |
| `swap` | Creates a swap file when the host has none |
| `io` | udev rules for the block scheduler, queue depth, read-ahead |
| `cpu` | Pins the CPU governor to `performance` when cpufreq exists |
| `nic` | Ring buffers, offloads, RPS/XPS, txqueuelen — re-applied at boot |
| `docker` | `daemon.json`: log rotation, ulimits, `live-restore` |
| `journald` | Caps journal size and adds rate limiting |
| `database` | PostgreSQL or MySQL tuning sized from the host's RAM and cores |
| `nginx` | `worker_rlimit_nofile`, `worker_connections`, http-level tuning |
| `services` | irqbalance, time sync, disables apport/whoopsie |
| `env` | Generates (and optionally applies) panel `.env` settings |

## What it actually tunes, and why

### Sockets and file descriptors

At this user count the panel is a socket-churn machine: every subscription
fetch is a short-lived connection, and every node link is a long-lived gRPC
stream. The defaults on Ubuntu are sized for a desktop.

- `nofile` goes to 1,048,576 for login sessions, systemd services, and the
  `docker`, `pasarguard`, `postgresql` and `nginx` units specifically.
- `net.core.somaxconn` and `tcp_max_syn_backlog` go to 65535 so bursts queue
  instead of being dropped at the accept queue.
- `ip_local_port_range` is widened and `tcp_fin_timeout` / `tcp_tw_reuse` are
  tightened so outbound ports are recycled fast enough to keep up.
- `tcp_keepalive_time` drops to 5 minutes so dead client sockets are reaped
  rather than pinned for two hours.

### Congestion control

BBR plus the `fq` qdisc, when the kernel has `tcp_bbr` (Ubuntu 22.04 does).
`tcp_slow_start_after_idle=0` keeps a reused keepalive connection from
restarting in slow start, which matters for the node-bridge streams.

### Connection tracking

`nf_conntrack_max` is computed from RAM (`RAM_bytes / 16384 / 2`, the kernel's
own rule of thumb), rounded to a multiple of 64K, and doubled for the `node`
profile. On 32 GB that is roughly 1M entries — about 320 MB of kernel memory.
The `established` timeout drops from the stock **5 days** to 1 hour, which is
the single biggest reason conntrack tables overflow on proxy hosts.

Override with `--conntrack-max N` if you measure differently. `--check` reports
live table usage; over ~70% is the signal to raise it.

### Database

Values are derived from detected RAM and core count, not hardcoded. On a
32 GB / 8-core host that lands near:

| Setting | Value | Reason |
| --- | --- | --- |
| `shared_buffers` | 8 GB | 25% of RAM, capped at 12 GB |
| `effective_cache_size` | ~17 GB | 55% of RAM |
| `max_connections` | ~200 | `workers x (pool + overflow)` plus headroom |
| `work_mem` | ~24 MB | 15% of RAM divided across connections |
| `autovacuum_vacuum_scale_factor` | 0.02 | Stock 0.2 lets dead tuples pile up on constantly-updated usage tables |
| `jit` | off | Costs more than it saves on short OLTP queries |
| `synchronous_commit` | off | See durability below |

After writing the file the script parses it the way the server will
(`postgres -C shared_buffers`) and reverts it if PostgreSQL rejects anything.

**Durability.** The default `--db-durability balanced` sets
`synchronous_commit = off` (PostgreSQL) / `innodb_flush_log_at_trx_commit = 2`
(MySQL). A hard crash or power loss can then lose up to about a second of
committed transactions — for this workload, a second of usage counters. The
database is **never** corrupted; only the newest commits are lost. Use
`--db-durability strict` to keep full per-commit fsync.

`max_connections` and `shared_buffers` need a **full restart**, not a reload.

### Panel configuration

`--apply-env` patches the panel `.env` (after backing it up). Without it, the
recommendations are written to
`/var/lib/pasarguard-optimizer/reports/env-recommendations.env` for review.

The two changes that matter most at scale:

**Workers.** A single uvicorn worker cannot use 8 cores. The script recommends
`UVICORN_WORKERS = cores * 3/4`, leaving headroom for PostgreSQL and
node-bridge. But `main.py` calls `require_nats_if_multiworker()`: **more than
one worker without NATS refuses to start.** So the script probes `NATS_URL`
first and keeps `UVICORN_WORKERS = 1` when NATS is unreachable, rather than
handing you a config that will not boot. Deploy NATS, then re-run:

```bash
sudo ./scripts/optimizer.sh --only env --apply-env
```

**Job intervals.** Every background job in `app/jobs/` sweeps the full user
table. At 300k users the stock intervals (`JOB_REVIEW_USERS_INTERVAL = 30`,
`JOB_RECORD_USER_USAGES_INTERVAL = 10`) mean a new sweep starts before the
previous one finished, so runs stack and the database never goes idle. The
recommended values roughly double them.

Remember that the connection ceiling is per process:
`(SQLALCHEMY_POOL_SIZE + SQLALCHEMY_MAX_OVERFLOW) x UVICORN_WORKERS`. Raising
workers means raising `max_connections` on the database to match.

## Rollback

Every run writes a backup set under `/var/lib/pasarguard-optimizer/backups/`.

```bash
sudo ./scripts/optimizer.sh --list-backups
sudo ./scripts/optimizer.sh --rollback 20260115-104233
sudo ./scripts/optimizer.sh --rollback latest
```

Files that existed before the run are restored; files the script created are
removed. Restart the affected services afterwards to fully revert.

## Verifying afterwards

```bash
sudo ./scripts/optimizer.sh --check
```

Worth watching in the first days:

- **Conntrack usage** — over 70% means raise `--conntrack-max`.
- **`ss -s` TIME-WAIT count** — should stay well under the local port range.
- **`pg_stat_activity` count vs `max_connections`** — if it saturates, either
  lower the pool sizes or raise `max_connections`.
- **Memory** — `shared_buffers` + `work_mem x connections` + the panel workers
  must fit in RAM with room for page cache.

## Caveats

- **LXC / OpenVZ** containers do not own most kernel knobs. The script detects
  this, applies what it can, and names every key the kernel refused.
- **Docker log caps** apply to newly created containers. Existing containers
  keep their current logging config until recreated (`docker compose up -d
  --force-recreate`).
- **`nofile` in running shells** does not change; re-login or reboot.
- **PgBouncer** is worth considering above ~8 workers, but SQLAlchemy's asyncpg
  driver uses prepared statements, so transaction-pooling mode needs
  `statement_cache_size=0` on the connection. The script does not set this up.
- The script never touches firewall rules, TLS certificates, or panel data.
