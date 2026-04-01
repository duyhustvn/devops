## Sops and age
- Install age
```
sudo apt install age
```

- Create key age 
```
mkdir -p ~/.config/sops/age
age-keygen -o ~/.config/sops/age/keys.txt
grep '^# public key:' ~/.config/sops/age/keys.txt
```
You can get the public key in format age1...

Replace the public key into file .sops.yaml field creation_rules.age

- Encypt file secret, go to folder k8s/services
```
sops -e -i secrets.enc.yaml
```

- Edit secrets.enc.yaml 
```
sops secrets.enc.yaml
```


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