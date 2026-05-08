# PostgreSQL High Availability — Manual Setup Guide

This document covers the manual steps to set up PostgreSQL streaming replication across three nodes and how to perform failover when a node goes down.

## Cluster Topology

| Node | IP | Role |
|------|----|------|
| node-db-01 | 192.168.56.111 | **Primary** (accepts reads and writes) |
| node-db-02 | 192.168.56.112 | **Standby 1** (streaming replica, candidate for promotion) |
| node-db-03 | 192.168.56.113 | **Standby 2** (streaming replica) |

Streaming replication flow:

```
node-db-01 (Primary)
    │  WAL stream
    ├──────────────► node-db-02 (Standby 1)
    │  WAL stream
    └──────────────► node-db-03 (Standby 2)
```

---

## Part 1: Configure Streaming Replication

### Step 1 — Configure PostgreSQL on all nodes

On **every node**, edit `postgresql.conf` to allow connections from all interfaces:

```ini
listen_addresses = '*'
```

> By default, PostgreSQL only listens on `localhost`. Setting this to `*` is required so standbys and pgpool can connect remotely.

Then update `pg_hba.conf` on **every node** to allow the replication user and pgpool user to connect from within the cluster subnet (`192.168.56.0/24`):

```
# Database administrative login by Unix domain socket
# local   all             postgres                                peer

# TYPE  DATABASE        USER            ADDRESS                 METHOD

# Local (Unix socket) connections
local   all             all                                     scram-sha-256

# IPv4 loopback
host    all             all             127.0.0.1/32            scram-sha-256

# IPv6 loopback
host    all             all             ::1/128                 scram-sha-256

# Replication connections from localhost
local   replication     all                                     scram-sha-256
host    replication     all             127.0.0.1/32            scram-sha-256
host    replication     all             ::1/128                 scram-sha-256

# Replication user from cluster subnet
host    replication     repl            192.168.56.0/24         scram-sha-256

# postgres and pgpool users from cluster subnet (needed by pgpool health checks)
host    all             postgres        192.168.56.0/24         scram-sha-256
host    all             pgpool          192.168.56.0/24         scram-sha-256
```

Reload PostgreSQL to apply the configuration changes:

```bash
sudo systemctl reload postgresql@16-main.service
```

---

### Step 2 — Create required users on the primary node

Run these commands on **node-db-01 (Primary)** only. The users will replicate to standbys automatically once replication is set up.

**Create the replication user** (`repl`) — used by standbys to stream WAL from the primary:

```bash
sudo -u postgres psql -c "CREATE ROLE repl WITH REPLICATION LOGIN PASSWORD 'replPasswd'"
```

**Set a password for the `postgres` superuser** — required for pgpool health checks:

```bash
sudo -u postgres psql -c "ALTER USER postgres WITH PASSWORD 'postgresPasswd'"
```

**Create the pgpool monitoring user** (`pgpool`) — used by pgpool-II to check backend health:

```bash
sudo -u postgres psql -c "CREATE ROLE pgpool WITH LOGIN PASSWORD 'pgpoolPasswd'"
```

Verify the users were created:

```bash
sudo -u postgres psql -c "\du"
```

---

### Step 3 — Bootstrap standby nodes from the primary

Repeat the steps below for **each standby node** (node-db-02 and node-db-03). Use a different replication slot name for each node.

| Node | Replication Slot Name |
|------|-----------------------|
| node-db-02 | `192_168_56_112` |
| node-db-03 | `192_168_56_113` |

**3a. Stop PostgreSQL on the standby:**

```bash
sudo systemctl stop postgresql@16-main.service
```

**3b. Remove the existing data directory** so `pg_basebackup` can create a clean copy:

```bash
sudo rm -rf /var/lib/postgresql/16/main
```

> This wipes all local data. The standby will be fully rebuilt from the primary in the next step.

**3c. Run `pg_basebackup` to copy the primary's data and start streaming:**

For **node-db-02** (use its own slot name `192_168_56_112`):

```bash
sudo -u postgres /usr/lib/postgresql/16/bin/pg_basebackup \
  -h 192.168.56.111 \
  -U repl \
  -p 5432 \
  -D /var/lib/postgresql/16/main \
  -X stream \
  -v \
  -R \
  -C -S 192_168_56_112
```

For **node-db-03** (use its own slot name `192_168_56_113`):

```bash
sudo -u postgres /usr/lib/postgresql/16/bin/pg_basebackup \
  -h 192.168.56.111 \
  -U repl \
  -p 5432 \
  -D /var/lib/postgresql/16/main \
  -X stream \
  -v \
  -R \
  -C -S 192_168_56_113
```

**Flag reference:**

| Flag | Purpose |
|------|---------|
| `-h` | IP address of the primary to copy from |
| `-U` | Replication user (`repl`) |
| `-p` | PostgreSQL port on the primary |
| `-D` | Target data directory on this standby |
| `-X stream` | Stream WAL during the backup (keeps the backup consistent) |
| `-v` | Verbose output |
| `-R` | Write `standby.signal` and populate `postgresql.auto.conf` — marks this server as a standby |
| `-C` | Create a replication slot on the primary |
| `-S` | Name of the replication slot to create |

Expected output:

