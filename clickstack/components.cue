// Components for the ClickStack module.
//
//   hyperdx           — HyperDX UI + API Deployment, ConfigMap, and Secret
//   mongodb           — MongoDBCommunity CR (catalog/mongodb_operator)
//   clickhouse        — ClickHouseInstallation CR (catalog/clickhouse_operator)
//   clickhouse-keeper — ClickHouseKeeperInstallation CR (catalog/clickhouse_operator)
//   otel-collector    — OpenTelemetryCollector CR (catalog/otel_collector)
package clickstack

import (
	"encoding/json"

	resources_config "opmodel.dev/opm/v1alpha1/resources/config@v1"
	resources_security "opmodel.dev/opm/v1alpha1/resources/security@v1"
	resources_workload "opmodel.dev/opm/v1alpha1/resources/workload@v1"
	traits_network "opmodel.dev/opm/v1alpha1/traits/network@v1"
	traits_security "opmodel.dev/opm/v1alpha1/traits/security@v1"
	traits_workload "opmodel.dev/opm/v1alpha1/traits/workload@v1"

	mdb_db "opmodel.dev/mongodb_operator/v1alpha1/resources/database@v1"
	chop_db "opmodel.dev/clickhouse_operator/v1alpha1/resources/database@v1"
	otel_telemetry "opmodel.dev/otel_collector/v1alpha1/resources/telemetry@v1"
)

