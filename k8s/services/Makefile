create-config-map:
	kubectl apply -f configmaps.yaml

create-secret:
	sops -d secrets.enc.yaml | kubectl apply -f -
