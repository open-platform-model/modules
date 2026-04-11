# mc_java_fleet

Dynamic Minecraft Java server fleet with a single shared mc-router for
hostname-based TCP routing.

## Overview

Define N servers in the `servers` map — each server gets its own StatefulSet
and Kubernetes Service. A single mc-router (typically a `LoadBalancer`) routes
incoming player connections by hostname to the correct backend server.

```text
players
  │
  ▼
mc-router (LoadBalancer :25565)
  │
  ├── lobby.mc.example.com    →  {releaseName}-server-lobby.{ns}.svc:25565
  ├── survival.mc.example.com →  {releaseName}-server-survival.{ns}.svc:25565
  └── creative.mc.example.com →  {releaseName}-server-creative.{ns}.svc:25565
```

Adding a server to `servers` automatically:

- Creates a StatefulSet + PVC + Service for that server
- Injects the shared `rconPassword` into the server container
- Adds a `--mapping` entry to the mc-router

## Features

| Feature | Field | Default |
|---|---|---|
| Dynamic server fleet | `servers` | — |
| Enable/disable per server | `enabled` | `true` |
| Bootstrap from archive | `bootstrap.url` | — |
| 12 server types | `vanilla`, `paper`, `fabric`, ... | — |
| Modrinth modpack/projects | `modrinth` | — |
| CurseForge modpack | `autoCurseForge` | — |
| Spiget plugin download | `paper.plugins.spigetResources` | — |
| Extra container ports | `extraPorts` | — |
| Expose extra ports in Service | `extraPorts[].expose` | `false` |
| Router hostname aliases per server | `aliases` | — |
| Backup sidecar | `backup.enabled` | `false` |
| Prometheus monitor sidecar | `monitor.enabled` | `true` |
| VS Code in browser | `codeServer.enabled` | — |
| Restic snapshot browser | `resticGui.enabled` | — |
| Router auto-scale | `router.autoScale` | — |
| NFS / CIFS / hostPath / PVC | `storage.data.type` | `"pvc"` |

## Top-level configuration

| Field | Required | Description |
|---|---|---|
| `releaseName` | [x] | Must match `ModuleRelease.metadata.name` — used for Service DNS names |
| `domain` | [x] | Base domain, e.g. `mc.example.com` |
| `namespace` | [ ] | K8s namespace (default: `"default"`) |
| `servers` | [x] | Map of server name → per-server config |
| `router` | [x] | Router image, port, serviceType, defaultServer, autoScale, etc. |
| `rconPassword` | [x] | Shared RCON password — K8s Secret reference |
| `codeServer` | [ ] | Optional VS Code-in-browser Deployment |
| `resticGui` | [ ] | Optional Backrest web UI for restic snapshots |

## Per-server configuration (`servers.<name>`)

### Basic

| Field | Default | Description |
|---|---|---|
| `enabled` | `true` | `false` sets replicas to 0 (server stopped, data preserved) |
| `image` | `itzg/minecraft-server:java21` | Override to pin a specific image digest |
| `version` | `"LATEST"` | Minecraft version, e.g. `"1.21.1"` |
| `port` | `25565` | Container port, also used by mc-router mapping |
| `serviceType` | `"ClusterIP"` | `"ClusterIP"` \| `"LoadBalancer"` \| `"NodePort"` |
| `aliases` | — | Extra hostnames the router maps to this server |
| `extraPorts` | — | Extra container ports (e.g. BlueMap web UI) |

### Server types

Set exactly one of the following. Defaults to vanilla when none is set.

| Field | Server software |
|---|---|
| `vanilla` | Unmodified Mojang server |
| `paper` | Paper (high-performance Spigot fork) |
| `fabric` | Fabric modded server |
| `forge` | Minecraft Forge and NeoForge modded server |
| `spigot` | Spigot server |
| `bukkit` | CraftBukkit server |
| `purpur` | Purpur server (Paper fork) |
| `magma` | Magma hybrid (Forge + Bukkit API) |
| `sponge` | SpongeVanilla server |
| `ftba` | Feed The Beast modpack server |
| `autoCurseForge` | CurseForge modpack (requires API key) |
| `modrinth` | Modrinth modpack (`TYPE=MODRINTH`) |

### Paper-specific fields

