module: "opmodel.dev/modules/clickstack@v0"
language: {
	version: "v0.15.0"
}
source: {
	kind: "self"
}
deps: {
	"opmodel.dev/clickhouse_operator/v1alpha1@v1": {
		v: "v1.0.1"
	}
	"opmodel.dev/core/v1alpha1@v1": {
		v: "v1.3.10"
	}
	"opmodel.dev/mongodb_operator/v1alpha1@v1": {
		v: "v1.0.1"
	}
	"opmodel.dev/opm/v1alpha1@v1": {
		v: "v1.5.9"
	}
	"opmodel.dev/otel_collector/v1alpha1@v1": {
		v: "v1.0.1"
	}
}
