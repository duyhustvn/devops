service=mongodb

apply:
	helm upgrade --install $(service) charts/mongodb-18.6.21.tgz -f helm/values.yml

uninstall: 
	helm uninstall $(service)

remove-pvc:
	kubectl delete pvc -l app.kubernetes.io/name=mongodb