```
pg_basebackup: initiating base backup, waiting for checkpoint to complete
pg_basebackup: checkpoint completed
pg_basebackup: write-ahead log start point: 0/9000028 on timeline 1
pg_basebackup: starting background WAL receiver
pg_basebackup: created replication slot "192_168_56_113"
pg_basebackup: write-ahead log end point: 0/9000100
pg_basebackup: waiting for background process to finish streaming ...
pg_basebackup: syncing data to disk ...
pg_basebackup: renaming backup_manifest.tmp to backup_manifest
pg_basebackup: base backup completed
```

The `-R` flag automatically writes the primary connection info into `postgresql.auto.conf`. Verify it was created correctly:

```bash
cat /var/lib/postgresql/16/main/postgresql.auto.conf
```

Expected content:

```ini
# Do not edit this file manually!
# It will be overwritten by the ALTER SYSTEM command.
primary_conninfo = 'user=repl password=replPasswd host=192.168.56.111 port=5432 ...'
primary_slot_name = '192_168_56_113'
```

**3d. Start PostgreSQL on the standby:**

```bash
sudo systemctl start postgresql@16-main.service
```

---

### Step 4 — Verify replication is working

Run this on the **primary (node-db-01)** to check that both standbys have connected and are streaming:

```bash
sudo -u postgres psql -c "SELECT client_addr, state, sent_lsn, write_lsn, flush_lsn, replay_lsn FROM pg_stat_replication;"
```

You should see two rows — one for each standby.

Check replication slots to confirm both standbys are consuming WAL:

```bash
sudo -u postgres psql -c "SELECT slot_name, active, restart_lsn FROM pg_replication_slots;"
```

```
   slot_name    | active | restart_lsn
----------------+--------+-------------
 192_168_56_112 | t      | 0/9000000
 192_168_56_113 | t      | 0/9000000
```

Both slots should show `active = t`.

---

## Part 2: Manual Failover

Use this procedure when **node-db-01 (Primary)** goes down and you need to promote a standby.

After failover, the new cluster topology will be:

| Node | IP | New Role |
|------|----|----------|
| node-db-01 | 192.168.56.111 | Down (recovering later) |
| node-db-02 | 192.168.56.112 | **New Primary** |
| node-db-03 | 192.168.56.113 | Standby of node-db-02 |

---

### Step 1 — Shut down (or confirm down) the old primary

Confirm node-db-01 is not reachable before proceeding. If you have access to the node, stop PostgreSQL explicitly to prevent split-brain:

```bash
# On node-db-01 (if accessible)
sudo systemctl stop postgresql@16-main.service
```

---

### Step 2 — Promote node-db-02 to primary

Run on **node-db-02** only:

```bash
sudo -u postgres psql -c "SELECT pg_promote()"
```

This causes node-db-02 to stop following the old primary and accept write connections. The `standby.signal` file is removed and the server enters read-write mode.

Verify the promotion succeeded:

```bash
sudo -u postgres psql -c "SELECT pg_is_in_recovery();"
```

The result should be `f` (false), confirming this node is now the primary.

---

### Step 3 — Re-sync node-db-03 to follow the new primary

node-db-03 was streaming from node-db-01 (the old primary). After failover, it needs to be re-pointed to node-db-02.

**3a. Stop PostgreSQL on node-db-03:**

```bash
sudo systemctl stop postgresql@16-main.service
```

**3b. Remove the data directory:**

```bash
sudo rm -rf /var/lib/postgresql/16/main
```

**3c. Run `pg_basebackup` from the new primary (node-db-02):**

```bash
sudo -u postgres /usr/lib/postgresql/16/bin/pg_basebackup \
  -h 192.168.56.112 \
  -U repl \
  -p 5432 \
  -D /var/lib/postgresql/16/main \
  -X stream \
  -v \
  -R \
  -C -S 192_168_56_113
```

**3d. Start PostgreSQL on node-db-03:**

```bash
sudo systemctl start postgresql@16-main.service
```

Verify node-db-03 is streaming from node-db-02:

```bash
# On node-db-02 (new primary)
sudo -u postgres psql -c "SELECT client_addr, state FROM pg_stat_replication;"
```

---

## Part 3: Rejoining the Old Primary (node-db-01)

When node-db-01 comes back online, it must be re-added as a **standby** of the new primary (node-db-02). It cannot rejoin as primary because it missed writes that happened after the failover.

**On node-db-01:**

Stop PostgreSQL if it auto-started:

```bash
sudo systemctl stop postgresql@16-main.service
```

Remove the old data directory:

```bash
sudo rm -rf /var/lib/postgresql/16/main
```

Re-sync from the new primary (node-db-02) with a new slot name:

```bash
sudo -u postgres /usr/lib/postgresql/16/bin/pg_basebackup \
  -h 192.168.56.112 \
  -U repl \
  -p 5432 \
  -D /var/lib/postgresql/16/main \
  -X stream \
  -v \
  -R \
  -C -S 192_168_56_111
```

Start PostgreSQL:

```bash
sudo systemctl start postgresql@16-main.service
```

Verify on node-db-02 (new primary) that all three slots are active:

```bash
sudo -u postgres psql -c "SELECT slot_name, active FROM pg_replication_slots;"
```

---

## Summary: Failover Cheat Sheet

| Situation | Action |
|-----------|--------|
| Primary (node-db-01) down | Promote node-db-02 with `pg_promote()` |
| Standby needs to follow new primary | `pg_basebackup -h <new_primary_ip>` + restart |
| Old primary rejoins cluster | Wipe data dir, `pg_basebackup` from new primary, restart |
| Verify replication health | `SELECT * FROM pg_stat_replication` on the current primary |
| Check replication slots | `SELECT slot_name, active FROM pg_replication_slots` on primary |
