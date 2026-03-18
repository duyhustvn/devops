service=dify

apply: 
	helm upgrade --install $(service) --values helm/values-devlocal.yaml helm
	kubectl apply -f k8s/.

uninstall: 
	helm uninstall $(service)
