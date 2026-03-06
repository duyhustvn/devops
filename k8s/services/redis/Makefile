service=redis

apply:
	helm upgrade --install $(service) bitnami/redis --version 25.3.2 -f helm/values.yml

undeploy: 
	helm uninstall $(service)
