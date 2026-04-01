service=dify
namespace=backend

apply: 
	helm upgrade --install $(service) --values helm/values-devlocal.yaml helm -n $(namespace) --create-namespace
	kubectl apply -f k8s/.

uninstall: 
	helm uninstall $(service) -n $(namespace)
