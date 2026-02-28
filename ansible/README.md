## Vault 
- I already encrypted the information of hosts using this command 
``` sh
ansible-vault encrypt --vault-password-file=.ansible-vault-secret-devlocal inventory/devlocal/host_vars/*
```

- To view vault using the command bellow
``` sh
ansible-vault view --vault-password-file=.ansible-vault-secret-devlocal inventory/devlocal/host_vars/node-db-01.yml
```

- To decrypt vault 
``` sh
ansible-vault encrypt --vault-password-file=.ansible-vault-secret-devlocal inventory/devlocal/host_vars/*
```
You should only decrypt vaul when you want to update, then remember to encrypt it again before commit

## Run ansible 
---
**NOTE**
Please read about [tags](https://docs.ansible.com/ansible/latest/playbook_guide/playbooks_tags.html) in ansible
---

- Run all tags the playbook
``` sh
ansible-playbook --vault-password-file=.ansible-vault-secret-devlocal -i inventory/devlocal/ubuntu/hosts.yml playbooks/install-postgresql-cluster.yml --tags rc_all
```

- Run specific tags the playbook
``` sh
ansible-playbook --vault-password-file=.ansible-vault-secret-devlocal -i inventory/devlocal/ubuntu/hosts.yml playbooks/install-postgresql-cluster.yml --tags config_psql,config_pgpool
```
Change the tags to the tags you want to run
