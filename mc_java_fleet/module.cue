// Package mc_java_fleet defines a Minecraft Java server fleet module.
//
// Combines a dynamic fleet of Minecraft Java servers with a single shared
// mc-router that routes player connections by hostname.
//
// ## Concept
//
// Define N servers in `servers` map — each gets its own StatefulSet and
// Kubernetes Service. A single mc-router (LoadBalancer) routes incoming
// TCP connections by hostname to the correct server:
//
//   lobby.mc.example.com    →  router  →  {releaseName}-server-lobby.{namespace}.svc
//   survival.mc.example.com →  router  →  {releaseName}-server-survival.{namespace}.svc
//
// ## Auto-wiring
//
// Adding a server to the `servers` map automatically:
//   - Creates a StatefulSet + Service for that server
//   - Adds a --mapping entry to the shared mc-router
//
// ## Service DNS convention
//
// Set `releaseName` to exactly match the ModuleRelease `metadata.name`.
// The K8s Service for each server is reachable at:
//   {releaseName}-server-{serverName}.{namespace}.svc
// The router Service:
//   {releaseName}-router.{namespace}.svc
//
// ## RCON password
//
// A single `rconPassword` is shared across all servers. Define it once at
// the module level; the components automatically inject it into each server.
package mc_java_fleet

import (
	m "opmodel.dev/core/v1alpha1/module@v1"
	schemas "opmodel.dev/opm/v1alpha1/schemas@v1"
)

// Module definition
m.#Module

// Module metadata
metadata: {
	modulePath:       "example.com/modules"
	name:             "mc-java-fleet"
	version:          "0.1.0"
	description:      "Dynamic Minecraft Java server fleet with a shared mc-router for hostname-based routing"
	defaultNamespace: "default"
}

_#portSchema: uint & >0 & <=65535

// Shared Modrinth auto-download config (works for both mods and plugins)
_#modrinthConfig: {
	projects: [...string]
	downloadDependencies?: "none" | "required" | "optional"
	allowedVersionType?:   "release" | "beta" | "alpha"
}

// Mods config — for mod-based server types (Forge, Fabric, FTB)
_#modsConfig: {
	// List of URLs to mod jar files
	urls?: [...string]

	// Modrinth project auto-download
	modrinth?: _#modrinthConfig

	// URL to a modpack zip to download at startup
	modpackUrl?: string

	// Remove old mods before installing new ones
	removeOldMods: bool | *false
}

// Plugins config — for plugin-based server types (Paper, Spigot, Bukkit, Purpur)
_#pluginsConfig: {
	// List of URLs to plugin jar files (PLUGINS)
	urls?: [...string]

	// Spigot resource/plugin IDs for auto-download via Spiget (SPIGET_RESOURCES)
	spigetResources?: [...int]

	// Modrinth project auto-download (MODRINTH_PROJECTS)
	modrinth?: _#modrinthConfig

	// URL to a zip archive of plugin jars to download and install (MODPACK).
	// The zip must contain jar files at its top level.
	modpackUrl?: string

	// Remove old plugins before installing new ones (REMOVE_OLD_MODS)
	removeOldMods: bool | *false
}

