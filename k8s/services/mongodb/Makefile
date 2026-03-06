service=mongodb

apply:
	helm upgrade --install $(service) bitnami/mongodb --version 18.1.10 -f helm/values.yml

undeploy: 
	helm uninstall $(service)
