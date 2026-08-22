module: "opmodel.dev/modules/nvidia_device_plugin@v2"
language: {
	version: "v0.17.0"
}
source: {
	kind: "self"
}
deps: {
	"opmodel.dev/catalogs/opm@v2": {
		v: "v2.0.0-alpha.4"
	}
	"opmodel.dev/core@v2": {
		v: "v2.0.0-alpha.5"
	}
}
