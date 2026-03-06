- Install Envoy Gateway from Dockerhub
```
helm install eg oci://docker.io/envoyproxy/gateway-helm --version v1.5.0 -f helm/values.yml -n envoy-gateway-system --create-namespace
```