// _#config — full per-server configuration.
// The rcon.password field is always provided at module level via #config.rconPassword
// and injected into each server component — it is intentionally absent here.
_#config: {
	// name used so that router can reference this server in its defaultServer config when hostname doesn't match any server (e.g. lobby.mc.example.com → defaultServer)
	name: string

	// enabled controls whether the server is running (replicas=1) or stopped (replicas=0).
	// Set to false to gracefully shut down a server without removing it from the fleet.
	enabled: bool | *true

	// === Container Image ===
	image: schemas.#Image & {
		repository: string | *"itzg/minecraft-server"
		tag:        string | *"java21"
		digest:     string | *""
	}

	// === Game Version ===
	// Minecraft version (e.g., "1.20.4", "LATEST", "SNAPSHOT")
	version: string | *"LATEST"

	// === EULA ===
	eula: bool | *true

	// === Server Type ===
	// Set exactly ONE of the following to select your server software.
	// Defaults to vanilla behaviour when none is set.

	// VANILLA — unmodified Mojang server
	vanilla?: {}

	// PAPER — Paper server (high-performance Spigot fork)
	paper?: {
		// Custom download URL for self-hosted Paper builds (PAPER_DOWNLOAD_URL)
		downloadUrl?: string

		// Pin a specific Paper build number (PAPER_BUILD).
		// Omit to always use the latest build for the selected VERSION.
		build?: uint

		// Set to "experimental" to allow experimental Paper builds (PAPER_CHANNEL).
		// Required for some newer Minecraft versions before a stable build is released.
		channel?: "experimental"

		// URL to a repository of optimised config files (PAPER_CONFIG_REPO).
		// The container appends /{VERSION}/{file} to download bukkit.yml,
		// spigot.yml, paper-global.yml, etc. at startup.
		configRepo?: string

		// Skip downloading default Paper/Bukkit/Spigot config files (SKIP_DOWNLOAD_DEFAULTS).
		// Set true when you manage all config files yourself via bootstrap.
		skipDownloadDefaults?: bool

		plugins?: _#pluginsConfig
	}

	// FORGE — Minecraft Forge modded server
	forge?: {
		version:       string
		installerUrl?: string
		mods?:         _#modsConfig
	}

	// FABRIC — Fabric modded server
	fabric?: {
		loaderVersion: string
		installerUrl?: string
		mods?:         _#modsConfig
	}

	// SPIGOT — Spigot server
	spigot?: {
		downloadUrl?: string
		plugins?:     _#pluginsConfig
	}

	// BUKKIT — CraftBukkit server
	bukkit?: {
		downloadUrl?: string
		plugins?:     _#pluginsConfig
	}

	// SPONGEVANILLA — SpongeVanilla server
	sponge?: {
		version: string
	}

	// PURPUR — Purpur server (Paper fork with extra features)
	purpur?: {
		// Pin a specific Purpur build number (PURPUR_BUILD).
		// Omit to always use the latest build for the selected VERSION.
		build?:   uint
		plugins?: _#pluginsConfig
	}

	// MAGMA — Magma server (Forge + Bukkit/Spigot API hybrid)
	magma?: {
		mods?:    _#modsConfig
		plugins?: _#pluginsConfig
	}

	// FTBA — Feed The Beast modpack server
	ftba?: {
		mods?: _#modsConfig
	}

	// AUTO_CURSEFORGE — CurseForge modpack server
	autoCurseForge?: {
		apiKey: schemas.#Secret & {
			$secretName: "server-secrets"
			$dataKey:    "cf-api-key"
		}
		pageUrl?:         string
		slug?:            string
		fileId?:          string
		filenameMatcher?: string
		excludeMods?: [...string]
		includeMods?: [...string]
		forceSynchronize?: bool
		parallelDownloads: uint | *1
	}

	// MODRINTH — Modrinth modpack server (TYPE=MODRINTH)
	// Installs a modpack from a Modrinth URL and optionally pins extra projects.
	// Use `version` to pin a specific pack version; omit to use the latest release.
	// `projects` adds extra mods/plugins on top of the modpack (format: "slug:versionId").
	modrinth?: {
		// Modrinth modpack page URL (e.g. "https://modrinth.com/modpack/my-pack")
		modpack: string

		// Specific modpack version ID to pin (e.g. "ZYF5kPnk"). Omit for latest.
		version?: string

		// Extra projects to install on top of the modpack.
		// Format: "slug" or "slug:versionId" (e.g. "bluemap:lHRktt6S")
		projects?: [...string]

		// Whether to also download dependency projects
		downloadDependencies?: "none" | "required" | "optional"
	}

	matchN(<=1, [
		{vanilla!: _},
		{paper!: _},
		{forge!: _},
		{fabric!: _},
		{spigot!: _},
		{bukkit!: _},
		{sponge!: _},
		{purpur!: _},
		{magma!: _},
		{ftba!: _},
		{autoCurseForge!: _},
		{modrinth!: _},
	])

	// === JVM Configuration ===
	jvm: {
		// Single heap size (MEMORY). When maxMemory is set, maxMemory is used as MEMORY
		// and initMemory is used as INIT_MEMORY. Do not set both memory and maxMemory.
		memory?: string | *"2G"

		// Split heap: initial heap size (INIT_MEMORY). Only used when maxMemory is set.
		initMemory?: string

		// Split heap: maximum heap size (MAX_MEMORY → rendered as MEMORY env var).
		// When set, memory field is ignored.
		maxMemory?: string

		opts?:         string
		xxOpts?:       string
		useAikarFlags: bool | *true
	}

	// === Server Properties ===
	server: {
		motd?:              string | *"OPM Minecraft Java Server"
		maxPlayers:         uint & >0 & <=1000 | *10
		difficulty:         "peaceful" | "easy" | *"normal" | "hard"
		mode:               *"survival" | "creative" | "adventure" | "spectator"
		pvp:                bool | *true
		enableCommandBlock: bool | *false
		ops?: [...string]
		blocklist?: [...string]
		seed?:                      string
		maxWorldSize?:              uint
		viewDistance:               uint & <=32 | *10
		allowNether:                bool | *true
		allowFlight:                bool | *false
		announcePlayerAchievements: bool | *true
		forceGameMode:              bool | *false
		generateStructures:         bool | *true
		hardcore:                   bool | *false
		maxBuildHeight:             uint | *256
		maxTickTime:                int | *60000
		spawnAnimals:               bool | *true
		spawnMonsters:              bool | *true
		spawnNPCs:                  bool | *true
		spawnProtection:            int & >=0 | *0

		// levelType accepts standard values or the minecraft: namespaced format
		// (e.g. "minecraft:normal", "minecraft:flat") used since 1.16+.
		// Standard values: "DEFAULT", "FLAT", "LARGEBIOMES", "AMPLIFIED", "CUSTOMIZED"
		levelType: string | *"DEFAULT"

		worldSaveName:            string | *"world"
		onlineMode:               bool | *true
		enforceSecureProfile:     bool | *true
		overrideServerProperties: bool | *true
		resourcePackUrl?:         string
		resourcePackSha?:         string
		resourcePackEnforce?:     bool
		vanillaTweaksShareCodes?: [...string]

		// Optional server display name (SERVER_NAME env var)
		serverName?: string

		// Enable rolling log files (ENABLE_ROLLING_LOGS)
		enableRollingLogs: bool | *true

		// Container timezone (TZ env var, e.g. "Europe/Stockholm")
		tz?: string
	}

	// === RCON Configuration ===
	// Note: password is absent here — always injected from #config.rconPassword.
	rcon: {
		enabled: bool | *true
		port:    _#portSchema | *25575
	}

	// === Query Port ===
	query: {
		enabled: bool | *false
		port:    _#portSchema | *25565
	}

	// === Bootstrap ===
	// Server bootstrapping from a tar archive containing worlds, plugins,
	// mods, and/or config files. Runs as an init container before the server starts.
	//
	// REQUIRED archive layout — directories must be at the ROOT of the archive
	// with no wrapper directory (all directories optional, but layout is mandatory):
	//
	//   worlds/             ← world directories, each containing level.dat
	//   ├── world/
	//   ├── world_nether/
	//   └── world_the_end/
	//   plugins/            ← plugin jars and config dirs
	//   mods/               ← mod jars
	//   config/             ← server config files
	//
	// Correct way to create the archive (from inside the server-data directory):
	//   tar -cJf bootstrap.tar.xz worlds/ plugins/ mods/ config/
	//   tar -czf bootstrap.tar.gz worlds/ plugins/ mods/ config/
	//
	// DO NOT wrap in a subdirectory:
	//   tar -cJf bootstrap.tar.xz my-server/   ← WRONG, breaks extraction
	//
	// Supported formats: .tar.gz, .tar.xz, .tar.bz2, .tar.zst
	//
	// The init container always re-downloads and re-stages plugins/mods/config on
	// every pod start (emptyDir volumes are ephemeral). Worlds are only copied when
	// they don't already exist in /data, ensuring existing player progress is safe.
	//
	// Composes cleanly with Modrinth/CurseForge modpack auto-download:
	// bootstrap provides the state (worlds, plugin configs), the registry
	// provides the code (mod/plugin jars).
	bootstrap?: {
		// URL to the archive. Supported formats: .tar.gz .tar.xz .tar.bz2 .tar.zst
		url: string

		// Image for the bootstrap init container.
		// Must provide: sh, curl, tar (with xz support), find, cp.
		// Defaults to the same itzg/minecraft-server image as the server container
		// so no apk/apt installs are needed and uid matches the pod security context.
		image: schemas.#Image & {
			repository: string | *"itzg/minecraft-server"
			tag:        string | *"java21"
			digest:     string | *""
		}

		// Force overwrite existing worlds in /data.
		// Default false: existing worlds are never overwritten (player progress safe).
		// Set true for intentional resets or disaster recovery.
		force: bool | *false

		// Controls itzg's SYNC_SKIP_NEWER_IN_DESTINATION for staged plugins/mods/config.
		// true (default): files already newer in /data are preserved (server changes safe).
		// false: archive files always overwrite destination.
		skipNewerInDestination: bool | *true
	}

	// === Networking ===
	port:        _#portSchema | *25565
	serviceType: *"ClusterIP" | "LoadBalancer" | "NodePort"

	extraPorts?: [...{
		name:          string
		containerPort: _#portSchema
		protocol:      *"TCP" | "UDP" | "SCTP"
		expose:        bool | *false
		exposedPort?:  _#portSchema
	}]

	// Additional hostnames the router maps to this server.
	// Each alias produces an extra --mapping arg pointing to the same
	// backend as the primary {serverName}.{domain} mapping.
	// Example: ["vanilla.larnet.eu", "mc.larnet.eu"]
	aliases?: [...string]

	// === Storage ===
	storage: {
		data: {
			type: *"pvc" | "hostPath" | "emptyDir" | "nfs" | "cifs"
			// pvc fields
			size:          string | *"10Gi"
			storageClass?: string
			// hostPath fields
			path?:         string
			hostPathType?: "Directory" | "DirectoryOrCreate"
			// nfs fields
			nfsServer?: string // NFS server hostname or IP (e.g. "10.10.0.2")
			nfsPath?:   string // Exported NFS path (e.g. "/mnt/data/minecraft")
			// cifs fields (requires smb.csi.k8s.io driver on cluster)
			cifsSource?:    string // UNC path (e.g. "//10.10.0.2/minecraft")
			cifsSecretRef?: string // K8s Secret name with keys: username, password
		}
		backups: {
			type: *"pvc" | "hostPath" | "emptyDir" | "nfs" | "cifs"
			// pvc fields
			size:          string | *"10Gi"
			storageClass?: string
			// hostPath fields
			path?:         string
			hostPathType?: "Directory" | "DirectoryOrCreate"
			// nfs fields
			nfsServer?: string
			nfsPath?:   string
			// cifs fields
			cifsSource?:    string
			cifsSecretRef?: string
		}
	}

	// === Backup ===
	backup: {
		enabled: bool | *false
		image: schemas.#Image & {
			repository: string | *"itzg/mc-backup"
			tag:        string | *"latest"
			digest:     string | *""
		}
		method:           *"tar" | "rsync" | "restic" | "rclone"
		interval:         string | *"24h"
		initialDelay:     string | *"5m"
		pruneBackupsDays: uint | *7
		pauseIfNoPlayers: bool | *true

		// Optional backup archive name (BACKUP_NAME)
		backupName?: string

		// Paths to exclude from backups, relative to SRC_DIR (EXCLUDES, comma-joined)
		// Example: ["./bluemap/*", "./plugins/CoreProtect/*"]
		excludes?: [...string]

		tar?: {
			compressMethod:      "gzip" | "bzip2" | "lzip" | "lzma" | "lzop" | *"xz" | "zstd"
			compressParameters?: string
			linkLatest:          bool | *false
		}
		rsync?: {
			linkLatest: bool | *false
			// When true, a backup volume (PVC/hostPath/emptyDir) is provisioned
			// for rsync to stage archives locally before syncing to the remote.
			useLocalStorage: bool | *false
		}
		restic?: {
			repository: string
			password: schemas.#Secret & {
				$secretName: "backup-secrets-\(name)"
				$dataKey:    "restic-password"
			}
			// S3-compatible storage credentials (e.g. SeaweedFS, MinIO, AWS S3).
			// Maps to AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY env vars.
			accessKey?: schemas.#Secret & {
				$secretName: "backup-secrets-\(name)"
				$dataKey:    "restic-s3-access-key"
			}
			secretKey?: schemas.#Secret & {
				$secretName: "backup-secrets-\(name)"
				$dataKey:    "restic-s3-secret-key"
			}
			retention?:      string
			hostname?:       string
			verbose?:        bool
			additionalTags?: string
			limitUpload?:    uint
			retryLock?:      string
		}
		rclone?: {
			remote:         string
			destDir:        string
			compressMethod: "gzip" | "bzip2" | "lzip" | "lzma" | "lzop" | "xz" | "zstd"
		}

		if enabled {
			matchN(1, [
				{tar!: _},
				{rsync!: _},
				{restic!: _},
				{rclone!: _},
			])
		}
	}

	// === Monitor Sidecar ===
	monitor: {
		enabled: bool | *true
		image: schemas.#Image & {
			repository: string | *"itzg/mc-monitor"
			tag:        string | *"0.16.1"
			digest:     string | *""
		}
		port:       uint & >0 & <=65535 | *8080
		timeout:    string | *"1m0s"
		serverHost: string | *"localhost"
	}

	// === Resource Limits ===
	resources?: schemas.#ResourceRequirementsSchema

	// === Security Context ===
	securityContext?: schemas.#SecurityContextSchema
}