#components: {

	/////////////////////////////////////////////////////////////////
	//// HyperDX — UI + API Deployment
	////
	//// Reads configuration via envFrom the `clickstack-config` ConfigMap
	//// and the `clickstack-secret` Secret (auto-created by OPM from the
	//// four #config secret references).
	/////////////////////////////////////////////////////////////////

	hyperdx: {
		resources_workload.#Container
		resources_config.#ConfigMaps
		traits_workload.#Scaling
		traits_workload.#RestartPolicy
		traits_workload.#UpdateStrategy
		traits_workload.#InitContainers
		traits_network.#Expose
		traits_security.#SecurityContext

		metadata: {
			name: "hyperdx"
			labels: "core.opmodel.dev/workload-type": "stateless"
		}

		spec: {
			scaling: count: 1

			restartPolicy: "Always"

			updateStrategy: type: "RollingUpdate"

			// ConfigMap with non-sensitive environment variables.
			configMaps: {
				"clickstack-config": {
					immutable: false
					data: {
						APP_PORT:                                  "\(#config.ports.app)"
						API_PORT:                                  "\(#config.ports.api)"
						HYPERDX_API_PORT:                          "\(#config.ports.api)"
						HYPERDX_APP_PORT:                          "\(#config.ports.app)"
						OPAMP_PORT:                                "\(#config.ports.opamp)"
						HYPERDX_LOG_LEVEL:                         "info"
						OTEL_SERVICE_NAME:                         "hdx-oss-api"
						USAGE_STATS_ENABLED:                       "true"
						HYPERDX_OTEL_EXPORTER_CLICKHOUSE_DATABASE: "default"
						CLICKHOUSE_USER:                           "otelcollector"
						RUN_SCHEDULED_TASKS_EXTERNALLY:            "false"
						FRONTEND_URL:                              #config.frontendUrl
						// Service-to-service URLs. Operators emit Service names that
						// embed the CR name, which itself is prefixed by the release
						// name. See #config.releaseName.
						CLICKHOUSE_ENDPOINT:                    "tcp://clickhouse-\(#config.releaseName)-clickhouse:\(#config.clickhouse.nativePort)?dial_timeout=10s"
						CLICKHOUSE_SERVER_ENDPOINT:             "clickhouse-\(#config.releaseName)-clickhouse:\(#config.clickhouse.nativePort)"
						CLICKHOUSE_PROMETHEUS_METRICS_ENDPOINT: "clickhouse-\(#config.releaseName)-clickhouse:9363"
						OTEL_EXPORTER_OTLP_ENDPOINT:            "http://\(#config.releaseName)-otel-collector:4318"
						OPAMP_SERVER_URL:                       "http://\(#config.releaseName)-hyperdx:\(#config.ports.opamp)"
						// MONGO_URI lives on the container env, not here — Kubernetes
						// only expands $(VAR) in values under `env:`, not those loaded
						// via `envFrom: configMapRef`. Setting it in the CM would leave
						// the literal "$(MONGODB_PASSWORD)" in the URI and fail SCRAM.
					}
				}

			}

			// Init container — block startup until MongoDB accepts connections.
			// Runs as non-root to satisfy the pod's securityContext.
			// MongoDB Community operator creates a `<crName>-svc` headless service;
			// our CR is `<release>-mongodb` so the service is `<release>-mongodb-svc`.
			initContainers: [{
				name:  "wait-for-mongodb"
				image: #config.initImage
				command: [
					"/bin/sh", "-c",
					"until nc -z clickstack-mongodb-svc 27017; do echo 'waiting for mongodb...'; sleep 2; done",
				]
				securityContext: {
					runAsNonRoot:             true
					runAsUser:                65534
					runAsGroup:               65534
					allowPrivilegeEscalation: false
					capabilities: drop: ["ALL"]
				}
			}]

			container: {
				name:  "hyperdx"
				image: #config.image

				ports: {
					app: {
						name:       "app"
						targetPort: #config.ports.app
					}
					api: {
						name:       "api"
						targetPort: #config.ports.api
					}
					opamp: {
						name:       "opamp"
						targetPort: #config.ports.opamp
					}
				}

				// Pull non-sensitive config (MONGO_URI, endpoints, ports) from the
				// clickstack-config ConfigMap. OPM's configmap transformer names the
				// K8s object {release}-{component}-{cm.name}, hence the explicit
				// "clickstack-hyperdx-clickstack-config" below.
				envFrom: [{configMapRef: name: "clickstack-hyperdx-clickstack-config"}]

				// envFrom-style wiring — HyperDX reads non-sensitive config from
				// the ConfigMap and passwords/keys from the OPM-provisioned Secret.
				// MONGO_URI / DEFAULT_CONNECTIONS / DEFAULT_SOURCES must be defined
				// here (not in the CM) so Kubernetes expands $(VAR) refs at pod
				// start; envFrom values are passed verbatim and would leak the
				// literal template string into the app.
				env: {
					MONGODB_PASSWORD: {
						name: "MONGODB_PASSWORD"
						from: #config.mongodbPassword
					}
					CLICKHOUSE_PASSWORD: {
						name: "CLICKHOUSE_PASSWORD"
						from: #config.clickhousePassword
					}
					CLICKHOUSE_APP_PASSWORD: {
						name: "CLICKHOUSE_APP_PASSWORD"
						from: #config.clickhouseAppPassword
					}
					HYPERDX_API_KEY: {
						name: "HYPERDX_API_KEY"
						from: #config.hyperdxApiKey
					}
					MONGO_URI: {
						name:  "MONGO_URI"
						value: "mongodb://hyperdx:$(MONGODB_PASSWORD)@\(#config.releaseName)-mongodb-svc:27017/hyperdx?authSource=hyperdx"
					}

					// Seed default ClickHouse connection + log/trace/metric sources
					// on first team creation. HyperDX runs setupDefaults() once per
					// team — only when the team has zero connections AND zero sources
					// — so subsequent UI edits are preserved.
					//
					// `$(CLICKHOUSE_APP_PASSWORD)` is expanded by Kubernetes (textual
					// substitution inside the env `value`); HyperDX itself does not
					// interpret $(VAR) syntax. Use the `app` user (read+write on the
					// `default` DB where otel_logs / otel_traces / otel_metrics_*
					// tables live) so the UI can run queries.
					DEFAULT_CONNECTIONS: {
						name: "DEFAULT_CONNECTIONS"
						value: json.Marshal([{
							name:     "Local ClickHouse"
							host:     "http://clickhouse-\(#config.releaseName)-clickhouse:\(#config.clickhouse.httpPort)"
							username: "app"
							password: "$(CLICKHOUSE_APP_PASSWORD)"
						}])
					}
					DEFAULT_SOURCES: {
						name: "DEFAULT_SOURCES"
						value: json.Marshal([
							{
								name:       "Logs"
								kind:       "log"
								connection: "Local ClickHouse"
								from: {
									databaseName: "default"
									tableName:    "otel_logs"
								}
								timestampValueExpression:          "TimestampTime"
								displayedTimestampValueExpression: "Timestamp"
								defaultTableSelectExpression:      "Timestamp, ServiceName, SeverityText, Body"
								serviceNameExpression:             "ServiceName"
								severityTextExpression:            "SeverityText"
								bodyExpression:                    "Body"
								eventAttributesExpression:         "LogAttributes"
								resourceAttributesExpression:      "ResourceAttributes"
								traceIdExpression:                 "TraceId"
								spanIdExpression:                  "SpanId"
								implicitColumnExpression:          "Body"
								traceSourceId:                     "Traces"
								metricSourceId:                    "Metrics"
							},
							{
								name:       "Traces"
								kind:       "trace"
								connection: "Local ClickHouse"
								from: {
									databaseName: "default"
									tableName:    "otel_traces"
								}
								timestampValueExpression:          "Timestamp"
								displayedTimestampValueExpression: "Timestamp"
								defaultTableSelectExpression:      "Timestamp, ServiceName, StatusCode, round(Duration / 1e6), SpanName"
								durationExpression:                "Duration"
								durationPrecision:                 9
								traceIdExpression:                 "TraceId"
								spanIdExpression:                  "SpanId"
								parentSpanIdExpression:            "ParentSpanId"
								spanNameExpression:                "SpanName"
								spanKindExpression:                "SpanKind"
								statusCodeExpression:              "StatusCode"
								statusMessageExpression:           "StatusMessage"
								serviceNameExpression:             "ServiceName"
								eventAttributesExpression:         "SpanAttributes"
								resourceAttributesExpression:      "ResourceAttributes"
								implicitColumnExpression:          "SpanName"
								logSourceId:                       "Logs"
								metricSourceId:                    "Metrics"
							},
							{
								// Single metric source covers every OTel metric type;
								// `metricTables` is a per-kind table-name map, and
								// `from.tableName` must be empty.
								name:       "Metrics"
								kind:       "metric"
								connection: "Local ClickHouse"
								from: {
									databaseName: "default"
									tableName:    ""
								}
								timestampValueExpression: "TimeUnix"
								metricTables: {
									gauge:                   "otel_metrics_gauge"
									histogram:               "otel_metrics_histogram"
									sum:                     "otel_metrics_sum"
									summary:                 "otel_metrics_summary"
									"exponential histogram": "otel_metrics_exponential_histogram"
								}
								serviceNameExpression:        "ServiceName"
								resourceAttributesExpression: "ResourceAttributes"
								logSourceId:                  "Logs"
							},
						])
					}
				}

				readinessProbe: {
					httpGet: {
						path: "/health"
						port: #config.ports.api
					}
					initialDelaySeconds: 1
					periodSeconds:       10
					failureThreshold:    3
				}

				livenessProbe: {
					httpGet: {
						path: "/health"
						port: #config.ports.api
					}
					initialDelaySeconds: 10
					periodSeconds:       30
					failureThreshold:    3
				}

				if #config.hyperdxResources != _|_ {
					resources: #config.hyperdxResources
				}
			}

			expose: {
				ports: {
					app: container.ports.app & {
						exposedPort: #config.ports.app
					}
					api: container.ports.api & {
						exposedPort: #config.ports.api
					}
					opamp: container.ports.opamp & {
						exposedPort: #config.ports.opamp
					}
				}
				type: "ClusterIP"
			}

			securityContext: {
				runAsNonRoot: true
				// HyperDX image declares USER "node" (non-numeric). Kubelet
				// refuses runAsNonRoot without a numeric UID it can verify,
				// so pin to the image's node user (uid 1000).
				runAsUser:                1000
				readOnlyRootFilesystem:   false
				allowPrivilegeEscalation: false
				capabilities: drop: ["ALL"]
			}
		}
	}

	/////////////////////////////////////////////////////////////////
	//// MongoDB — HyperDX metadata store
	/////////////////////////////////////////////////////////////////

	// MongoDB Community operator hardcodes the replica set pod ServiceAccount
	// to "mongodb-kubernetes-appdb" (see
	// mongodb-community-operator/controllers/construct/mongodbstatefulset.go:56).
	// Upstream's helm chart creates this SA + a matching Role in the operator
	// namespace — we're running the CR in a different namespace (clickstack),
	// so the SA must exist there too. OPM's service-account transformer
	// prefixes the component name with the release name, yielding
	// "clickstack-mongodb-appdb"; we override the pod's ServiceAccountName
	// below so the CR's merge path
	// (mongodb-community-operator/pkg/util/merge/merge_podtemplate_spec.go:43)
	// replaces the hardcoded default.
	"mongodb-appdb-sa": {
		resources_security.#ServiceAccount

		metadata: name: "mongodb-appdb"

		spec: serviceAccount: {
			name:           "mongodb-appdb"
			automountToken: true
		}
	}

	// Minimal Role the mongod + agent containers need to fetch their
	// AutomationConfig secret and self-patch pod annotations during upgrades.
	// Lifted from templates/database-roles.yaml in the upstream chart.
	"mongodb-appdb-role": {
		resources_security.#Role

		metadata: name: "mongodb-appdb"

		spec: role: {
			name:  "mongodb-appdb"
			scope: "namespace"
			rules: [
				{
					apiGroups: [""]
					resources: ["secrets"]
					verbs: ["get"]
				},
				{
					apiGroups: [""]
					resources: ["pods"]
					verbs: ["patch", "delete", "get"]
				},
			]
			subjects: [{name: "mongodb-appdb"}]
		}
	}

	mongodb: {
		mdb_db.#MongoDBCommunity

		metadata: name: "mongodb"

		spec: mongodbCommunity: spec: {
			members: #config.mongodb.members
			type:    "ReplicaSet"
			version: #config.mongodb.version
			security: authentication: modes: ["SCRAM"]
			users: [{
				name: "hyperdx"
				db:   "hyperdx"
				passwordSecretRef: {
					name: "clickstack-secret"
					key:  "MONGODB_PASSWORD"
				}
				roles: [{name: "dbOwner", db: "hyperdx"}]
				scramCredentialsSecretName: "clickstack-hyperdx-scram"
			}]
			statefulSet: spec: {
				// mongod + mongodb-agent share a keyfile emptyDir volume. The agent
				// writes keyfile with owner uid 2000 and mode 0600. Without matching
				// runAsUser/fsGroup, mongod fails with "keyfile: bad file". Matches
				// the defaults the community operator *would* set when
				// MANAGED_SECURITY_CONTEXT=false — make it explicit so the chain
				// doesn't regress on operator env drift.
				template: spec: {
					securityContext: {
						runAsUser:    2000
						runAsGroup:   2000
						fsGroup:      2000
						runAsNonRoot: true
					}
					// Override the operator's hardcoded default SA; matches the
					// ServiceAccount created above by the "mongodb-appdb-sa"
					// component. OPM's SA transformer keeps the spec.name as-is
					// when the component metadata.name is explicit.
					serviceAccountName: "mongodb-appdb"
				}
				volumeClaimTemplates: [{
					metadata: name: "data-volume"
					spec: {
						accessModes: ["ReadWriteOnce"]
						resources: requests: storage: #config.mongodb.storageSize
					}
				}]
			}
		}
	}

	/////////////////////////////////////////////////////////////////
	//// ClickHouse — telemetry columnar database
	/////////////////////////////////////////////////////////////////

	clickhouse: {
		chop_db.#ClickHouseInstallation

		metadata: name: "clickhouse"

		spec: clickhouseInstallation: spec: {
			configuration: {
				clusters: [{
					name: "default"
					layout: {
						shardsCount:   #config.clickhouse.shards
						replicasCount: #config.clickhouse.replicas
					}
				}]
				users: {
					// Altinity resolves Secret references only for keys prefixed with
					// `k8s_secret_` and expects `<secret>/<key>` (slash, not colon).
					// Plain `password:` is treated as a literal value and hashed as-is,
					// which silently bakes the ref string into CH instead of the
					// resolved password — clients then fail to authenticate with
					// code 516. Keep the `k8s_secret_password` form.
					"otelcollector/k8s_secret_password": "\(#config.clickhousePassword.$secretName)/\(#config.clickhousePassword.$dataKey)"
					"otelcollector/networks/ip":         "::/0"
					"app/k8s_secret_password":           "\(#config.clickhouseAppPassword.$secretName)/\(#config.clickhouseAppPassword.$dataKey)"
					"app/networks/ip":                   "::/0"
				}
			}
			// Storage templates omitted — the catalog's timoni-vendored schema
			// renders the PVC `spec` as a closed empty struct (upstream CRD gap),
			// which blocks authoring detailed `accessModes`/`resources` here.
			// Operator defaults to emptyDir. Supply full `spec.templates.volumeClaimTemplates`
			// via a ModuleRelease patch when deploying to a cluster that needs persistence.
		}
	}

	/////////////////////////////////////////////////////////////////
	//// ClickHouse Keeper — quorum coordination
	/////////////////////////////////////////////////////////////////

	"clickhouse-keeper": {
		chop_db.#ClickHouseKeeperInstallation

		metadata: name: "keeper"

		// Storage omitted — see note on clickhouse component above. Patch via
		// ModuleRelease for production sizing.
		spec: clickhouseKeeperInstallation: spec: {
			configuration: clusters: [{
				name: "default"
				layout: replicasCount: #config.keeper.replicas
			}]
		}
	}

	/////////////////////////////////////////////////////////////////
	//// OTEL Collector — OTLP ingress + cluster-wide scraping
	////
	//// DaemonSet-mode collector — one pod per node — doing three things
	//// at once:
	////
	////   1. OTLP gRPC/HTTP ingress (4317/4318) for apps that push telemetry
	////      (HyperDX itself + anything instrumented with the OTel SDK).
	////   2. filelog receiver tailing every container's stdout/stderr from
	////      the node's /var/log/pods (kubelet-managed). Self-logs are
	////      excluded to prevent feedback loops.
	////   3. kubeletstats receiver scraping per-pod/container/volume
	////      metrics from the local kubelet's :10250 stats endpoint.
	////
	//// All three pipelines exit via the `clickhouse` exporter, which
	//// authenticates as the `otelcollector` user provisioned in the CHI.
	//// A `transform` processor copies k8s.container.name → service.name
	//// on log records without an upstream service.name, so filelog-sourced
	//// entries carry a useful ServiceName in the HyperDX UI.
	/////////////////////////////////////////////////////////////////

	"otel-collector-sa": {
		resources_security.#ServiceAccount

		metadata: name: "otel-scraper"

		spec: serviceAccount: {
			name:           "otel-scraper"
			automountToken: true
		}
	}

	// ClusterRole + ClusterRoleBinding covering the API access kubeletstats
	// (nodes/stats, nodes/proxy) needs. Scope is cluster so the DaemonSet
	// can reach every node's kubelet regardless of which namespace its pod
	// lands in.
	"otel-collector-rbac": {
		resources_security.#Role

		metadata: name: "otel-scraper"

		spec: role: {
			name:  "otel-scraper"
			scope: "cluster"
			rules: [
				{
					apiGroups: [""]
					resources: ["nodes", "nodes/stats", "nodes/proxy", "pods", "namespaces"]
					verbs: ["get", "list", "watch"]
				},
			]
			subjects: [{name: "otel-scraper"}]
		}
	}

	"otel-collector": {
		otel_telemetry.#Collector

		metadata: name: "otel"

		spec: collector: spec: {
			mode:           "daemonset"
			image:          "\(#config.otel.image.repository):\(#config.otel.image.tag)"
			serviceAccount: "otel-scraper"

			// Downward-API env: K8S_NODE_NAME is what kubeletstats uses to build
			// the `https://${K8S_NODE_NAME}:10250` endpoint so each pod scrapes
			// only its own node. CLICKHOUSE_PASSWORD wires the exporter auth.
			env: [
				{
					name: "CLICKHOUSE_PASSWORD"
					valueFrom: secretKeyRef: {
						name: "clickstack-secret"
						key:  "CLICKHOUSE_PASSWORD"
					}
				},
				{
					name: "K8S_NODE_NAME"
					valueFrom: fieldRef: fieldPath: "spec.nodeName"
				},
			]

			// Mount the node's kubelet-managed pod log tree read-only.
			// /var/log/containers holds kubelet-created symlinks pointing into
			// /var/log/pods; mounting both keeps the `container` operator happy
			// regardless of which path the CRI surfaces.
			volumes: [
				{
					name: "varlogpods"
					hostPath: path: "/var/log/pods"
				},
				{
					name: "varlogcontainers"
					hostPath: path: "/var/log/containers"
				},
			]
			volumeMounts: [
				{
					name:      "varlogpods"
					mountPath: "/var/log/pods"
					readOnly:  true
				},
				{
					name:      "varlogcontainers"
					mountPath: "/var/log/containers"
					readOnly:  true
				},
			]

			config: {
				receivers: {
					otlp: protocols: {
						grpc: endpoint: "0.0.0.0:4317"
						http: endpoint: "0.0.0.0:4318"
					}

					// Tail every container log on the node. Exclude this
					// collector's own logs to stop a feedback loop (our logs
					// ship themselves, get re-parsed, ship themselves…).
					// The `container` operator parses the CRI log format and
					// populates k8s.{namespace,pod,container}.name resource
					// attributes so HyperDX can group by them.
					filelog: {
						include: ["/var/log/pods/*/*/*.log"]
						exclude: ["/var/log/pods/*_\(#config.releaseName)-otel-collector-*/*/*.log"]
						start_at:          "end"
						include_file_path: true
						include_file_name: false
						operators: [{
							type: "container"
							id:   "container-parser"
						}]
					}

					// Scrape per-pod / per-container / per-volume metrics from
					// the local kubelet. insecure_skip_verify because kind uses
					// a self-signed kubelet serving cert.
					kubeletstats: {
						auth_type:            "serviceAccount"
						collection_interval:  "30s"
						endpoint:             "https://${env:K8S_NODE_NAME}:10250"
						insecure_skip_verify: true
						metric_groups: ["node", "pod", "container", "volume"]
					}
				}
				processors: {
					"memory_limiter": {
						check_interval:   "1s"
						limit_percentage: 75
					}
					batch: {}

					// Set service.name = k8s.container.name on logs that came
					// in without one (i.e. filelog-sourced container stdout).
					// HyperDX's ServiceName column is populated from
					// resource["service.name"]; without this, pod logs land
					// with an empty ServiceName and the UI's service filter is
					// useless.
					transform: {
						log_statements: [{
							context: "resource"
							statements: [
								"set(attributes[\"service.name\"], attributes[\"k8s.container.name\"]) where attributes[\"service.name\"] == nil",
							]
						}]
					}
				}
				exporters: {
					clickhouse: {
						endpoint:           "tcp://clickhouse-\(#config.releaseName)-clickhouse:\(#config.clickhouse.nativePort)?dial_timeout=10s"
						database:           "default"
						username:           "otelcollector"
						password:           "${env:CLICKHOUSE_PASSWORD}"
						logs_table_name:    "otel_logs"
						traces_table_name:  "otel_traces"
						metrics_table_name: "otel_metrics"
					}
				}
				service: pipelines: {
					logs: {
						receivers: ["otlp", "filelog"]
						processors: ["memory_limiter", "transform", "batch"]
						exporters: ["clickhouse"]
					}
					traces: {
						receivers: ["otlp"]
						processors: ["memory_limiter", "batch"]
						exporters: ["clickhouse"]
					}
					metrics: {
						receivers: ["otlp", "kubeletstats"]
						processors: ["memory_limiter", "batch"]
						exporters: ["clickhouse"]
					}
				}
			}
		}
	}
}
