service=prometheus

apply: 
	helm upgrade --install $(service) oci://ghcr.io/prometheus-community/charts/kube-prometheus-stack -f helm/values.yml
uninstall: 
	helm uninstall $(service)