// Module config schema
#config: {
	// === Routing Identity ===

	// Must match the ModuleRelease metadata.name exactly.
	// Used to compute K8s Service DNS names:
	//   {releaseName}-server-{serverName}.{namespace}.svc
	releaseName: string

	// Base domain for all server hostnames.
	// Each server is accessible at {serverName}.{domain}.
	// Example: domain: "mc.example.com" → lobby.mc.example.com
	domain: string

	// Kubernetes namespace for all components
	namespace: string

	// === Server Fleet ===
	// Each entry produces one Minecraft server + auto-wires it into the router.
	// Key = server name (e.g. "lobby", "survival"). Must be a valid DNS label.
	servers: [sName=string]: _#config & {name: sName}

	// === Router Configuration ===
	router: {
		// Container image for mc-router
		image: schemas.#Image & {
			repository: string | *"itzg/mc-router"
			tag:        string | *"1.40.3"
			digest:     string | *""
		}

		// Minecraft listening port on the router Service
		port: _#portSchema | *25565

		// Service type for the router (typically LoadBalancer for public access)
		serviceType: *"LoadBalancer" | "ClusterIP" | "NodePort"

		// Maximum connection rate per second
		connectionRateLimit: int & >0 | *1

		// Enable debug logging
		debug: bool | *false

		// Simplify SRV record lookup
		simplifySrv: bool | *false

		// Enable PROXY protocol for downstream servers
		useProxyProtocol: bool | *false

		// Default server when no hostname matches (optional)
		defaultServer?: {
			host: string
			port: _#portSchema
		}

		// Auto-scale configuration (wake/sleep StatefulSets on player connect/disconnect)
		autoScale?: {
			up?: {
				enabled: bool
			}
			down?: {
				enabled: bool
				after?:  string
			}
		}

		// Metrics backend configuration
		metrics?: {
			backend: "discard" | "expvar" | "influxdb" | "prometheus"
		}

		// REST API configuration
		api: {
			enabled: bool | *false
			port:    _#portSchema | *8080
		}

		// Resource limits for the router container
		resources?: schemas.#ResourceRequirementsSchema
	}

	// === Shared RCON Secret ===
	// Shared across all Minecraft server instances in the fleet.
	rconPassword: schemas.#Secret & {
		$secretName: "server-secrets"
		$dataKey:    "rcon-password"
	}

	// === Code Server ===
	// Optional single web-based editor (VS Code in the browser) that mounts
	// all server data volumes at /servers/{name} for direct file access.
	//
	// Works best with hostPath storage — the code-server pod shares the same
	// host paths as the server pods without PVC ownership conflicts.
	// For pvc storage, code-server gets a separate (empty) PVC per server —
	// data will NOT be shared with the running server.
	codeServer?: {
		enabled: bool | *false
		image: schemas.#Image & {
			repository: string | *"codercom/code-server"
			tag:        string | *"latest"
			digest:     string | *""
		}
		port:        _#portSchema | *8080
		serviceType: *"ClusterIP" | "LoadBalancer" | "NodePort"
		password?: schemas.#Secret & {
			$secretName: "code-server-secrets"
			$dataKey:    "password"
		}
		// Home directory storage — persists extensions, settings, and workspace
		// across pod restarts.
		storage: {
			home: {
				type:          *"pvc" | "hostPath" | "emptyDir"
				size:          string | *"1Gi"
				storageClass?: string
				path?:         string
				hostPathType?: "Directory" | "DirectoryOrCreate"
			}
		}
		resources?: schemas.#ResourceRequirementsSchema
	}

	// === Restic GUI ===
	// Optional Backrest web UI (https://github.com/garethgeorge/backrest) for
	// browsing and restoring restic snapshots created by the backup sidecars.
	//
	// Config is generated entirely in CUE and stored as an immutable K8s Secret
	// (one repo pre-configured per server that has backup.restic set). The Secret
	// is content-hash named so any config change triggers a new Secret and a pod
	// rollout — no init container, no stale config.json on a PVC.
	//
	// Prune and check schedules are disabled in the pre-configured repos because
	// the itzg/mc-backup sidecar already owns the backup schedule. Backrest is
	// used purely for browsing and restoring.
	//
	// Password: provide a pre-computed bcrypt hash (cost 10, $2a$ prefix).
	// Generate with: htpasswd -bnBC 10 "" "yourpassword" | tr -d ':\n' | sed 's/$2y/$2a/'
	//
	// Storage: a single PVC (or hostPath/emptyDir) holds Backrest internal state
	// and the restic cache under /data. Config is mounted read-only from the Secret.
	resticGui?: {
		enabled: bool | *false
		image: schemas.#Image & {
			repository: string | *"ghcr.io/garethgeorge/backrest"
			tag:        string | *"latest"
			digest:     string | *""
		}
		port:        _#portSchema | *9898
		serviceType: *"ClusterIP" | "LoadBalancer" | "NodePort"
		// Username for the Backrest web UI.
		username: string | *"admin"
		// Base64-encoded bcrypt hash of the Backrest web UI password.
		// Backrest decodes the stored value as base64 before bcrypt comparison.
		// Generate with: htpasswd -bnBC 10 "" "yourpassword" | tr -d ':\n' | sed 's/$2y/$2a/' | base64 | tr -d '\n'
		passwordBcryptHash: string
		// Pre-generated ECDSA P-256 identity for Backrest's internal multihost feature.
		// Required to prevent Backrest from writing config.json.bak.* on startup,
		// which fails when the config is mounted read-only from a K8s Secret.
		// Without this, PopulateRequiredFields mutates the config → triggers Update()
		// → makeBackup() → write fails on read-only mount.
		//
		// Generate once with:
		//   go run github.com/garethgeorge/backrest/cmd/backrest@latest gen-key
		// Or use the helper script in the module tools directory.
		multihostIdentity: {
			keyId:   string // "ecdsa.<base64url(sha256(X+Y))>"
			privKey: string // PEM "EC PRIVATE" (SEC1/x509.MarshalECPrivateKey)
			pubKey:  string // PEM "EC PUBLIC"  (SPKI/x509.MarshalPKIXPublicKey)
		}
		resources?: schemas.#ResourceRequirementsSchema
	}
}

