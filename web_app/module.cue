// Package web_app defines a minimal stateless web application module.
// Modeled on the opm-operator hello-web test fixture, extended with an Expose
// trait so it renders a Service alongside the Deployment. Used to exercise the
// authored-#ModuleInstance (ModulePackage CR) render path on the OPM core
// catalog (opmodel.dev/catalogs/opm@v2).
//
// OPM v2 line: path major v1 (the v1 train publishes this registry path at
// major v0 — cross-train major separation), core@v2 identity reshape
// (complete modulePath with major, identity/ package, derived fqn), and the
// version-segment catalog imports (resources/v1beta1 etc.).
package web_app

import (
	m "opmodel.dev/core@v2"
	res "opmodel.dev/catalogs/opm/resources/v1beta1"
)

m.#Module

// Module metadata — modulePath is the COMPLETE CUE module path including the
// major, byte-identical to cue.mod's module field and identity/identity.cue;
// fqn/registryPath/uuid derive from it (enhancement 0010).
metadata: {
	name:        "web_app"
	modulePath:  "opmodel.dev/modules/web_app@v1"
	version:     "1.0.0"
	description: "Minimal stateless web app — renders a Deployment + Service"
}

#config: {
	// Container image
	image: res.#Image & {
		repository: string | *"nginx"
		tag:        string | *"1.27"
		digest:     string | *""
	}

	// Replica count
	replicas: int & >=1 | *1

	// Container/Service port
	port: int & >0 & <=65535 | *80

	// Kubernetes Service type
	serviceType: "ClusterIP" | "NodePort" | "LoadBalancer" | *"ClusterIP"
}

debugValues: {
	image: {
		repository: "nginx"
		tag:        "1.27"
		digest:     ""
	}
	replicas:    1
	port:        80
	serviceType: "ClusterIP"
}