| Field | Env var | Description |
|---|---|---|
| `paper.build` | `PAPER_BUILD` | Pin a specific Paper build number |
| `paper.channel` | `PAPER_CHANNEL` | `"experimental"` to unlock experimental builds |
| `paper.downloadUrl` | `PAPER_DOWNLOAD_URL` | Override download URL for self-hosted Paper |
| `paper.configRepo` | `PAPER_CONFIG_REPO` | URL to a repo of optimised config files (`bukkit.yml`, `paper-global.yml`, etc.) |
| `paper.skipDownloadDefaults` | `SKIP_DOWNLOAD_DEFAULTS` | Skip downloading default Paper/Bukkit/Spigot config files |

### Mod and plugin auto-download

Mods and plugins can be auto-downloaded from registries at server startup.

#### Modrinth projects

Use version IDs (not version numbers) for precise pinning. Modrinth version IDs
are the short alphanumeric strings shown on the version page (e.g. `Oa9ZDzZq`).

```cue
// Modrinth modpack (sets TYPE=MODRINTH)
modrinth: {
    modpack:              "https://modrinth.com/modpack/my-pack"
    version:              "abc123"        // omit for latest release
    projects:             ["lithium", "starlight:versionId"]
    downloadDependencies: "required"      // "none" | "required" | "optional"
}

// Paper — pin plugins by Modrinth version ID
paper: {
    plugins: {
        modrinth: {
            projects: [
                "essentialsx:Oa9ZDzZq",  // 2.21.2
                "luckperms:OrIs0S6b",     // v5.5.17
                "bluemap:Vb2ZE8bR",       // 5.16-paper
            ]
            downloadDependencies: "required"
        }
        removeOldMods: true   // clear stale jars before downloading
    }
}

// Modrinth projects on top of Fabric
fabric: {
    loaderVersion: "0.15.11"
    mods: modrinth: projects: ["lithium", "starlight"]
}
```

#### Spiget and direct URLs

```cue
// Spiget (SpigotMC resource IDs)
paper: plugins: spigetResources: [28140, 34315]

// Direct jar URLs
paper: plugins: urls: ["https://example.com/MyPlugin.jar"]

// Zip modpack of plugin jars
paper: plugins: modpackUrl: "https://example.com/plugins.zip"
```

#### Bootstrap vs registry

Bootstrap and registry-based downloads compose cleanly and serve different purposes:

- **Bootstrap** provides *state*: worlds, plugin config directories
- **Modrinth / SPIGET / URLs** provide *code*: the jar files

Do not put plugin jars in the bootstrap archive. If a jar is present in both the
bootstrap archive and the Modrinth list, both will land in `/data/plugins` — the
Modrinth version overwrites the bootstrap version (Modrinth downloads last). Use
`removeOldMods: true` to clear any stale jars before fresh downloads.

### Extra ports

Add container ports for plugins that open their own HTTP/TCP listeners (e.g. BlueMap):

```cue
extraPorts: [{
    name:          "bluemap"
    containerPort: 8100
    protocol:      "TCP"   // default

    // expose: true also adds this port to the Kubernetes Service
    expose:        true

    // exposedPort: override the Service-side port (defaults to containerPort)
    // exposedPort: 18100
}]
```

By default (`expose: false`) the port is added to the container spec only —
useful for internal plugin listeners that don't need external access.

### Router hostname aliases

Each server can declare additional hostnames the router should map to it,
in addition to the auto-generated `{serverName}.{domain}` mapping:

```cue
"vanilla": {
    // ...
    // Players connecting to vanilla.example.com OR vanilla.mc.example.com
    // both land on this server.
    aliases: ["vanilla.example.com"]
}
```

Aliases use the same backend DNS as the primary mapping:
`{releaseName}-server-{serverName}.{namespace}.svc:{port}`

### Bootstrap

Bootstrap a new server from a tar archive containing worlds, plugins,
mods, and/or config files:

```cue
bootstrap: {
    url:                    "https://nas.example.com/backups/my-server.tar.xz"
    force:                  false  // true to overwrite existing worlds (disaster recovery)
    skipNewerInDestination: true   // true = server-modified files are preserved
}
```

#### Mandatory archive layout

Directories must be at the **root of the archive** with no wrapper directory.
All directories are optional — include only what you need.

```
my-server.tar.xz        ← root of the archive
├── worlds/
│   ├── world/          (contains level.dat)
│   ├── world_nether/
│   └── world_the_end/
├── plugins/            staged → itzg syncs to /data/plugins on every start
├── mods/               staged → itzg syncs to /data/mods on every start
└── config/             staged → itzg syncs to /data/config on every start
```

#### Creating the archive

