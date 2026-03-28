# Kiểm tra nếu ENV không được truyền vào thì báo lỗi ngay lập tức
ifeq ($(ENV),)
$(error ENV is required. Example: make diff ENV=devlocal or make apply ENV=lab)
endif

service=local-path-provisioner

# Xem sự khác biệt
diff:
	helmfile -e $(ENV) diff

# Thực thi cài đặt
apply:
	helmfile -e $(ENV) apply
	kubectl patch storageclass local-path -p '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'

# Render ra file YAML để kiểm tra (debug)
template:
	helmfile -e $(ENV) template

# Đồng bộ trạng thái (cài mới hoặc cập nhật toàn bộ)
sync:
	helmfile -e $(ENV) sync

# Gỡ bỏ hoàn toàn các release định nghĩa trong helmfile của môi trường đó
destroy:
	@echo "DANGER: Dang xoa toan bo Redis tren moi truong $(ENV)..."
	helmfile -e $(ENV) destroy

delete-pvc:
	kubectl delete pvc -l app.kubernetes.io/name=$(service)