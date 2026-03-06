## Install 
```
helm upgrade --install prometheus oci://ghcr.io/prometheus-community/charts/kube-prometheus-stack -f helm/values.yml
```

## Grafana
- Get grafana user
```
kubectl get secret prometheus-grafana -o jsonpath={.data.admin-user} | base64 -d; echo
```

- Get grafana password
```
kubectl get secret prometheus-grafana -o jsonpath={.data.admin-password} | base64 -d; echo
```

## Forward Port 
- Grafana

```
kubectl port-forward svc/prometheus-grafana 3000:80
```