Run `tar` **from inside** your server data directory so that `worlds/`,
`plugins/`, etc. appear at the archive root — not wrapped in a subdirectory:

```sh
# xz (recommended — best compression)
cd /path/to/server-data
tar -cJf my-server.tar.xz worlds/ plugins/ mods/ config/

# gzip (faster, larger)
tar -czf my-server.tar.gz worlds/ plugins/ mods/ config/

# Include only what you need — all dirs are optional:
tar -cJf worlds-only.tar.xz worlds/
tar -cJf plugins-only.tar.xz plugins/
```

**Wrong** — do not wrap in a subdirectory:
```sh
tar -cJf bootstrap.tar.xz my-server/   # WRONG: produces my-server/worlds/... inside archive
```

Supported formats: `.tar.gz`, `.tar.xz`, `.tar.bz2`, `.tar.zst`

#### Behavior

- The init container runs on **every pod start** (staging emptyDirs are ephemeral).
  Plugins/mods/config are always re-staged so they stay current across pod recreations.
- Worlds are only copied if they **don't already exist** in `/data`. Existing player
  progress is always preserved unless `force: true` is set.
- `skipNewerInDestination: true` (default) means files already modified by the server
  (e.g. plugin configs tuned in-game) are not overwritten by the archive on subsequent starts.

### Backup sidecar

```cue
backup: {
    enabled:          true
    method:           "restic"          // "tar" | "rsync" | "restic" | "rclone"
    interval:         "1h"
    initialDelay:     "5m"
    pruneBackupsDays: 14
    pauseIfNoPlayers: true
    excludes:         ["./bluemap/*"]

    restic: {
        repository: "s3:https://s3.example.com/my-bucket/server"
        password:   { value: "my-restic-password" }
        accessKey:  { value: "ACCESS_KEY_ID" }
        secretKey:  { value: "SECRET_ACCESS_KEY" }
        retention:  "--keep-within 20d"
    }
}
```

### Monitor sidecar

Enabled by default. Exposes Prometheus metrics via `itzg/mc-monitor` on port 8080:

```cue
monitor: {
    enabled: true   // default
    port:    8080
}
```

### Storage

```cue
storage: data: {
    // PVC (default)
    type:         "pvc"
    size:         "10Gi"
    storageClass: "local-path"

    // OR: hostPath (recommended with codeServer for shared file access)
    type:         "hostPath"
    path:         "/var/data/minecraft/survival"
    hostPathType: "DirectoryOrCreate"

    // OR: NFS
    type:      "nfs"
    nfsServer: "10.10.0.2"
    nfsPath:   "/mnt/data/minecraft"

    // OR: CIFS/SMB (requires smb.csi.k8s.io driver)
    type:          "cifs"
    cifsSource:    "//10.10.0.2/minecraft"
    cifsSecretRef: "cifs-credentials"
}
```

## Code Server

Optional VS Code-in-browser Deployment that mounts all server data volumes
at `/servers/{name}` for direct file access (edit configs, inspect worlds, etc.).

```cue
codeServer: {
    enabled:     true
    port:        8080
    serviceType: "ClusterIP"
    password:    { value: "my-password" }
    storage: home: {
        type:         "pvc"    // persists extensions and settings
        size:         "5Gi"
        storageClass: "local-path"
    }
}
```

**hostPath vs PVC:** With `hostPath` storage on server pods, code-server shares
the same host paths without PVC ownership conflicts — full read/write access to
live server data. With `pvc` storage, code-server gets a separate (empty) PVC per
server and **cannot** access the running server's data.

## Restic GUI (Backrest)

Optional [Backrest](https://github.com/garethgeorge/backrest) web UI for browsing
and restoring restic snapshots created by the backup sidecars.

```cue
resticGui: {
    enabled:            true
    port:               9898
    serviceType:        "ClusterIP"
    username:           "admin"
    passwordBcryptHash: "$2a$10$..."   // pre-computed bcrypt hash
    multihostIdentity: {
        keyId:   "ecdsa...."           // pre-generated ECDSA P-256 identity
        privKey: "-----BEGIN EC PRIVATE-----\n...\n-----END EC PRIVATE-----\n"
        pubKey:  "-----BEGIN EC PUBLIC-----\n...\n-----END EC PUBLIC-----\n"
    }
}
```

The Backrest config is generated entirely in CUE and stored as an **immutable K8s
Secret** (content-hash named). Every server with `backup.restic` configured gets
a pre-wired repo entry. Adding or removing a server automatically produces a new
Secret and triggers a pod rollout — no init container, no stale config to manage.

Prune and check schedules are disabled in the pre-configured repos — the
`itzg/mc-backup` sidecar owns the backup schedule. Backrest is used purely for
browsing and restoring.

Click **"Index Snapshots"** in the Backrest UI to populate the snapshot list after
first deploy.

### Restore guide

> **⚠️ MANDATORY: shut down the server before restoring.**
> Restoring to a running server causes world corruption and may permanently
> damage player data. Never skip this step.

The Backrest pod mounts each restic-enabled server's data directory (hostPath
storage only) at `/servers/{name}`, writable. This gives Backrest direct access
to restore snapshots into the live server data directories.

