## Install helmfile and helm
- Install helmfile
```
curl -sL https://github.com/helmfile/helmfile/releases/download/v1.4.1/helmfile_1.4.1_linux_amd64.tar.gz | tar -xzC /tmp helmfile && sudo mv /tmp/helmfile /usr/local/bin/
```

- Install helm
```
curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
```

## Install helm-diff plugin
```
helm plugin install https://github.com/databus23/helm-diff
```