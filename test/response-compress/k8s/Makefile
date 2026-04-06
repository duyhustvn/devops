service=response-compress-test
apply:
	kubectl apply -f .

restart:
	kubectl rollout restart deploy $(service)

undeploy:
	kubectl uninstall $(service)
