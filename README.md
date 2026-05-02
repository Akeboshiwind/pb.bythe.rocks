# pb.bythe.rocks

A [PocketBase](https://pocketbase.io) instance deployed to [Fly.io](https://fly.io),
with [Litestream](https://litestream.io) continuously replicating the SQLite
database to [Cloudflare R2](https://www.cloudflare.com/developer-platform/r2/).

Litestream is **optional** — the app boots and runs fine without it. Add R2
credentials when you're ready and Litestream will start replicating on the
next deploy. If a replica already exists when the volume is empty (e.g. after
a region migration or volume rebuild), it will be restored automatically on
boot.

## Layout

| File             | Purpose                                                    |
| ---------------- | ---------------------------------------------------------- |
| `Dockerfile`     | Builds an image with the PocketBase + Litestream binaries. |
| `entrypoint.sh`  | Restores from R2 (if configured), then runs PocketBase.    |
| `litestream.yml` | Litestream replica config (env-var driven).                |
| `fly.toml`       | Fly.io app config: 1 GiB volume mount, HTTPS, custom dom.  |

## One-time setup

You'll do this once. The deploy step at the bottom is what you re-run.

### 1. Install the Fly CLI and sign in

```sh
brew install flyctl       # or: curl -L https://fly.io/install.sh | sh
fly auth login
```

### 2. Create the Fly app and volume

The app name in `fly.toml` is `pb-bythe-rocks`. Fly app names are global, so
if it's taken, change the `app = ...` line to something unique and use that
name everywhere below.

```sh
fly apps create pb-bythe-rocks
fly volumes create pb_data --size 1 --region lhr --app pb-bythe-rocks
```

The volume name (`pb_data`), size, and region must match `fly.toml`. Pick a
region close to you — `fly platform regions` lists them.

### 3. Deploy (without Litestream — fine to skip ahead)

```sh
fly deploy
```

This is enough to have a working PocketBase. Open
`https://pb-bythe-rocks.fly.dev/_/` and create the superuser account when
prompted. **Do this before pointing your domain at it** so you're not racing
the public internet to claim the admin account.

### 4. Custom domain (`pb.bythe.rocks`)

Tell Fly about the domain first — the command prints the exact DNS records
you need to set, so this is the source of truth, not this README:

```sh
fly certs add pb.bythe.rocks --app pb-bythe-rocks
```

For a subdomain, Fly recommends a single CNAME pointing at the app's
`.fly.dev` hostname (the `fly certs add` output will spell out the exact
target):

```
Type:   CNAME
Name:   pb
Value:  pb-bythe-rocks.fly.dev   # confirm against the `fly certs add` output
TTL:    auto / 300
Proxy:  off  (if Cloudflare — keep DNS-only, no orange cloud)
```

Then watch the cert issue (Let's Encrypt, ~30s):

```sh
fly certs show pb.bythe.rocks --app pb-bythe-rocks
```

Once it's green, `https://pb.bythe.rocks` serves PocketBase. If validation
stalls, `fly certs show` lists the verification records still missing —
usually an `_acme-challenge` CNAME or `_fly-ownership` TXT, which only
matters for proxied / wildcard / unusual setups.

### 5. Cloudflare R2 + Litestream

Skip this section if you don't want backups yet — the app is already running
without them.

#### 5a. Create the R2 bucket

1. Cloudflare dashboard → **R2** → **Create bucket**.
2. Name: e.g. `pb-bythe-rocks-backups`. Location hint: pick the closest one
   to your Fly region.
3. After creation, note the **Account ID** shown on the R2 home page — the
   endpoint is `https://<account-id>.r2.cloudflarestorage.com`.

#### 5b. Create an R2 API token

> **Use the right token UI.** Cloudflare has two unrelated pages that both
> mention "API tokens": the global **My Profile → API Tokens** page only
> issues bearer-style tokens, *not* the S3 credentials Litestream needs. You
> have to be on the R2-specific page below.

1. R2 → **Manage R2 API Tokens** (top-right of the R2 overview) → **Create
   API token**.
2. Permissions: **Object Read & Write**.
3. Specify the bucket you just created (don't grant account-wide access).
4. TTL: as long as you want; no IP restriction.
5. Save the **Access Key ID** and **Secret Access Key** — you only see the
   secret once. Ignore the "Token value" field on the same page; that's a
   bearer token for the REST API, not the S3 secret.

#### 5c. Push the credentials to Fly as secrets

> **Endpoint must be host-only.** R2 sometimes shows the S3 endpoint with
> the bucket pre-appended (e.g. `…r2.cloudflarestorage.com/pb-bythe-rocks-backups`).
> Strip that suffix — `litestream.yml` already specifies the bucket
> separately and uses path-style addressing, so a bucket-suffixed endpoint
> produces a doubled bucket path and 401s with no clear error.

```sh
fly secrets set \
  LITESTREAM_BUCKET=pb-bythe-rocks-backups \
  LITESTREAM_ENDPOINT=https://<account-id>.r2.cloudflarestorage.com \
  LITESTREAM_ACCESS_KEY_ID=<access-key-id> \
  LITESTREAM_SECRET_ACCESS_KEY=<secret-access-key> \
  --app pb-bythe-rocks
```

`LITESTREAM_PATH` (the prefix inside the bucket) defaults to `pocketbase`
via `fly.toml`. Override it as a secret if you want to share one bucket
across several apps.

Setting secrets restarts the machine. On boot, the entrypoint sees all four
vars are present, runs `litestream restore -if-replica-exists` (no-op the
first time — there's nothing in R2 yet), then launches PocketBase under
`litestream replicate`. Subsequent writes start streaming to R2 within
seconds.

## Day-to-day

```sh
fly deploy                    # ship code/config changes
fly logs                      # tail logs (look for [entrypoint] lines)
fly ssh console               # shell into the machine
fly status                    # machine + volume + cert state
```

### Verifying backups

After some writes, list what's in R2:

```sh
fly ssh console -C "litestream snapshots -config /etc/litestream.yml /pb_data/data.db"
```

You should see snapshot generations with recent timestamps.

### Restoring (disaster recovery)

The entrypoint already restores automatically on a fresh volume. To restore
manually onto a running machine:

```sh
fly ssh console
# inside the VM:
pkill -f pocketbase
rm /pb_data/data.db*
litestream restore -config /etc/litestream.yml /pb_data/data.db
exit
fly machine restart <machine-id>
```

To restore locally for inspection, set the same four `LITESTREAM_*` vars in
your shell and run the same `litestream restore` command against a local
path.

## Updating PocketBase / Litestream versions

Bump `PB_VERSION` or `LITESTREAM_VERSION` in `Dockerfile` and re-`fly deploy`.
PocketBase migrations run automatically on startup. Take a manual R2 snapshot
first if you're nervous:

```sh
fly ssh console -C "litestream snapshots -config /etc/litestream.yml /pb_data/data.db"
```