// debugValues exercises the full #config surface for local cue vet / cue eval.
debugValues: {
	releaseName: "my-fleet"
	domain:      "mc.example.com"
	namespace:   "minecraft"

	servers: {
		lobby: {
			server: {
				motd:       "Welcome to the Lobby!"
				maxPlayers: 50
				mode:       "adventure"
				pvp:        false
				difficulty: "peaceful"
			}
			paper: {}
			jvm: memory:    "1G"
			bootstrap: url: "https://example.com/bootstrap/lobby.tar.gz"
		}
		survival: {
			server: {
				maxPlayers: 20
				difficulty: "hard"
			}
			fabric: {
				loaderVersion: "0.15.11"
				mods: {
					modrinth: {
						projects: ["lithium", "starlight"]
					}
				}
			}
			jvm: maxMemory: "4G"
			backup: {
				enabled: true
				method:  "tar"
				tar: {}
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

	rconPassword: value: "debug-rcon-password"

	codeServer: {
		enabled:     true
		port:        8080
		serviceType: "ClusterIP"
		storage: home: {
			type: "pvc"
			size: "1Gi"
		}
	}

	resticGui: {
		enabled:            true
		port:               9898
		serviceType:        "ClusterIP"
		username:           "admin"
		passwordBcryptHash: "$2a$10$debugHashForCueVetOnlyNotRealxxxxxxxxxxxxxxxxxxxxxO"
		multihostIdentity: {
			keyId:   "ecdsa.debugKeyIdForCueVetOnlyNotReal"
			privKey: "-----BEGIN EC PRIVATE-----\ndebug\n-----END EC PRIVATE-----\n"
			pubKey:  "-----BEGIN EC PUBLIC-----\ndebug\n-----END EC PUBLIC-----\n"
		}
	}
}
