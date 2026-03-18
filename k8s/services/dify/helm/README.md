## Install/Update chart

create your own values file , save as `values.yaml` to override the default values of chart. For example
```yaml
pluginDaemon:
  enabled: true
```
Then install/upgrade the app with helm command

```sh
helm upgrade --install dify ./ -f values.yaml --debug
```

## References:
- [https://github.com/douban/charts](https://github.com/douban/charts)
- [https://github.com/BorisPolonsky/dify-helm](https://github.com/BorisPolonsky/dify-helm)
