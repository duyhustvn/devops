service=eg
namespace=envoy-gateway-system

apply: 
	helm install $(service) oci://docker.io/envoyproxy/gateway-helm --version v1.5.0 -f helm/values.yml -n $(namespace) --create-namespace
	kubectl apply -f k8s/.

undeploy: 
	kubectl delete -f k8s/.
	kubectl -n $(service) delete ds envoy-default-eg-e41e7b31
	helm uninstall $(service) -n $(namespace)

