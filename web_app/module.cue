// Package web_app defines a minimal stateless web application module.
// Modeled on the opm-operator hello-web test fixture, extended with an Expose
// trait so it renders a Service alongside the Deployment. Used to exercise the
// authored-#ModuleInstance (ModulePackage CR) render path on the OPM core
// catalog (opmodel.dev/catalogs/opm@v1).
package web_app

import (
	m "opmodel.dev/core@v1"
	res "opmodel.dev/catalogs/opm/resources"
)

m.#Module

metadata: {
	modulePath:  "opmodel.dev/modules"
	name:        "web-app"
	version:     "0.1.0"
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
