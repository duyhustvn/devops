service=redis

apply:
	helm upgrade --install $(service) ./helm/redis-25.3.2.tgz -f helm/values.yml

uninstall: 
	helm uninstall $(service)

delete-pvc:
	kubectl delete pvc -l app.kubernetes.io/name=$(service)