**Prerequisites:**

- Backrest UI accessible (port-forward or ClusterIP proxy)
- `kubectl` access to the cluster
- The server has at least one indexed snapshot in Backrest

**Step 1 — Stop the server**

```sh
kubectl scale statefulset {releaseName}-server-{name} --replicas=0 \
  -n {namespace} --context {context}

# Example:
kubectl scale statefulset mc-server-create-survival --replicas=0 \
  -n minecraft --context admin@gon1-nas2
```

Wait until the pod is fully terminated before proceeding:

```sh
kubectl wait pod -l app.kubernetes.io/name=server-{name} \
  --for=delete -n {namespace} --timeout=60s
```

**Step 2 — Open Backrest and index snapshots**

1. Open the Backrest UI
2. Select the repo for the server (e.g. `mc-create-survival`)
3. Click **"Index Snapshots"** to ensure the snapshot list is current

**Step 3 — Select a snapshot and restore**

1. Click the repo → select the snapshot to restore from
2. Click **"Restore"**
3. In the snapshot file browser, navigate into the `/data/` directory
   (this strips the `/data/` path prefix so files land directly in the server
   data directory rather than a nested `data/` subdirectory)
4. Set the **restore target** to `/servers/{name}` — e.g. `/servers/create-survival`
5. Confirm and start the restore
6. Monitor progress in the Backrest UI — large worlds may take several minutes

Backrest stages restored files in a safety directory named
`data-backrest-restore-<id>` under the target path instead of overwriting the
server directory in place immediately.

> **Note on restore paths:** itzg/mc-backup snapshots all content under `/data/`.
> Selecting `/data/` as the source within the snapshot and `/servers/{name}` as
> the target restores worlds, plugins, mods, and config directly into the server
> data directory without a nested `data/` wrapper.

**Step 4 — Finalize the staged restore**

If code-server is enabled, open it and inspect the staged restore directory:

```sh
cd /servers/{name}
ls -la
```

You should see a directory like `data-backrest-restore-9b04e220`.

If you selected `/data/` inside Backrest before restoring, the staged directory
should contain the server contents directly (`world/`, `plugins/`, `mods/`,
etc.). Move the restored files into place only after reviewing them:

```sh
cd /servers/{name}

# Example staged restore directory
RESTORE_DIR=data-backrest-restore-9b04e220

# Review first
ls -la "$RESTORE_DIR"

# Then move restored contents into place
mv "$RESTORE_DIR"/* .
rmdir "$RESTORE_DIR"
```

If the staged directory contains a nested `data/` directory instead, restore was
started from the snapshot root rather than from `/data/`. In that case move the
contents of `data/` into place instead:

```sh
mv "$RESTORE_DIR"/data/* .
rmdir "$RESTORE_DIR"/data "$RESTORE_DIR"
```

Because the Backrest pod now runs as UID/GID `1000`, the staged restore
directory should be writable from code-server and match the ownership used by
the Minecraft server containers.

**Step 5 — Restart the server**

```sh
kubectl scale statefulset {releaseName}-server-{name} --replicas=1 \
  -n {namespace} --context {context}

# Example:
kubectl scale statefulset mc-server-create-survival --replicas=1 \
  -n minecraft --context admin@gon1-nas2
```

**PVC storage limitation:** If a server uses `type: "pvc"` storage instead of
`hostPath`, its volume cannot be mounted in the Backrest pod (PVC
`ReadWriteOnce` access is held by the running StatefulSet). Restore for PVC
servers requires `kubectl exec` into the backup sidecar container and running
`restic restore` manually, or using a separate restore Job.

### Generating the prerequisites

#### `passwordBcryptHash`

Backrest stores passwords as a **base64-encoded bcrypt hash**. Generate the value
with:

