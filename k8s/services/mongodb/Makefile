service=mongodb

apply:
	helm upgrade --install $(service) bitnami/mongodb --version 18.1.10 -f helm/values.yml

uninstall: 
	helm uninstall $(service)

remove-pvc:
	kubectl delete pvc -l app.kubernetes.io/name=mongodb
