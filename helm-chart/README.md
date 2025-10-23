# akv-sync

![Version: 1.0.0](https://img.shields.io/badge/Version-1.0.0-informational?style=flat-square) ![Type: application](https://img.shields.io/badge/Type-application-informational?style=flat-square) ![AppVersion: 1.0.0](https://img.shields.io/badge/AppVersion-1.0.0-informational?style=flat-square)

Azure Key Vault Multi-Region Synchronization Helm Chart

**Homepage:** <https://github.com/yourorg/akv-sync>

## Maintainers

| Name | Email | Url |
| ---- | ------ | --- |
| Your Team | <devops@example.com> |  |

## Source Code

* <https://github.com/yourorg/akv-sync>

## Values

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| affinity | object | `{}` |  |
| authentication.method | string | `"workload-identity"` |  |
| authentication.servicePrincipal.clientId | string | `""` |  |
| authentication.servicePrincipal.clientSecret | string | `""` |  |
| authentication.servicePrincipal.secretRef.key | string | `""` |  |
| authentication.servicePrincipal.secretRef.name | string | `""` |  |
| authentication.servicePrincipal.tenantId | string | `""` |  |
| azure.destinationSubscriptionId | string | `""` |  |
| azure.sourceSubscriptionId | string | `""` |  |
| azureIdentity.clientId | string | `""` |  |
| azureIdentity.enabled | bool | `true` |  |
| azureIdentity.tenantId | string | `""` |  |
| createNamespace | bool | `false` |  |
| cronjob.activeDeadlineSeconds | int | `600` |  |
| cronjob.backoffLimit | int | `1` |  |
| cronjob.concurrencyPolicy | string | `"Forbid"` |  |
| cronjob.failedJobsHistoryLimit | int | `1` |  |
| cronjob.schedule | string | `"*/5 * * * *"` |  |
| cronjob.successfulJobsHistoryLimit | int | `3` |  |
| cronjob.suspend | bool | `false` |  |
| destination.autoCreate | bool | `false` |  |
| destination.namingPattern | string | `"{source_name}-replica"` |  |
| destination.region | string | `"northeurope"` |  |
| destination.resourceGroup | string | `""` |  |
| destination.sku | string | `"standard"` |  |
| destination.tags | object | `{}` |  |
| extraEnv | list | `[]` |  |
| extraVolumeMounts | list | `[]` |  |
| extraVolumes | list | `[]` |  |
| image.pullPolicy | string | `"Always"` |  |
| image.repository | string | `"youracrrepo.azurecr.io/akv-sync"` |  |
| image.tag | string | `"latest"` |  |
| imagePullSecrets | list | `[]` |  |
| namespaceOverride | string | `""` |  |
| nodeSelector | object | `{}` |  |
| notifications.email.enabled | bool | `false` |  |
| notifications.email.from | string | `"akv-sync@example.com"` |  |
| notifications.email.smtpPassword | string | `""` |  |
| notifications.email.smtpPasswordSecret.key | string | `"password"` |  |
| notifications.email.smtpPasswordSecret.name | string | `"smtp-credentials"` |  |
| notifications.email.smtpPort | int | `587` |  |
| notifications.email.smtpServer | string | `"smtp.example.com"` |  |
| notifications.email.smtpUser | string | `"notifications@example.com"` |  |
| notifications.email.to[0] | string | `"ops-team@example.com"` |  |
| notifications.email.to[1] | string | `"devops@example.com"` |  |
| notifications.email.useTLS | bool | `true` |  |
| notifications.enabled | bool | `true` |  |
| notifications.events.onFailure | bool | `true` |  |
| notifications.events.onSuccess | bool | `true` |  |
| notifications.events.onWarning | bool | `true` |  |
| notifications.slack.channel | string | `"#alerts"` |  |
| notifications.slack.enabled | bool | `true` |  |
| notifications.slack.iconEmoji | string | `":key:"` |  |
| notifications.slack.username | string | `"AKV Sync Bot"` |  |
| notifications.slack.webhookUrl | string | `""` |  |
| notifications.teams.enabled | bool | `false` |  |
| notifications.teams.webhookSecret.key | string | `"url"` |  |
| notifications.teams.webhookSecret.name | string | `"teams-webhook"` |  |
| notifications.teams.webhookUrl | string | `""` |  |
| notifications.telegram.botToken | string | `""` |  |
| notifications.telegram.botTokenSecret.key | string | `"token"` |  |
| notifications.telegram.botTokenSecret.name | string | `"telegram-credentials"` |  |
| notifications.telegram.chatId | string | `""` |  |
| notifications.telegram.chatIdSecret.key | string | `"chatId"` |  |
| notifications.telegram.chatIdSecret.name | string | `"telegram-credentials"` |  |
| notifications.telegram.enabled | bool | `false` |  |
| pod.annotations | object | `{}` |  |
| pod.containerSecurityContext.allowPrivilegeEscalation | bool | `false` |  |
| pod.containerSecurityContext.capabilities.drop[0] | string | `"ALL"` |  |
| pod.containerSecurityContext.readOnlyRootFilesystem | bool | `true` |  |
| pod.containerSecurityContext.runAsNonRoot | bool | `true` |  |
| pod.containerSecurityContext.runAsUser | int | `1000` |  |
| pod.labels | object | `{}` |  |
| pod.securityContext.fsGroup | int | `1000` |  |
| pod.securityContext.runAsNonRoot | bool | `true` |  |
| pod.securityContext.runAsUser | int | `1000` |  |
| pod.securityContext.seccompProfile.type | string | `"RuntimeDefault"` |  |
| priorityClassName | string | `""` |  |
| resources.limits.cpu | string | `"500m"` |  |
| resources.limits.memory | string | `"512Mi"` |  |
| resources.requests.cpu | string | `"100m"` |  |
| resources.requests.memory | string | `"128Mi"` |  |
| serviceAccount.annotations | object | `{}` |  |
| serviceAccount.create | bool | `false` |  |
| serviceAccount.labels | object | `{}` |  |
| serviceAccount.name | string | `"akv-sync-sa"` |  |
| source.excludeKeyvaults | list | `[]` |  |
| source.keyvaults[0].name | string | `"source-keyvault-westeurope"` |  |
| source.keyvaults[0].region | string | `"westeurope"` |  |
| source.resourceGroup | string | `""` |  |
| source.selectionMode | string | `"specific"` |  |
| source.tags | object | `{}` |  |
| sync.dryRun | bool | `false` |  |
| sync.enableDeletion | bool | `false` |  |
| sync.excludeSecrets | list | `[]` |  |
| sync.logLevel | string | `"INFO"` |  |
| sync.syncDisabledSecrets | bool | `true` |  |
| tolerations | list | `[]` |  |

----------------------------------------------
Autogenerated from chart metadata using [helm-docs v1.14.2](https://github.com/norwoodj/helm-docs/releases/v1.14.2)
