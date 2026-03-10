service=telegraf-ds

apply:
	helm upgrade --install $(service) influxdata/telegraf-ds -f helm/values.yml

undeploy:
	helm uninstall $(service)