```sh
htpasswd -bnBC 10 "" "yourpassword" | tr -d ':\n' | sed 's/$2y/$2a/' | base64 | tr -d '\n'
```

Store the base64-encoded output as `passwordBcryptHash` in your `values.cue`.

#### `multihostIdentity`

Backrest requires an ECDSA P-256 identity to be present in the config on startup.
Without it, Backrest calls `Update()` to populate `multihost.identity` at startup,
which writes a backup copy of the config file — this fails because the config is
mounted read-only from a K8s Secret.

Generate the identity once per deployment using the helper script:

```sh
cat > /tmp/gen_backrest_key.go << 'EOF'
package main

import (
    "crypto/ecdsa"
    "crypto/elliptic"
    "crypto/rand"
    "crypto/sha256"
    "crypto/x509"
    "encoding/base64"
    "encoding/pem"
    "fmt"
    "os"
)

func main() {
    privKey, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
    if err != nil { fmt.Fprintln(os.Stderr, err); os.Exit(1) }

    privateBytes, _ := x509.MarshalECPrivateKey(privKey)
    pemPriv := string(pem.EncodeToMemory(&pem.Block{Type: "EC PRIVATE", Bytes: privateBytes}))

    publicBytes, _ := x509.MarshalPKIXPublicKey(&privKey.PublicKey)
    pemPub := string(pem.EncodeToMemory(&pem.Block{Type: "EC PUBLIC", Bytes: publicBytes}))

    h := sha256.New()
    h.Write(privKey.PublicKey.X.Bytes())
    h.Write(privKey.PublicKey.Y.Bytes())
    keyid := "ecdsa." + base64.RawURLEncoding.EncodeToString(h.Sum(nil))

    fmt.Printf("keyId:   %q\n", keyid)
    fmt.Printf("privKey: %q\n", pemPriv)
    fmt.Printf("pubKey:  %q\n", pemPub)
}
EOF
go run /tmp/gen_backrest_key.go
```

Copy the three output values into your `values.cue`:

```cue
multihostIdentity: {
    keyId:   "ecdsa.<generated>"
    privKey: "-----BEGIN EC PRIVATE-----\n<generated>\n-----END EC PRIVATE-----\n"
    pubKey:  "-----BEGIN EC PUBLIC-----\n<generated>\n-----END EC PUBLIC-----\n"
}
```

The identity only matters for Backrest's peer-to-peer sync feature (not used here).
It can be a fixed value per deployment — generate it once and commit it alongside
your other values. The private key material is stored in the same K8s Secret as
the restic repo passwords, protected by the same access controls.

## Router

The shared `itzg/mc-router` routes TCP connections by SNI hostname. All servers
in the fleet are auto-wired as `--mapping` args. Per-server `aliases` add
additional hostnames pointing to the same backend.

The router identity (ServiceAccount, ClusterRole, ClusterRoleBinding) is named
`{releaseName}-router`, making it safe to run multiple fleet releases in the
same cluster without ownership conflicts.

```cue
router: {
    port:                25565
    serviceType:         "LoadBalancer"
    connectionRateLimit: 1
    defaultServer: {
        host: "{releaseName}-server-lobby.{namespace}.svc"
        port: 25565
    }

    // Wake/sleep StatefulSets when players connect/disconnect
    autoScale: {
        up:   { enabled: true }
        down: { enabled: true, after: "10m" }
    }

    metrics: { backend: "prometheus" }

    api: {
        enabled: true
        port:    8080
    }
}
```

## Example release

