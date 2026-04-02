# Kiểm tra nếu ENV không được truyền vào thì báo lỗi ngay lập tức
ifeq ($(ENV),)
$(error ENV is required. Example: make diff ENV=devlocal or make apply ENV=lab)
endif

service=dify
namespace=backend

apply: 
	helm upgrade --install $(service) \
		-f helm/values-common.yaml \
		-f helm/values-$(ENV).yaml \
		helm/ -n $(namespace) --create-namespace
	kubectl apply -f k8s/.

uninstall: 
	helm uninstall $(service) -n $(namespace)
