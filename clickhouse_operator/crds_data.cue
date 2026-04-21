// Altinity ClickHouse operator CRD definitions (v0.26.3).
// Simplified schema using x-kubernetes-preserve-unknown-fields — authoring-side
// validation is provided by catalog/clickhouse_operator timoni-generated types.
package clickhouse_operator

#crd_clickhouseinstallations: {
	apiVersion: "apiextensions.k8s.io/v1"
	kind:       "CustomResourceDefinition"
	metadata: name: "clickhouseinstallations.clickhouse.altinity.com"
	spec: {
		group: "clickhouse.altinity.com"
		names: {
			kind:     "ClickHouseInstallation"
			listKind: "ClickHouseInstallationList"
			plural:   "clickhouseinstallations"
			singular: "clickhouseinstallation"
			shortNames: ["chi"]
		}
		scope: "Namespaced"
		versions: [{
			name: "v1"
			additionalPrinterColumns: [
				{jsonPath: ".status.clusters", name: "Clusters", type: "integer"},
				{jsonPath: ".status.shards", name: "Shards", type: "integer"},
				{jsonPath: ".status.hostsCount", name: "Hosts", type: "integer"},
				{jsonPath: ".status.status", name: "Status", type: "string"},
			]
			schema: openAPIV3Schema: {
				type:                                   "object"
				"x-kubernetes-preserve-unknown-fields": true
			}
			served:  true
			storage: true
			subresources: status: {}
		}]
	}
}

#crd_clickhouseinstallationtemplates: {
	apiVersion: "apiextensions.k8s.io/v1"
	kind:       "CustomResourceDefinition"
	metadata: name: "clickhouseinstallationtemplates.clickhouse.altinity.com"
	spec: {
		group: "clickhouse.altinity.com"
		names: {
			kind:     "ClickHouseInstallationTemplate"
			listKind: "ClickHouseInstallationTemplateList"
			plural:   "clickhouseinstallationtemplates"
			singular: "clickhouseinstallationtemplate"
			shortNames: ["chit"]
		}
		scope: "Namespaced"
		versions: [{
			name: "v1"
			schema: openAPIV3Schema: {
				type:                                   "object"
				"x-kubernetes-preserve-unknown-fields": true
			}
			served:  true
			storage: true
		}]
	}
}

#crd_clickhouseoperatorconfigurations: {
	apiVersion: "apiextensions.k8s.io/v1"
	kind:       "CustomResourceDefinition"
	metadata: name: "clickhouseoperatorconfigurations.clickhouse.altinity.com"
	spec: {
		group: "clickhouse.altinity.com"
		names: {
			kind:     "ClickHouseOperatorConfiguration"
			listKind: "ClickHouseOperatorConfigurationList"
			plural:   "clickhouseoperatorconfigurations"
			singular: "clickhouseoperatorconfiguration"
			shortNames: ["chopconf"]
		}
		scope: "Namespaced"
		versions: [{
			name: "v1"
			schema: openAPIV3Schema: {
				type:                                   "object"
				"x-kubernetes-preserve-unknown-fields": true
			}
			served:  true
			storage: true
		}]
	}
}

#crd_clickhousekeeperinstallations: {
	apiVersion: "apiextensions.k8s.io/v1"
	kind:       "CustomResourceDefinition"
	metadata: name: "clickhousekeeperinstallations.clickhouse-keeper.altinity.com"
	spec: {
		group: "clickhouse-keeper.altinity.com"
		names: {
			kind:     "ClickHouseKeeperInstallation"
			listKind: "ClickHouseKeeperInstallationList"
			plural:   "clickhousekeeperinstallations"
			singular: "clickhousekeeperinstallation"
			shortNames: ["chk"]
		}
		scope: "Namespaced"
		versions: [{
			name: "v1"
			additionalPrinterColumns: [
				{jsonPath: ".status.status", name: "Status", type: "string"},
			]
			schema: openAPIV3Schema: {
				type:                                   "object"
				"x-kubernetes-preserve-unknown-fields": true
			}
			served:  true
			storage: true
			subresources: status: {}
		}]
	}
}

#crds: {
	"clickhouseinstallations.clickhouse.altinity.com":              #crd_clickhouseinstallations
	"clickhouseinstallationtemplates.clickhouse.altinity.com":      #crd_clickhouseinstallationtemplates
	"clickhouseoperatorconfigurations.clickhouse.altinity.com":     #crd_clickhouseoperatorconfigurations
	"clickhousekeeperinstallations.clickhouse-keeper.altinity.com": #crd_clickhousekeeperinstallations
}