```cue
package main

import (
    m     "opmodel.dev/core/v1alpha1/modulerelease@v1"
    fleet "example.com/modules/mc_java_fleet@v0.1.0"
)

m.#ModuleRelease

metadata: {
    name:      "my-fleet"
    namespace: "minecraft"
}

#module: fleet

values: {
    releaseName: "my-fleet"
    domain:      "mc.example.com"
    namespace:   "minecraft"

    rconPassword: value: "changeme"

    servers: {
        lobby: {
            enabled: true
            server: {
                motd:       "Welcome!"
                maxPlayers: 50
                mode:       "adventure"
                pvp:        false
                difficulty: "peaceful"
            }
            paper: {
                plugins: {
                    modrinth: {
                        projects: [
                            "essentialsx:Oa9ZDzZq",
                            "luckperms:OrIs0S6b",
                        ]
                        downloadDependencies: "required"
                    }
                    removeOldMods: true
                }
            }
            jvm: memory: "1G"

            // Expose BlueMap web UI on port 8100
            extraPorts: [{
                name:          "bluemap"
                containerPort: 8100
                expose:        true
            }]

            // Also reachable at lobby.example.com (in addition to lobby.mc.example.com)
            aliases: ["lobby.example.com"]
        }

        survival: {
            server: {
                maxPlayers: 20
                difficulty: "hard"
            }
            modrinth: {
                modpack:              "https://modrinth.com/modpack/create-ultimate-selection-2"
                version:              "Mun9yNz5"
                downloadDependencies: "required"
            }
            jvm: { initMemory: "2G", maxMemory: "6G", useAikarFlags: true }

            // Seed world from backup archive on first deploy
            bootstrap: {
                url: "https://nas.example.com/backups/survival.tar.gz"
            }

            backup: {
                enabled:      true
                method:       "restic"
                interval:     "1h"
                initialDelay: "5m"
                restic: {
                    repository: "s3:https://s3.example.com/mc/survival"
                    password:   { value: "restic-pass" }
                    accessKey:  { value: "ACCESS" }
                    secretKey:  { value: "SECRET" }
                }
            }

            storage: data: {
                type:         "hostPath"
                path:         "/data/minecraft/survival"
                hostPathType: "DirectoryOrCreate"
            }
        }
    }

    router: {
        port:        25565
        serviceType: "LoadBalancer"
        defaultServer: {
            host: "my-fleet-server-lobby.minecraft.svc"
            port: 25565
        }
    }

    codeServer: {
        enabled:     true
        port:        8080
        serviceType: "ClusterIP"
        password:    { value: "changeme" }
        storage: home: { type: "pvc", size: "5Gi" }
    }

    resticGui: {
        enabled:            true
        port:               9898
        serviceType:        "ClusterIP"
        username:           "admin"
        passwordBcryptHash: "JDJh..."     // htpasswd -bnBC 10 "" "changeme" | tr -d ':\n' | sed 's/$2y/$2a/' | base64 | tr -d '\n'
        multihostIdentity: {              // go run /tmp/gen_backrest_key.go
            keyId:   "ecdsa...."
            privKey: "-----BEGIN EC PRIVATE-----\n...\n-----END EC PRIVATE-----\n"
            pubKey:  "-----BEGIN EC PUBLIC-----\n...\n-----END EC PUBLIC-----\n"
        }
    }
}
```

## Kubernetes resources produced

For a release named `my-fleet` with servers `lobby` and `survival`, plus
`codeServer` and `resticGui` enabled:

```text
StatefulSet/my-fleet-server-lobby
Service/my-fleet-server-lobby          (ClusterIP)
PersistentVolumeClaim/my-fleet-server-lobby-data

StatefulSet/my-fleet-server-survival
Service/my-fleet-server-survival       (ClusterIP)
PersistentVolumeClaim/my-fleet-server-survival-data

Deployment/my-fleet-router
Service/my-fleet-router                (LoadBalancer)
ServiceAccount/my-fleet-router
ClusterRole/my-fleet-router
ClusterRoleBinding/my-fleet-router

Deployment/my-fleet-code-server
Service/my-fleet-code-server           (ClusterIP)

Deployment/my-fleet-restic-gui
Service/my-fleet-restic-gui            (ClusterIP)
Secret/my-fleet-restic-gui-backrest-config-<hash>  (immutable, content-hash named)
```

## Service DNS convention

```text
releaseName = "my-fleet"
namespace   = "minecraft"

server-lobby    →  my-fleet-server-lobby.minecraft.svc.cluster.local
server-survival →  my-fleet-server-survival.minecraft.svc.cluster.local
router          →  my-fleet-router.minecraft.svc.cluster.local
code-server     →  my-fleet-code-server.minecraft.svc.cluster.local
restic-gui      →  my-fleet-restic-gui.minecraft.svc.cluster.local
```

## Differences from the gamestack bundle

| Feature | mc_java_fleet | gamestack bundle |
|---|---|---|
| Velocity proxy | [ ] | [x] |
| mc-monitor | [x] (per-server sidecar) | [x] (per-server sidecar) |
| Deployment model | Single ModuleRelease | Multiple ModuleReleases |
| Proxied network mode | [ ] | [x] |
| Standalone servers | [x] | [x] |
| Bootstrap init container | [x] | [ ] |
| Code Server | [x] | [ ] |
| Restic GUI (Backrest) | [x] | [ ] |
