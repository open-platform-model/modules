// Components defines the Minecraft Java server fleet workload.
//
// Dynamic component generation:
//   - One `server-{name}` component per entry in #config.servers
//     (StatefulSet + Service, identical structure to mc_java)
//   - One `router` component (stateless mc-router Deployment + LoadBalancer Service)
//     with --mapping args auto-built from the servers map
//   - One `rbac` component granting mc-router K8s service discovery permissions
//
// Router --mapping arg format:
//   -mapping={name}.{domain}={releaseName}-server-{name}.{namespace}.svc:{port}
package mc_java_fleet

import (
	"encoding/json"
	"list"
	"strings"

	resources_workload "opmodel.dev/opm/v1alpha1/resources/workload@v1"
	resources_storage "opmodel.dev/opm/v1alpha1/resources/storage@v1"
	resources_config "opmodel.dev/opm/v1alpha1/resources/config@v1"
	resources_security "opmodel.dev/opm/v1alpha1/resources/security@v1"
	traits_workload "opmodel.dev/opm/v1alpha1/traits/workload@v1"
	traits_network "opmodel.dev/opm/v1alpha1/traits/network@v1"
	traits_security "opmodel.dev/opm/v1alpha1/traits/security@v1"
)

// #components contains component definitions.
// Components reference #config which gets resolved to concrete values at build time.
#components: {

	// Pre-computed shared bindings to avoid repeating #config.xxx in every comprehension
	// and ensure string interpolation has concrete values.
	let _domain = #config.domain
	let _relName = #config.releaseName
	let _ns = #config.namespace
	let _routerName = "\(_relName)-router"

	// ── Dynamic Minecraft server components ──────────────────────────────────────
	// One StatefulSet + Service per entry in #config.servers.
	// Component name: server-{name}  →  K8s Service: {releaseName}-server-{name}
	for _srvName, _srvCfg in #config.servers {
		let _c = _srvCfg

		"server-\(_srvName)": {
			resources_workload.#Container
			resources_storage.#Volumes
			if _c.bootstrap != _|_ {
				traits_workload.#InitContainers
			}
			if _c.backup.enabled || _c.monitor.enabled {
				traits_workload.#SidecarContainers
			}
			traits_workload.#Scaling
			traits_workload.#RestartPolicy
			traits_workload.#UpdateStrategy
			traits_workload.#GracefulShutdown
			traits_network.#Expose
			traits_security.#SecurityContext

			metadata: labels: "core.opmodel.dev/workload-type": "stateful"

			spec: {
				// Single replica when enabled; zero replicas when disabled (server stopped).
				if _c.enabled {
					scaling: count: 1
				}
				if !_c.enabled {
					scaling: count: 0
				}

				restartPolicy: "Always"

				// Recreate strategy — Minecraft cannot do rolling updates
				updateStrategy: type: "Recreate"

				// Graceful shutdown — allow time for world save
				gracefulShutdown: terminationGracePeriodSeconds: 60

				// === Bootstrap Init Container ===
				// Only injected when bootstrap.url is set.
				//
				// Runs on every pod start (emptyDir staging volumes reset on pod recreation).
				// Downloads the archive and:
				//   worlds/*  → copied into /data (skips existing, unless FORCE=true)
				//   plugins/* → staged at /staging/plugins (itzg syncs to /data/plugins)
				//   mods/*    → staged at /staging/mods    (itzg syncs to /data/mods)
				//   config/*  → staged at /staging/config  (itzg syncs to /data/config)
				if _c.bootstrap != _|_ {
					initContainers: [{
						name:  "bootstrap"
						image: _c.bootstrap.image
						command: ["python3", "-c"]
						args: ["""
							import os, sys, shutil, tarfile, urllib.request

							url   = os.environ["BOOTSTRAP_URL"]
							force = os.environ.get("FORCE", "false").lower() == "true"
							tmp   = "/tmp/_bootstrap"
							arc   = "/tmp/_bootstrap.archive"

							os.makedirs(tmp, exist_ok=True)

							print(f"Downloading bootstrap archive from {url} ...", flush=True)
							urllib.request.urlretrieve(url, arc)

							print("Extracting archive...", flush=True)
							with tarfile.open(arc) as tf:
							    tf.extractall(tmp)
							os.remove(arc)

							# --- Worlds: copy level.dat-bearing dirs into /data ---
							worlds_src = os.path.join(tmp, "worlds")
							if os.path.isdir(worlds_src):
							    print("Scanning for world directories...", flush=True)
							    for entry in os.scandir(worlds_src):
							        if not entry.is_dir():
							            continue
							        level_dat = os.path.join(entry.path, "level.dat")
							        if not os.path.exists(level_dat):
							            continue
							        dest = os.path.join("/data", entry.name)
							        if os.path.isdir(dest) and not force:
							            print(f"  Skip world {entry.name}: already exists in /data", flush=True)
							        else:
							            print(f"  Seeding world: {entry.name}", flush=True)
							            if os.path.exists(dest):
							                shutil.rmtree(dest)
							            shutil.copytree(entry.path, dest)

							# --- Plugins, mods, config: always stage into emptyDirs ---
							for cat in ("plugins", "mods", "config"):
							    src = os.path.join(tmp, cat)
							    dst = f"/staging/{cat}"
							    if os.path.isdir(src):
							        items = os.listdir(src)
							        print(f"Staging {cat} ({len(items)} items)...", flush=True)
							        for item in items:
							            s = os.path.join(src, item)
							            d = os.path.join(dst, item)
							            if os.path.isdir(s):
							                shutil.copytree(s, d, dirs_exist_ok=True)
							            else:
							                shutil.copy2(s, d)

							shutil.rmtree(tmp)
							print("Bootstrap complete.", flush=True)
							"""]
						env: {
							BOOTSTRAP_URL: {
								name:  "BOOTSTRAP_URL"
								value: _c.bootstrap.url
							}
							FORCE: {
								name:  "FORCE"
								value: "\(_c.bootstrap.force)"
							}
						}
						volumeMounts: {
							data: volumes.data & {
								mountPath: "/data"
							}
							"staging-plugins": volumes["staging-plugins"] & {
								mountPath: "/staging/plugins"
							}
							"staging-mods": volumes["staging-mods"] & {
								mountPath: "/staging/mods"
							}
							"staging-config": volumes["staging-config"] & {
								mountPath: "/staging/config"
							}
						}
					}]
				}

				// === Security Context ===
				if _c.securityContext != _|_ {
					securityContext: _c.securityContext
				}
			if _c.securityContext == _|_ {
				securityContext: {
					runAsNonRoot:             true
					runAsUser:                1000
					runAsGroup:               3000
					fsGroup:                  3000
					readOnlyRootFilesystem:   true
					allowPrivilegeEscalation: false
					capabilities: drop: ["ALL"]
				}
			}

				// === Main Container: Minecraft Server ===
				container: {
					name:  "server"
					image: _c.image

					ports: {
						minecraft: {
							targetPort: 25565
							protocol:   "TCP"
						}
						if _c.rcon.enabled {
							rcon: {
								name:       "rcon"
								targetPort: _c.rcon.port
								protocol:   "TCP"
							}
						}
						if _c.query.enabled {
							query: {
								name:       "query"
								targetPort: _c.query.port
								protocol:   "TCP"
							}
						}
						if _c.extraPorts != _|_ {
							for _extraPort in _c.extraPorts {
								"\(_extraPort.name)": {
									name:       _extraPort.name
									targetPort: _extraPort.containerPort
									protocol:   _extraPort.protocol
								}
							}
						}
					}

					env: {
						EULA: {
							name:  "EULA"
							value: "\(_c.eula)"
						}

						// === Server Type ===
						if _c.vanilla != _|_ {
							TYPE: {name: "TYPE", value: "VANILLA"}
						}
						if _c.paper != _|_ {
							TYPE: {name: "TYPE", value: "PAPER"}
						}
						if _c.forge != _|_ {
							TYPE: {name: "TYPE", value: "FORGE"}
						}
						if _c.fabric != _|_ {
							TYPE: {name: "TYPE", value: "FABRIC"}
						}
						if _c.spigot != _|_ {
							TYPE: {name: "TYPE", value: "SPIGOT"}
						}
						if _c.bukkit != _|_ {
							TYPE: {name: "TYPE", value: "BUKKIT"}
						}
						if _c.sponge != _|_ {
							TYPE: {name: "TYPE", value: "SPONGEVANILLA"}
						}
						if _c.purpur != _|_ {
							TYPE: {name: "TYPE", value: "PURPUR"}
						}
						if _c.magma != _|_ {
							TYPE: {name: "TYPE", value: "MAGMA"}
						}
						if _c.ftba != _|_ {
							TYPE: {name: "TYPE", value: "FTBA"}
						}
						if _c.autoCurseForge != _|_ {
							TYPE: {name: "TYPE", value: "AUTO_CURSEFORGE"}
						}
						if _c.modrinth != _|_ {
							TYPE: {name: "TYPE", value: "MODRINTH"}
						}

						VERSION: {
							name:  "VERSION"
							value: _c.version
						}

						// === Server Properties ===
						MAX_PLAYERS: {
							name:  "MAX_PLAYERS"
							value: "\(_c.server.maxPlayers)"
						}
						DIFFICULTY: {
							name:  "DIFFICULTY"
							value: _c.server.difficulty
						}
						MODE: {
							name:  "MODE"
							value: _c.server.mode
						}
						PVP: {
							name:  "PVP"
							value: "\(_c.server.pvp)"
						}
						ENABLE_COMMAND_BLOCK: {
							name:  "ENABLE_COMMAND_BLOCK"
							value: "\(_c.server.enableCommandBlock)"
						}

						if _c.rcon.enabled {
							ENABLE_RCON: {
								name:  "ENABLE_RCON"
								value: "true"
							}
							// Shared RCON password injected from module-level config
							RCON_PASSWORD: {
								name: "RCON_PASSWORD"
								from: #config.rconPassword
							}
							RCON_PORT: {
								name:  "RCON_PORT"
								value: "\(_c.rcon.port)"
							}
						}

						if _c.server.motd != _|_ {
							MOTD: {
								name:  "MOTD"
								value: _c.server.motd
							}
						}
						if _c.server.ops != _|_ {
							OPS: {
								name:  "OPS"
								value: strings.Join(_c.server.ops, ",")
							}
						}
						if _c.server.blocklist != _|_ {
							WHITELIST: {
								name:  "WHITELIST"
								value: strings.Join(_c.server.blocklist, ",")
							}
						}
						if _c.server.seed != _|_ {
							SEED: {
								name:  "SEED"
								value: _c.server.seed
							}
						}
						if _c.server.maxWorldSize != _|_ {
							MAX_WORLD_SIZE: {
								name:  "MAX_WORLD_SIZE"
								value: "\(_c.server.maxWorldSize)"
							}
						}
						VIEW_DISTANCE: {
							name:  "VIEW_DISTANCE"
							value: "\(_c.server.viewDistance)"
						}
						ALLOW_NETHER: {
							name:  "ALLOW_NETHER"
							value: "\(_c.server.allowNether)"
						}
						ALLOW_FLIGHT: {
							name:  "ALLOW_FLIGHT"
							value: "\(_c.server.allowFlight)"
						}
						ENABLE_ROLLING_LOGS: {
							name:  "ENABLE_ROLLING_LOGS"
							value: "\(_c.server.enableRollingLogs)"
						}
						if _c.server.serverName != _|_ {
							SERVER_NAME: {
								name:  "SERVER_NAME"
								value: _c.server.serverName
							}
						}
						if _c.server.tz != _|_ {
							TZ: {
								name:  "TZ"
								value: _c.server.tz
							}
						}
						ANNOUNCE_PLAYER_ACHIEVEMENTS: {
							name:  "ANNOUNCE_PLAYER_ACHIEVEMENTS"
							value: "\(_c.server.announcePlayerAchievements)"
						}
						FORCE_GAMEMODE: {
							name:  "FORCE_GAMEMODE"
							value: "\(_c.server.forceGameMode)"
						}
						GENERATE_STRUCTURES: {
							name:  "GENERATE_STRUCTURES"
							value: "\(_c.server.generateStructures)"
						}
						HARDCORE: {
							name:  "HARDCORE"
							value: "\(_c.server.hardcore)"
						}
						MAX_BUILD_HEIGHT: {
							name:  "MAX_BUILD_HEIGHT"
							value: "\(_c.server.maxBuildHeight)"
						}
						MAX_TICK_TIME: {
							name:  "MAX_TICK_TIME"
							value: "\(_c.server.maxTickTime)"
						}
						SPAWN_ANIMALS: {
							name:  "SPAWN_ANIMALS"
							value: "\(_c.server.spawnAnimals)"
						}
						SPAWN_MONSTERS: {
							name:  "SPAWN_MONSTERS"
							value: "\(_c.server.spawnMonsters)"
						}
						SPAWN_NPCS: {
							name:  "SPAWN_NPCS"
							value: "\(_c.server.spawnNPCs)"
						}
						SPAWN_PROTECTION: {
							name:  "SPAWN_PROTECTION"
							value: "\(_c.server.spawnProtection)"
						}
						LEVEL_TYPE: {
							name:  "LEVEL_TYPE"
							value: _c.server.levelType
						}
						LEVEL: {
							name:  "LEVEL"
							value: _c.server.worldSaveName
						}
						ONLINE_MODE: {
							name:  "ONLINE_MODE"
							value: "\(_c.server.onlineMode)"
						}
						ENFORCE_SECURE_PROFILE: {
							name:  "ENFORCE_SECURE_PROFILE"
							value: "\(_c.server.enforceSecureProfile)"
						}
						OVERRIDE_SERVER_PROPERTIES: {
							name:  "OVERRIDE_SERVER_PROPERTIES"
							value: "\(_c.server.overrideServerProperties)"
						}

						// === JVM ===
						// When maxMemory is set it becomes MEMORY; initMemory becomes INIT_MEMORY.
						// When only memory is set it becomes MEMORY (single heap).
						if _c.jvm.maxMemory != _|_ {
							MEMORY: {
								name:  "MEMORY"
								value: _c.jvm.maxMemory
							}
							if _c.jvm.initMemory != _|_ {
								INIT_MEMORY: {
									name:  "INIT_MEMORY"
									value: _c.jvm.initMemory
								}
							}
						}
						if _c.jvm.maxMemory == _|_ {
							MEMORY: {
								name:  "MEMORY"
								value: _c.jvm.memory
							}
						}
						if _c.jvm.opts != _|_ {
							JVM_OPTS: {
								name:  "JVM_OPTS"
								value: _c.jvm.opts
							}
						}
						if _c.jvm.xxOpts != _|_ {
							JVM_XX_OPTS: {
								name:  "JVM_XX_OPTS"
								value: _c.jvm.xxOpts
							}
						}
						if _c.jvm.useAikarFlags {
							USE_AIKAR_FLAGS: {
								name:  "USE_AIKAR_FLAGS"
								value: "true"
							}
						}

						// === Type-Specific ===
						if _c.forge != _|_ {
							FORGE_VERSION: {
								name:  "FORGE_VERSION"
								value: _c.forge.version
							}
							if _c.forge.installerUrl != _|_ {
								FORGE_INSTALLER_URL: {
									name:  "FORGE_INSTALLER_URL"
									value: _c.forge.installerUrl
								}
							}
							if _c.forge.mods != _|_ {
								if _c.forge.mods.urls != _|_ {
									MODS: {
										name:  "MODS"
										value: strings.Join(_c.forge.mods.urls, ",")
									}
								}
								if _c.forge.mods.modrinth != _|_ {
									MODRINTH_PROJECTS: {
										name:  "MODRINTH_PROJECTS"
										value: strings.Join(_c.forge.mods.modrinth.projects, ",")
									}
									if _c.forge.mods.modrinth.downloadDependencies != _|_ {
										MODRINTH_DOWNLOAD_DEPENDENCIES: {
											name:  "MODRINTH_DOWNLOAD_DEPENDENCIES"
											value: _c.forge.mods.modrinth.downloadDependencies
										}
									}
									if _c.forge.mods.modrinth.allowedVersionType != _|_ {
										MODRINTH_ALLOWED_VERSION_TYPE: {
											name:  "MODRINTH_ALLOWED_VERSION_TYPE"
											value: _c.forge.mods.modrinth.allowedVersionType
										}
									}
								}
								if _c.forge.mods.modpackUrl != _|_ {
									MODPACK: {
										name:  "MODPACK"
										value: _c.forge.mods.modpackUrl
									}
								}
								REMOVE_OLD_MODS: {
									name:  "REMOVE_OLD_MODS"
									value: "\(_c.forge.mods.removeOldMods)"
								}
							}
						}
						if _c.fabric != _|_ {
							FABRIC_LOADER_VERSION: {
								name:  "FABRIC_LOADER_VERSION"
								value: _c.fabric.loaderVersion
							}
							if _c.fabric.installerUrl != _|_ {
								FABRIC_INSTALLER_URL: {
									name:  "FABRIC_INSTALLER_URL"
									value: _c.fabric.installerUrl
								}
							}
							if _c.fabric.mods != _|_ {
								if _c.fabric.mods.urls != _|_ {
									MODS: {
										name:  "MODS"
										value: strings.Join(_c.fabric.mods.urls, ",")
									}
								}
								if _c.fabric.mods.modrinth != _|_ {
									MODRINTH_PROJECTS: {
										name:  "MODRINTH_PROJECTS"
										value: strings.Join(_c.fabric.mods.modrinth.projects, ",")
									}
									if _c.fabric.mods.modrinth.downloadDependencies != _|_ {
										MODRINTH_DOWNLOAD_DEPENDENCIES: {
											name:  "MODRINTH_DOWNLOAD_DEPENDENCIES"
											value: _c.fabric.mods.modrinth.downloadDependencies
										}
									}
									if _c.fabric.mods.modrinth.allowedVersionType != _|_ {
										MODRINTH_ALLOWED_VERSION_TYPE: {
											name:  "MODRINTH_ALLOWED_VERSION_TYPE"
											value: _c.fabric.mods.modrinth.allowedVersionType
										}
									}
								}
								if _c.fabric.mods.modpackUrl != _|_ {
									MODPACK: {
										name:  "MODPACK"
										value: _c.fabric.mods.modpackUrl
									}
								}
								REMOVE_OLD_MODS: {
									name:  "REMOVE_OLD_MODS"
									value: "\(_c.fabric.mods.removeOldMods)"
								}
							}
						}
						if _c.paper != _|_ {
							if _c.paper.downloadUrl != _|_ {
								PAPER_DOWNLOAD_URL: {
									name:  "PAPER_DOWNLOAD_URL"
									value: _c.paper.downloadUrl
								}
							}
							if _c.paper.build != _|_ {
								PAPER_BUILD: {
									name:  "PAPER_BUILD"
									value: "\(_c.paper.build)"
								}
							}
							if _c.paper.channel != _|_ {
								PAPER_CHANNEL: {
									name:  "PAPER_CHANNEL"
									value: _c.paper.channel
								}
							}
							if _c.paper.configRepo != _|_ {
								PAPER_CONFIG_REPO: {
									name:  "PAPER_CONFIG_REPO"
									value: _c.paper.configRepo
								}
							}
							if _c.paper.skipDownloadDefaults != _|_ {
								if _c.paper.skipDownloadDefaults {
									SKIP_DOWNLOAD_DEFAULTS: {
										name:  "SKIP_DOWNLOAD_DEFAULTS"
										value: "true"
									}
								}
							}
							if _c.paper.plugins != _|_ {
								if _c.paper.plugins.urls != _|_ {
									PLUGINS: {
										name:  "PLUGINS"
										value: strings.Join(_c.paper.plugins.urls, ",")
									}
								}
								if _c.paper.plugins.spigetResources != _|_ {
									let _spigetStrings = [for r in _c.paper.plugins.spigetResources {"\(r)"}]
									SPIGET_RESOURCES: {
										name:  "SPIGET_RESOURCES"
										value: strings.Join(_spigetStrings, ",")
									}
								}
								if _c.paper.plugins.modrinth != _|_ {
									MODRINTH_PROJECTS: {
										name:  "MODRINTH_PROJECTS"
										value: strings.Join(_c.paper.plugins.modrinth.projects, ",")
									}
									if _c.paper.plugins.modrinth.downloadDependencies != _|_ {
										MODRINTH_DOWNLOAD_DEPENDENCIES: {
											name:  "MODRINTH_DOWNLOAD_DEPENDENCIES"
											value: _c.paper.plugins.modrinth.downloadDependencies
										}
									}
									if _c.paper.plugins.modrinth.allowedVersionType != _|_ {
										MODRINTH_ALLOWED_VERSION_TYPE: {
											name:  "MODRINTH_ALLOWED_VERSION_TYPE"
											value: _c.paper.plugins.modrinth.allowedVersionType
										}
									}
								}
								if _c.paper.plugins.modpackUrl != _|_ {
									MODPACK: {
										name:  "MODPACK"
										value: _c.paper.plugins.modpackUrl
									}
								}
								REMOVE_OLD_MODS: {
									name:  "REMOVE_OLD_MODS"
									value: "\(_c.paper.plugins.removeOldMods)"
								}
							}
						}
						if _c.spigot != _|_ {
							if _c.spigot.downloadUrl != _|_ {
								SPIGOT_DOWNLOAD_URL: {
									name:  "SPIGOT_DOWNLOAD_URL"
									value: _c.spigot.downloadUrl
								}
							}
							if _c.spigot.plugins != _|_ {
								if _c.spigot.plugins.urls != _|_ {
									PLUGINS: {
										name:  "PLUGINS"
										value: strings.Join(_c.spigot.plugins.urls, ",")
									}
								}
								if _c.spigot.plugins.spigetResources != _|_ {
									let _spigetStrings = [for r in _c.spigot.plugins.spigetResources {"\(r)"}]
									SPIGET_RESOURCES: {
										name:  "SPIGET_RESOURCES"
										value: strings.Join(_spigetStrings, ",")
									}
								}
								if _c.spigot.plugins.modrinth != _|_ {
									MODRINTH_PROJECTS: {
										name:  "MODRINTH_PROJECTS"
										value: strings.Join(_c.spigot.plugins.modrinth.projects, ",")
									}
									if _c.spigot.plugins.modrinth.downloadDependencies != _|_ {
										MODRINTH_DOWNLOAD_DEPENDENCIES: {
											name:  "MODRINTH_DOWNLOAD_DEPENDENCIES"
											value: _c.spigot.plugins.modrinth.downloadDependencies
										}
									}
									if _c.spigot.plugins.modrinth.allowedVersionType != _|_ {
										MODRINTH_ALLOWED_VERSION_TYPE: {
											name:  "MODRINTH_ALLOWED_VERSION_TYPE"
											value: _c.spigot.plugins.modrinth.allowedVersionType
										}
									}
								}
								if _c.spigot.plugins.modpackUrl != _|_ {
									MODPACK: {
										name:  "MODPACK"
										value: _c.spigot.plugins.modpackUrl
									}
								}
								REMOVE_OLD_MODS: {
									name:  "REMOVE_OLD_MODS"
									value: "\(_c.spigot.plugins.removeOldMods)"
								}
							}
						}
						if _c.bukkit != _|_ {
							if _c.bukkit.downloadUrl != _|_ {
								BUKKIT_DOWNLOAD_URL: {
									name:  "BUKKIT_DOWNLOAD_URL"
									value: _c.bukkit.downloadUrl
								}
							}
							if _c.bukkit.plugins != _|_ {
								if _c.bukkit.plugins.urls != _|_ {
									PLUGINS: {
										name:  "PLUGINS"
										value: strings.Join(_c.bukkit.plugins.urls, ",")
									}
								}
								if _c.bukkit.plugins.spigetResources != _|_ {
									let _spigetStrings = [for r in _c.bukkit.plugins.spigetResources {"\(r)"}]
									SPIGET_RESOURCES: {
										name:  "SPIGET_RESOURCES"
										value: strings.Join(_spigetStrings, ",")
									}
								}
								if _c.bukkit.plugins.modrinth != _|_ {
									MODRINTH_PROJECTS: {
										name:  "MODRINTH_PROJECTS"
										value: strings.Join(_c.bukkit.plugins.modrinth.projects, ",")
									}
									if _c.bukkit.plugins.modrinth.downloadDependencies != _|_ {
										MODRINTH_DOWNLOAD_DEPENDENCIES: {
											name:  "MODRINTH_DOWNLOAD_DEPENDENCIES"
											value: _c.bukkit.plugins.modrinth.downloadDependencies
										}
									}
									if _c.bukkit.plugins.modrinth.allowedVersionType != _|_ {
										MODRINTH_ALLOWED_VERSION_TYPE: {
											name:  "MODRINTH_ALLOWED_VERSION_TYPE"
											value: _c.bukkit.plugins.modrinth.allowedVersionType
										}
									}
								}
								if _c.bukkit.plugins.modpackUrl != _|_ {
									MODPACK: {
										name:  "MODPACK"
										value: _c.bukkit.plugins.modpackUrl
									}
								}
								REMOVE_OLD_MODS: {
									name:  "REMOVE_OLD_MODS"
									value: "\(_c.bukkit.plugins.removeOldMods)"
								}
							}
						}
						if _c.sponge != _|_ {
							SPONGEVERSION: {
								name:  "SPONGEVERSION"
								value: _c.sponge.version
							}
						}
						if _c.purpur != _|_ {
							if _c.purpur.build != _|_ {
								PURPUR_BUILD: {
									name:  "PURPUR_BUILD"
									value: "\(_c.purpur.build)"
								}
							}
							if _c.purpur.plugins != _|_ {
								if _c.purpur.plugins.urls != _|_ {
									PLUGINS: {
										name:  "PLUGINS"
										value: strings.Join(_c.purpur.plugins.urls, ",")
									}
								}
								if _c.purpur.plugins.spigetResources != _|_ {
									let _spigetStrings = [for r in _c.purpur.plugins.spigetResources {"\(r)"}]
									SPIGET_RESOURCES: {
										name:  "SPIGET_RESOURCES"
										value: strings.Join(_spigetStrings, ",")
									}
								}
								if _c.purpur.plugins.modrinth != _|_ {
									MODRINTH_PROJECTS: {
										name:  "MODRINTH_PROJECTS"
										value: strings.Join(_c.purpur.plugins.modrinth.projects, ",")
									}
									if _c.purpur.plugins.modrinth.downloadDependencies != _|_ {
										MODRINTH_DOWNLOAD_DEPENDENCIES: {
											name:  "MODRINTH_DOWNLOAD_DEPENDENCIES"
											value: _c.purpur.plugins.modrinth.downloadDependencies
										}
									}
									if _c.purpur.plugins.modrinth.allowedVersionType != _|_ {
										MODRINTH_ALLOWED_VERSION_TYPE: {
											name:  "MODRINTH_ALLOWED_VERSION_TYPE"
											value: _c.purpur.plugins.modrinth.allowedVersionType
										}
									}
								}
								if _c.purpur.plugins.modpackUrl != _|_ {
									MODPACK: {
										name:  "MODPACK"
										value: _c.purpur.plugins.modpackUrl
									}
								}
								REMOVE_OLD_MODS: {
									name:  "REMOVE_OLD_MODS"
									value: "\(_c.purpur.plugins.removeOldMods)"
								}
							}
						}
						if _c.magma != _|_ {
							if _c.magma.mods != _|_ {
								if _c.magma.mods.urls != _|_ {
									MODS: {
										name:  "MODS"
										value: strings.Join(_c.magma.mods.urls, ",")
									}
								}
								if _c.magma.mods.modrinth != _|_ {
									MODRINTH_PROJECTS: {
										name:  "MODRINTH_PROJECTS"
										value: strings.Join(_c.magma.mods.modrinth.projects, ",")
									}
									if _c.magma.mods.modrinth.downloadDependencies != _|_ {
										MODRINTH_DOWNLOAD_DEPENDENCIES: {
											name:  "MODRINTH_DOWNLOAD_DEPENDENCIES"
											value: _c.magma.mods.modrinth.downloadDependencies
										}
									}
									if _c.magma.mods.modrinth.allowedVersionType != _|_ {
										MODRINTH_ALLOWED_VERSION_TYPE: {
											name:  "MODRINTH_ALLOWED_VERSION_TYPE"
											value: _c.magma.mods.modrinth.allowedVersionType
										}
									}
								}
								if _c.magma.mods.modpackUrl != _|_ {
									MODPACK: {
										name:  "MODPACK"
										value: _c.magma.mods.modpackUrl
									}
								}
								REMOVE_OLD_MODS: {
									name:  "REMOVE_OLD_MODS"
									value: "\(_c.magma.mods.removeOldMods)"
								}
							}
							if _c.magma.plugins != _|_ {
								if _c.magma.plugins.urls != _|_ {
									PLUGINS: {
										name:  "PLUGINS"
										value: strings.Join(_c.magma.plugins.urls, ",")
									}
								}
								if _c.magma.plugins.spigetResources != _|_ {
									let _spigetStrings = [for r in _c.magma.plugins.spigetResources {"\(r)"}]
									SPIGET_RESOURCES: {
										name:  "SPIGET_RESOURCES"
										value: strings.Join(_spigetStrings, ",")
									}
								}
							}
						}
						if _c.ftba != _|_ {
							if _c.ftba.mods != _|_ {
								if _c.ftba.mods.urls != _|_ {
									MODS: {
										name:  "MODS"
										value: strings.Join(_c.ftba.mods.urls, ",")
									}
								}
								if _c.ftba.mods.modrinth != _|_ {
									MODRINTH_PROJECTS: {
										name:  "MODRINTH_PROJECTS"
										value: strings.Join(_c.ftba.mods.modrinth.projects, ",")
									}
									if _c.ftba.mods.modrinth.downloadDependencies != _|_ {
										MODRINTH_DOWNLOAD_DEPENDENCIES: {
											name:  "MODRINTH_DOWNLOAD_DEPENDENCIES"
											value: _c.ftba.mods.modrinth.downloadDependencies
										}
									}
									if _c.ftba.mods.modrinth.allowedVersionType != _|_ {
										MODRINTH_ALLOWED_VERSION_TYPE: {
											name:  "MODRINTH_ALLOWED_VERSION_TYPE"
											value: _c.ftba.mods.modrinth.allowedVersionType
										}
									}
								}
								if _c.ftba.mods.modpackUrl != _|_ {
									MODPACK: {
										name:  "MODPACK"
										value: _c.ftba.mods.modpackUrl
									}
								}
								REMOVE_OLD_MODS: {
									name:  "REMOVE_OLD_MODS"
									value: "\(_c.ftba.mods.removeOldMods)"
								}
							}
						}
						if _c.autoCurseForge != _|_ {
							CF_API_KEY: {
								name: "CF_API_KEY"
								from: _c.autoCurseForge.apiKey
							}
							if _c.autoCurseForge.pageUrl != _|_ {
								CF_PAGE_URL: {
									name:  "CF_PAGE_URL"
									value: _c.autoCurseForge.pageUrl
								}
							}
							if _c.autoCurseForge.slug != _|_ {
								CF_SLUG: {
									name:  "CF_SLUG"
									value: _c.autoCurseForge.slug
								}
							}
							if _c.autoCurseForge.fileId != _|_ {
								CF_FILE_ID: {
									name:  "CF_FILE_ID"
									value: _c.autoCurseForge.fileId
								}
							}
							if _c.autoCurseForge.filenameMatcher != _|_ {
								CF_FILENAME_MATCHER: {
									name:  "CF_FILENAME_MATCHER"
									value: _c.autoCurseForge.filenameMatcher
								}
							}
							if _c.autoCurseForge.forceSynchronize != _|_ {
								CF_FORCE_SYNCHRONIZE: {
									name:  "CF_FORCE_SYNCHRONIZE"
									value: "\(_c.autoCurseForge.forceSynchronize)"
								}
							}
							if _c.autoCurseForge.parallelDownloads != _|_ {
								CF_PARALLEL_DOWNLOADS: {
									name:  "CF_PARALLEL_DOWNLOADS"
									value: "\(_c.autoCurseForge.parallelDownloads)"
								}
							}
						}

						// === Modrinth Modpack ===
						if _c.modrinth != _|_ {
							MODRINTH_MODPACK: {
								name:  "MODRINTH_MODPACK"
								value: _c.modrinth.modpack
							}
							if _c.modrinth.version != _|_ {
								MODRINTH_VERSION: {
									name:  "MODRINTH_VERSION"
									value: _c.modrinth.version
								}
							}
							if _c.modrinth.projects != _|_ {
								MODRINTH_PROJECTS: {
									name:  "MODRINTH_PROJECTS"
									value: strings.Join(_c.modrinth.projects, ",")
								}
							}
							if _c.modrinth.downloadDependencies != _|_ {
								MODRINTH_DOWNLOAD_DEPENDENCIES: {
									name:  "MODRINTH_DOWNLOAD_DEPENDENCIES"
									value: _c.modrinth.downloadDependencies
								}
							}
						}

						// === Resource Packs ===
						if _c.server.resourcePackUrl != _|_ {
							RESOURCE_PACK: {
								name:  "RESOURCE_PACK"
								value: _c.server.resourcePackUrl
							}
						}
						if _c.server.resourcePackSha != _|_ {
							RESOURCE_PACK_SHA1: {
								name:  "RESOURCE_PACK_SHA1"
								value: _c.server.resourcePackSha
							}
						}
						if _c.server.resourcePackEnforce != _|_ {
							RESOURCE_PACK_ENFORCE: {
								name:  "RESOURCE_PACK_ENFORCE"
								value: "\(_c.server.resourcePackEnforce)"
							}
						}

						// === VanillaTweaks ===
						if _c.server.vanillaTweaksShareCodes != _|_ {
							VANILLATWEAKS_SHARECODE: {
								name:  "VANILLATWEAKS_SHARECODE"
								value: strings.Join(_c.server.vanillaTweaksShareCodes, ",")
							}
						}

						// === Bootstrap Staging ===
						// Tell itzg where to find staged plugins/mods/config so it syncs
						// them into /data on every server start.
						if _c.bootstrap != _|_ {
							COPY_PLUGINS_SRC: {
								name:  "COPY_PLUGINS_SRC"
								value: "/staging/plugins"
							}
							COPY_MODS_SRC: {
								name:  "COPY_MODS_SRC"
								value: "/staging/mods"
							}
							COPY_CONFIG_SRC: {
								name:  "COPY_CONFIG_SRC"
								value: "/staging/config"
							}
							SYNC_SKIP_NEWER_IN_DESTINATION: {
								name:  "SYNC_SKIP_NEWER_IN_DESTINATION"
								value: "\(_c.bootstrap.skipNewerInDestination)"
							}
						}

						// === Query Port ===
						if _c.query.enabled {
							ENABLE_QUERY: {
								name:  "ENABLE_QUERY"
								value: "true"
							}
							QUERY_PORT: {
								name:  "QUERY_PORT"
								value: "\(_c.query.port)"
							}
						}
					}

					volumeMounts: {
						data: volumes.data & {
							mountPath: "/data"
						}
						if _c.bootstrap != _|_ {
							"staging-plugins": volumes["staging-plugins"] & {
								mountPath: "/staging/plugins"
							}
							"staging-mods": volumes["staging-mods"] & {
								mountPath: "/staging/mods"
							}
							"staging-config": volumes["staging-config"] & {
								mountPath: "/staging/config"
							}
						}
					}

					if _c.resources != _|_ {
						resources: _c.resources
					}

					// === Health Checks ===
					startupProbe: {
						exec: command: ["mc-monitor", "status", "--port", "\(_c.port)"]
						periodSeconds:    10
						timeoutSeconds:   5
						failureThreshold: 60
					}
					livenessProbe: {
						exec: command: ["mc-monitor", "status", "--port", "\(_c.port)"]
						periodSeconds:    30
						timeoutSeconds:   5
						failureThreshold: 3
					}
					readinessProbe: {
						exec: command: ["mc-monitor", "status", "--port", "\(_c.port)"]
						periodSeconds:    10
						timeoutSeconds:   3
						failureThreshold: 3
					}
				}

				// === Sidecar Containers ===
				let _backupSidecar = [if _c.backup.enabled {
					{
						name:  "backup"
						image: _c.backup.image

						env: {
							if _c.backup.tar != _|_ {
								BACKUP_METHOD: {name: "BACKUP_METHOD", value: "tar"}
							}
							if _c.backup.rsync != _|_ {
								BACKUP_METHOD: {name: "BACKUP_METHOD", value: "rsync"}
							}
							if _c.backup.restic != _|_ {
								BACKUP_METHOD: {name: "BACKUP_METHOD", value: "restic"}
							}
							if _c.backup.rclone != _|_ {
								BACKUP_METHOD: {name: "BACKUP_METHOD", value: "rclone"}
							}
							BACKUP_INTERVAL: {
								name:  "BACKUP_INTERVAL"
								value: _c.backup.interval
							}
							INITIAL_DELAY: {
								name:  "INITIAL_DELAY"
								value: _c.backup.initialDelay
							}
							RCON_HOST: {name: "RCON_HOST", value: "localhost"}
							RCON_PORT: {
								name:  "RCON_PORT"
								value: "\(_c.rcon.port)"
							}
							RCON_PASSWORD: {
								name: "RCON_PASSWORD"
								from: #config.rconPassword
							}
							SRC_DIR: {name: "SRC_DIR", value: "/data"}
							DEST_DIR: {name: "DEST_DIR", value: "/backups"}
							if _c.backup.pruneBackupsDays != _|_ {
								PRUNE_BACKUPS_DAYS: {
									name:  "PRUNE_BACKUPS_DAYS"
									value: "\(_c.backup.pruneBackupsDays)"
								}
							}
							PAUSE_IF_NO_PLAYERS: {
								name:  "PAUSE_IF_NO_PLAYERS"
								value: "\(_c.backup.pauseIfNoPlayers)"
							}
							if _c.backup.backupName != _|_ {
								BACKUP_NAME: {
									name:  "BACKUP_NAME"
									value: _c.backup.backupName
								}
							}
							if _c.backup.excludes != _|_ {
								EXCLUDES: {
									name:  "EXCLUDES"
									value: strings.Join(_c.backup.excludes, ",")
								}
							}
							if _c.backup.tar != _|_ {
								TAR_COMPRESS_METHOD: {
									name:  "TAR_COMPRESS_METHOD"
									value: _c.backup.tar.compressMethod
								}
								LINK_LATEST: {
									name:  "LINK_LATEST"
									value: "\(_c.backup.tar.linkLatest)"
								}
								if _c.backup.tar.compressParameters != _|_ {
									TAR_COMPRESS_PARAMETERS: {
										name:  "TAR_COMPRESS_PARAMETERS"
										value: _c.backup.tar.compressParameters
									}
								}
							}
							if _c.backup.rsync != _|_ {
								LINK_LATEST: {
									name:  "LINK_LATEST"
									value: "\(_c.backup.rsync.linkLatest)"
								}
							}
							if _c.backup.restic != _|_ {
								RESTIC_REPOSITORY: {
									name:  "RESTIC_REPOSITORY"
									value: _c.backup.restic.repository
								}
								RESTIC_PASSWORD: {
									name: "RESTIC_PASSWORD"
									from: _c.backup.restic.password
								}
								if _c.backup.restic.retention != _|_ {
									PRUNE_RESTIC_RETENTION: {
										name:  "PRUNE_RESTIC_RETENTION"
										value: _c.backup.restic.retention
									}
								}
								if _c.backup.restic.hostname != _|_ {
									RESTIC_HOSTNAME: {
										name:  "RESTIC_HOSTNAME"
										value: _c.backup.restic.hostname
									}
								}
								if _c.backup.restic.verbose != _|_ {
									RESTIC_VERBOSE: {
										name:  "RESTIC_VERBOSE"
										value: "\(_c.backup.restic.verbose)"
									}
								}
								if _c.backup.restic.additionalTags != _|_ {
									RESTIC_ADDITIONAL_TAGS: {
										name:  "RESTIC_ADDITIONAL_TAGS"
										value: _c.backup.restic.additionalTags
									}
								}
								if _c.backup.restic.limitUpload != _|_ {
									RESTIC_LIMIT_UPLOAD: {
										name:  "RESTIC_LIMIT_UPLOAD"
										value: "\(_c.backup.restic.limitUpload)"
									}
								}
								if _c.backup.restic.retryLock != _|_ {
									RESTIC_RETRY_LOCK: {
										name:  "RESTIC_RETRY_LOCK"
										value: _c.backup.restic.retryLock
									}
								}
								if _c.backup.restic.accessKey != _|_ {
									AWS_ACCESS_KEY_ID: {
										name: "AWS_ACCESS_KEY_ID"
										from: _c.backup.restic.accessKey
									}
								}
								if _c.backup.restic.secretKey != _|_ {
									AWS_SECRET_ACCESS_KEY: {
										name: "AWS_SECRET_ACCESS_KEY"
										from: _c.backup.restic.secretKey
									}
								}
							}
							if _c.backup.rclone != _|_ {
								RCLONE_REMOTE: {
									name:  "RCLONE_REMOTE"
									value: _c.backup.rclone.remote
								}
								RCLONE_DEST_DIR: {
									name:  "RCLONE_DEST_DIR"
									value: _c.backup.rclone.destDir
								}
								RCLONE_COMPRESS_METHOD: {
									name:  "RCLONE_COMPRESS_METHOD"
									value: _c.backup.rclone.compressMethod
								}
							}
						}

						volumeMounts: {
							data: volumes.data & {
								mountPath: "/data"
								readOnly:  true
							}
							if _c.backup.enabled && _c.backup.method == "tar" {
								backups: {
									name:      "backups"
									mountPath: "/backups"
									if _c.storage.backups.type == "pvc" {
										persistentClaim: {
											size: _c.storage.backups.size
											if _c.storage.backups.storageClass != _|_ {
												storageClass: _c.storage.backups.storageClass
											}
										}
									}
									if _c.storage.backups.type == "hostPath" {
										hostPath: {
											path: _c.storage.backups.path
											type: _c.storage.backups.hostPathType
										}
									}
									if _c.storage.backups.type == "emptyDir" {
										emptyDir: {}
									}
								}
							}
							if _c.backup.enabled && _c.backup.method == "rsync" {
								if _c.backup.rsync.useLocalStorage {
									backups: {
										name:      "backups"
										mountPath: "/backups"
										if _c.storage.backups.type == "pvc" {
											persistentClaim: {
												size: _c.storage.backups.size
												if _c.storage.backups.storageClass != _|_ {
													storageClass: _c.storage.backups.storageClass
												}
											}
										}
										if _c.storage.backups.type == "hostPath" {
											hostPath: {
												path: _c.storage.backups.path
												type: _c.storage.backups.hostPathType
											}
										}
										if _c.storage.backups.type == "emptyDir" {
											emptyDir: {}
										}
									}
								}
							}
						}

						resources: {
							requests: {cpu: "100m", memory: "256Mi"}
							limits: {cpu: "1000m", memory: "1Gi"}
						}
					}
				}]

				let _monitorSidecar = [if _c.monitor.enabled {
					{
						name:  "mc-monitor"
						image: _c.monitor.image
						command: ["/mc-monitor", "export-for-prometheus"]
						ports: metrics: {
							name:       "metrics"
							targetPort: _c.monitor.port
							protocol:   "TCP"
						}
						env: {
							EXPORT_SERVERS: {
								name: "EXPORT_SERVERS"
								// Use the K8s Service name for meaningful per-server labels.
								// Overridable via _c.monitor.serverHost; defaults to "localhost".
								value: "\(_c.monitor.serverHost):\(_c.port)"
							}
							EXPORT_PORT: {
								name:  "EXPORT_PORT"
								value: "\(_c.monitor.port)"
							}
							TIMEOUT: {
								name:  "TIMEOUT"
								value: _c.monitor.timeout
							}
						}
						resources: {
							requests: {cpu: "10m", memory: "32Mi"}
							limits: {cpu: "100m", memory: "64Mi"}
						}
					}
				}]

				sidecarContainers: list.Concat([_backupSidecar, _monitorSidecar])

				// === Network Exposure ===
				expose: {
					ports: {
						minecraft: {
							targetPort:  25565
							protocol:    "TCP"
							exposedPort: _c.port
						}
						if _c.monitor.enabled {
							metrics: {
								targetPort:  _c.monitor.port
								protocol:    "TCP"
								exposedPort: _c.monitor.port
							}
						}
						if _c.extraPorts != _|_ {
							for _extraPort in _c.extraPorts if _extraPort.expose {
								"\(_extraPort.name)": {
									name:        _extraPort.name
									targetPort:  _extraPort.containerPort
									protocol:    _extraPort.protocol
									exposedPort: _extraPort.containerPort
									if _extraPort.exposedPort != _|_ {
										exposedPort: _extraPort.exposedPort
									}
								}
							}
						}
					}
					type: _c.serviceType
				}

				// === Volumes ===
				volumes: {
					data: {
						name: "data"
						if _c.storage.data.type == "pvc" {
							persistentClaim: {
								size: _c.storage.data.size
								if _c.storage.data.storageClass != _|_ {
									storageClass: _c.storage.data.storageClass
								}
							}
						}
						if _c.storage.data.type == "hostPath" {
							hostPath: {
								path: _c.storage.data.path
								type: _c.storage.data.hostPathType
							}
						}
						if _c.storage.data.type == "emptyDir" {
							emptyDir: {}
						}
						if _c.storage.data.type == "nfs" {
							nfs: {
								server: _c.storage.data.nfsServer
								path:   _c.storage.data.nfsPath
							}
						}
						if _c.storage.data.type == "cifs" {
							cifs: {
								source:    _c.storage.data.cifsSource
								secretRef: _c.storage.data.cifsSecretRef
							}
						}
					}
					if _c.backup.enabled && _c.backup.method == "tar" {
						backups: {
							name: "backups"
							if _c.storage.backups.type == "pvc" {
								persistentClaim: {
									size: _c.storage.backups.size
									if _c.storage.backups.storageClass != _|_ {
										storageClass: _c.storage.backups.storageClass
									}
								}
							}
							if _c.storage.backups.type == "hostPath" {
								hostPath: {
									path: _c.storage.backups.path
									type: _c.storage.backups.hostPathType
								}
							}
							if _c.storage.backups.type == "emptyDir" {
								emptyDir: {}
							}
							if _c.storage.backups.type == "nfs" {
								nfs: {
									server: _c.storage.backups.nfsServer
									path:   _c.storage.backups.nfsPath
								}
							}
							if _c.storage.backups.type == "cifs" {
								cifs: {
									source:    _c.storage.backups.cifsSource
									secretRef: _c.storage.backups.cifsSecretRef
								}
							}
						}
					}
					if _c.backup.enabled && _c.backup.method == "rsync" {
						if _c.backup.rsync.useLocalStorage {
							backups: {
								name: "backups"
								if _c.storage.backups.type == "pvc" {
									persistentClaim: {
										size: _c.storage.backups.size
										if _c.storage.backups.storageClass != _|_ {
											storageClass: _c.storage.backups.storageClass
										}
									}
								}
								if _c.storage.backups.type == "hostPath" {
									hostPath: {
										path: _c.storage.backups.path
										type: _c.storage.backups.hostPathType
									}
								}
								if _c.storage.backups.type == "emptyDir" {
									emptyDir: {}
								}
								if _c.storage.backups.type == "nfs" {
									nfs: {
										server: _c.storage.backups.nfsServer
										path:   _c.storage.backups.nfsPath
									}
								}
								if _c.storage.backups.type == "cifs" {
									cifs: {
										source:    _c.storage.backups.cifsSource
										secretRef: _c.storage.backups.cifsSecretRef
									}
								}
							}
						}
					}

					// === Bootstrap Staging Volumes ===
					// Three ephemeral emptyDirs populated by the bootstrap init container.
					// Re-populated on every pod start; itzg copies their contents into
					// /data/plugins, /data/mods, and /data/config at server startup.
					if _c.bootstrap != _|_ {
						"staging-plugins": {
							name: "staging-plugins"
							emptyDir: {}
						}
						"staging-mods": {
							name: "staging-mods"
							emptyDir: {}
						}
						"staging-config": {
							name: "staging-config"
							emptyDir: {}
						}
					}
				}
			}
		}
	}

	// ── mc-router ─────────────────────────────────────────────────────────────
	// Always present. --mapping args auto-built from the servers map:
	//   {serverName}.{domain}  →  {releaseName}-server-{serverName}.{namespace}.svc:{port}
	router: {
		resources_workload.#Container
		traits_workload.#Scaling
		traits_workload.#RestartPolicy
		traits_workload.#UpdateStrategy
		traits_network.#Expose
		traits_security.#WorkloadIdentity

		metadata: labels: "core.opmodel.dev/workload-type": "stateless"

		spec: {
			scaling: count: 1

			restartPolicy: "Always"

			updateStrategy: type: "Recreate"

			workloadIdentity: {
				name:           _routerName
				automountToken: true
			}

			container: {
				name:  _routerName
				image: #config.router.image

				ports: {
					minecraft: {
						targetPort: #config.router.port
						protocol:   "TCP"
					}
					if #config.router.api.enabled {
						api: {
							targetPort: #config.router.api.port
							protocol:   "TCP"
						}
					}
				}

				env: {
					PORT: {
						name:  "PORT"
						value: "\(#config.router.port)"
					}
					CONNECTION_RATE_LIMIT: {
						name:  "CONNECTION_RATE_LIMIT"
						value: "\(#config.router.connectionRateLimit)"
					}
					DEBUG: {
						name:  "DEBUG"
						value: "\(#config.router.debug)"
					}
					if #config.router.simplifySrv {
						SIMPLIFY_SRV: {
							name:  "SIMPLIFY_SRV"
							value: "true"
						}
					}
					if #config.router.useProxyProtocol {
						USE_PROXY_PROTOCOL: {
							name:  "USE_PROXY_PROTOCOL"
							value: "true"
						}
					}
					if #config.router.defaultServer != _|_ {
						DEFAULT: {
							name:  "DEFAULT"
							value: "\(#config.router.defaultServer.host):\(#config.router.defaultServer.port)"
						}
					}
					if #config.router.autoScale != _|_ {
						if #config.router.autoScale.up != _|_ {
							AUTO_SCALE_UP: {
								name:  "AUTO_SCALE_UP"
								value: "\(#config.router.autoScale.up.enabled)"
							}
						}
						if #config.router.autoScale.down != _|_ {
							AUTO_SCALE_DOWN: {
								name:  "AUTO_SCALE_DOWN"
								value: "\(#config.router.autoScale.down.enabled)"
							}
							if #config.router.autoScale.down.after != _|_ {
								AUTO_SCALE_DOWN_AFTER: {
									name:  "AUTO_SCALE_DOWN_AFTER"
									value: #config.router.autoScale.down.after
								}
							}
						}
					}
					if #config.router.metrics != _|_ {
						METRICS_BACKEND: {
							name:  "METRICS_BACKEND"
							value: #config.router.metrics.backend
						}
					}
					if #config.router.api.enabled {
						API_BINDING: {
							name:  "API_BINDING"
							value: ":\(#config.router.api.port)"
						}
					}
				}

				// Auto-build --mapping args from the servers map.
				// Primary:  -mapping={serverName}.{domain}={releaseName}-server-{serverName}.{namespace}.svc:{port}
				// Aliases:  one extra -mapping per entry in server.aliases
				let _primaryMappings = [for _srvName, _srvCfg in #config.servers {
					"-mapping=\(_srvName).\(_domain)=\(_relName)-server-\(_srvName).\(_ns).svc:\(_srvCfg.port)"
				}]
				let _aliasMappings = [
					for _srvName, _srvCfg in #config.servers
					if _srvCfg.aliases != _|_
					for _alias in _srvCfg.aliases {
						"-mapping=\(_alias)=\(_relName)-server-\(_srvName).\(_ns).svc:\(_srvCfg.port)"
					},
				]
				args: list.Concat([_primaryMappings, _aliasMappings])

				if #config.router.resources != _|_ {
					resources: #config.router.resources
				}
			}

			expose: {
				ports: {
					minecraft: {
						targetPort:  #config.router.port
						protocol:    "TCP"
						exposedPort: #config.router.port
					}
					if #config.router.api.enabled {
						api: {
							targetPort:  #config.router.api.port
							protocol:    "TCP"
							exposedPort: #config.router.api.port
						}
					}
				}
				type: #config.router.serviceType
			}
		}
	}

	// ── code-server ────────────────────────────────────────────────────────────
	// Optional single Deployment running code-server (VS Code in the browser).
	// Mounts every server's data volume at /servers/{name} so all world files
	// are accessible from one editor. Home directory is stored on a dedicated
	// PVC so extensions and settings persist across restarts.
	//
	// hostPath volumes are shared by pointing at the same host path as the
	// server StatefulSets — no PVC ownership conflicts.
	// pvc storage: code-server gets a separate new PVC per server (data not shared).
	if #config.codeServer != _|_ {
		if #config.codeServer.enabled {
			let _cs = #config.codeServer

			"code-server": {
				resources_workload.#Container
				resources_storage.#Volumes
				traits_workload.#Scaling
				traits_workload.#RestartPolicy
				traits_workload.#UpdateStrategy
				traits_network.#Expose
				traits_security.#SecurityContext

				metadata: labels: "core.opmodel.dev/workload-type": "stateless"

				spec: {
					scaling: count: 1
					restartPolicy: "Always"
					updateStrategy: type: "Recreate"

					// Run as the same UID/GID as the server containers so that
					// files written by the servers are accessible in code-server.
					// readOnlyRootFilesystem is false — code-server writes to /home/coder.
					securityContext: {
						runAsNonRoot:             true
						runAsUser:                1000
						runAsGroup:               3000
						readOnlyRootFilesystem:   false
						allowPrivilegeEscalation: false
						capabilities: drop: ["ALL"]
					}

					container: {
						name:  "code-server"
						image: _cs.image

						ports: http: {
							targetPort: _cs.port
							protocol:   "TCP"
						}

						env: {
							PORT: {name: "PORT", value: "\(_cs.port)"}
							if _cs.password != _|_ {
								PASSWORD: {name: "PASSWORD", from: _cs.password}
							}
						}

						volumeMounts: {
							// Persistent home for extensions, settings, and workspace state.
							// References volumes.home so the source type is carried through.
							home: volumes.home & {
								mountPath: "/home/coder"
							}
							// One mount per server — /servers/{serverName}
							for _srvName, _ in #config.servers {
								"\(_srvName)-data": volumes["\(_srvName)-data"] & {
									mountPath: "/servers/\(_srvName)"
								}
							}
						}

						if _cs.resources != _|_ {
							resources: _cs.resources
						}
					}

					volumes: {
						// Home PVC / hostPath / emptyDir
						home: {
							name: "home"
							if _cs.storage.home.type == "pvc" {
								persistentClaim: {
									size: _cs.storage.home.size
									if _cs.storage.home.storageClass != _|_ {
										storageClass: _cs.storage.home.storageClass
									}
								}
							}
							if _cs.storage.home.type == "hostPath" {
								hostPath: {
									path: _cs.storage.home.path
									type: _cs.storage.home.hostPathType
								}
							}
							if _cs.storage.home.type == "emptyDir" {
								emptyDir: {}
							}
						}
						// Server data volumes — mirrors each server's storage config.
						// hostPath: shares the host path directly (recommended).
						// pvc/emptyDir: creates a separate volume (data not shared).
						for _srvName, _srvCfg in #config.servers {
							"\(_srvName)-data": {
								name: "\(_srvName)-data"
								if _srvCfg.storage.data.type == "pvc" {
									persistentClaim: {
										size: _srvCfg.storage.data.size
										if _srvCfg.storage.data.storageClass != _|_ {
											storageClass: _srvCfg.storage.data.storageClass
										}
									}
								}
								if _srvCfg.storage.data.type == "hostPath" {
									hostPath: {
										path: _srvCfg.storage.data.path
										type: _srvCfg.storage.data.hostPathType
									}
								}
								if _srvCfg.storage.data.type == "emptyDir" {
									emptyDir: {}
								}
							}
						}
					}

					expose: {
						ports: http: {
							targetPort:  _cs.port
							protocol:    "TCP"
							exposedPort: _cs.port
						}
						type: _cs.serviceType
					}
				}
			}
		}
	}

	// ── restic-gui ─────────────────────────────────────────────────────────────
	// Optional Backrest deployment (https://github.com/garethgeorge/backrest)
	// for browsing and restoring restic snapshots created by the backup sidecars.
	//
	// Config is generated entirely in CUE and stored as an immutable K8s Secret
	// (content-hash named). Any change to repos or credentials produces a new
	// Secret and triggers a pod rollout automatically — no init container, no
	// stale config.json on a PVC to worry about.
	//
	// Backrest connects to repos over S3/network only — no server data volumes
	// are mounted. Prune and check schedules are disabled in pre-configured repos
	// because the itzg/mc-backup sidecar already owns the backup schedule.
	if #config.resticGui != _|_ {
		if #config.resticGui.enabled {
			let _rg = #config.resticGui

			// Ordered list of restic-enabled servers (lexicographic by name — CUE
			// struct iteration is deterministic, giving stable indices).
			let _resticServers = [
				for _name, _c in #config.servers
				if _c.backup.enabled && _c.backup.restic != _|_ {
					{name: _name, cfg: _c}
				},
			]

			// Build the full Backrest config.json as a CUE value and marshal to JSON.
			// passwordBcrypt is a pre-computed bcrypt hash supplied in values.
			let _backrestConfig = {
				modno:    0
				version:  6
				instance: "\(_relName)-backrest"
				repos: [for _, _s in _resticServers {
					let _awsEnv = {
						if _s.cfg.backup.restic.accessKey != _|_ {
							accessKey: "AWS_ACCESS_KEY_ID=\(_s.cfg.backup.restic.accessKey.value)"
						}
						if _s.cfg.backup.restic.secretKey != _|_ {
							secretKey: "AWS_SECRET_ACCESS_KEY=\(_s.cfg.backup.restic.secretKey.value)"
						}
					}
					id:       "\(_relName)-\(_s.name)"
					uri:      _s.cfg.backup.restic.repository
					password: _s.cfg.backup.restic.password.value
					env: [for _, v in _awsEnv {v}]
					autoUnlock:     true
					autoInitialize: true
					prunePolicy: {schedule: {disabled: true}}
					checkPolicy: {schedule: {disabled: true}}
				}]
				auth: {
					users: [{
						name:           _rg.username
						passwordBcrypt: _rg.passwordBcryptHash
					}]
				}
				// multihost.identity must be present so Backrest's PopulateRequiredFields
				// returns mutated=false on startup. Without it, Backrest calls Update()
				// to write the identity back, which triggers makeBackup() and fails
				// because the config is mounted read-only from a K8s Secret.
				multihost: {
					identity: {
						keyId:       _rg.multihostIdentity.keyId
						ed25519priv: _rg.multihostIdentity.privKey
						ed25519pub:  _rg.multihostIdentity.pubKey
					}
				}
			}

			let _configJSON = json.Marshal(_backrestConfig)

			"restic-gui": {
				resources_workload.#Container
				resources_storage.#Volumes
				resources_config.#Secrets
				traits_workload.#InitContainers
				traits_workload.#Scaling
				traits_workload.#RestartPolicy
				traits_workload.#UpdateStrategy
				traits_network.#Expose
				traits_security.#SecurityContext

				metadata: labels: "core.opmodel.dev/workload-type": "stateless"

				spec: {
					scaling: count: 1
					restartPolicy: "Always"
					updateStrategy: type: "Recreate"

					// Run Backrest as the same UID/GID as the Minecraft and code-server
					// containers so restored files and staging directories remain
					// accessible from /servers/{name} without root-owned artifacts.
					securityContext: {
						runAsNonRoot:             true
						runAsUser:                1000
						runAsGroup:               1000
						fsGroup:                  1000
						readOnlyRootFilesystem:   false
						allowPrivilegeEscalation: false
						capabilities: drop: ["ALL"]
					}

					// === Config Secret ===
					// CUE-generated Backrest config stored as an immutable K8s Secret.
					// Mounted read-only at /config-template — the init container copies
					// it to the writable /data emptyDir before Backrest starts.
					// Backrest writes GUIDs, operation logs, and cache freely to /data.
					secrets: backrestConfig: {
						name:      "backrest-config"
						type:      "Opaque"
						immutable: true
						data: {
							"config.json": _configJSON
						}
					}

					// === Init Container: Config Seed ===
					// Copies the immutable Secret config into the writable emptyDir on
					// every pod start so Backrest can write GUIDs and operation logs.
					initContainers: [{
						name: "config-seed"
						image: {
							repository: "busybox"
							tag:        "latest"
							digest:     ""
						}
						command: ["cp", "/config-template/config.json", "/data/config.json"]
						volumeMounts: {
							"config-template": volumes["config-template"] & {mountPath: "/config-template", readOnly: true}
							data:              volumes.data & {mountPath: "/data"}
						}
					}]

					// === Main Container: Backrest ===
					// Reads/writes config freely from the writable /data emptyDir.
					// Server hostPath volumes are mounted writable at /servers/{name}
					// so Backrest can restore snapshots directly into server data dirs.
					container: {
						name:  "backrest"
						image: _rg.image

						ports: http: {
							targetPort: _rg.port
							protocol:   "TCP"
						}

						env: {
							BACKREST_PORT:   {name: "BACKREST_PORT",   value: "0.0.0.0:\(_rg.port)"}
							BACKREST_DATA:   {name: "BACKREST_DATA",   value: "/data"}
							BACKREST_CONFIG: {name: "BACKREST_CONFIG", value: "/data/config.json"}
							XDG_CACHE_HOME:  {name: "XDG_CACHE_HOME", value: "/data/cache"}
							TMPDIR:          {name: "TMPDIR",          value: "/tmp"}
						}

						volumeMounts: {
							data: volumes.data & {mountPath: "/data"}
							tmp:  volumes.tmp & {mountPath: "/tmp"}

							// One writable mount per hostPath-backed restic server.
							for _, _s in _resticServers
							if _s.cfg.storage.data.type == "hostPath" {
								"server-\(_s.name)": volumes["server-\(_s.name)"] & {
									mountPath: "/servers/\(_s.name)"
								}
							}
						}

						if _rg.resources != _|_ {
							resources: _rg.resources
						}
					}

					volumes: {
						// Writable emptyDir — holds config.json (seeded by init container),
						// GUIDs written back by Backrest, operation logs, and restic cache.
						// Ephemeral: reset on every pod restart (init container re-seeds).
						data: {
							name:     "data"
							emptyDir: {}
						}
						// Writable /tmp for restic staging.
						tmp: {
							name:     "tmp"
							emptyDir: {}
						}
						// Read-only Secret mount — init container source only.
						"config-template": {
							name: "config-template"
							secret: {
								from: {secrets.backrestConfig}
								items: [{key: "config.json", path: "config.json"}]
							}
						}
						// One hostPath volume per restic-enabled server with hostPath storage.
						// Mounted writable in Backrest for snapshot restore operations.
						for _, _s in _resticServers
						if _s.cfg.storage.data.type == "hostPath" {
							"server-\(_s.name)": {
								name: "server-\(_s.name)"
								hostPath: {
									path: _s.cfg.storage.data.path
									type: _s.cfg.storage.data.hostPathType
								}
							}
						}
					}

					expose: {
						ports: http: {
							targetPort:  _rg.port
							protocol:    "TCP"
							exposedPort: _rg.port
						}
						type: _rg.serviceType
					}
				}
			}
		}
	}

	// ── RBAC ──────────────────────────────────────────────────────────────────
	// Grants mc-router permission to watch/list Services (service discovery)
	// and manage StatefulSets (auto-scale wake/sleep).
	rbac: {
		resources_security.#Role

		spec: role: {
			name:  _routerName
			scope: "cluster"

			rules: [
				{
					apiGroups: [""]
					resources: ["services"]
					verbs: ["watch", "list"]
				},
				{
					apiGroups: ["apps"]
					resources: ["statefulsets", "statefulsets/scale"]
					verbs: ["watch", "list", "get", "update", "patch"]
				},
			]

			subjects: [{
				name: _routerName
			}]
		}
	}
}
