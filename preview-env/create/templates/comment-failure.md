### `${APP_NAME}`
* __Status:__ :x:
* __ArgoCD:__ :link: [Link](https://${ARGOCD_SERVER}/applications/argocd/${APP_NAME}?view=tree&resource=)([degraded resources](https://${ARGOCD_SERVER}/applications/argocd/${APP_NAME}?view=tree&resource=health%3ADegraded))
* __Deployment Jobs:__ :clipboard: [Link](https://github.com/${REPO}/actions/runs/${RUN_ID})
* __Troubleshooting Tips:__ :spanner:
```
Typical Errors
--------------
ErrImagePull / ImagePullBackOff - The CI hasn't finished building the image yet -> increase "argocd_wait_for_sync_timeout"
Readiness / Liveness probe failed - The container is not fully functional yet -> increase "argocd_wait_for_sync_timeout"

```
* __Details for Troubleshooting:__ :ring_buoy:
```
${KUBERNETES_EVENTS}
```

```
${ARGOCD_APP_DETAILS}
```
