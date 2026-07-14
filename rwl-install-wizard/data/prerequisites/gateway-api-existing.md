### Existing Gateway

The kit sets `ingress.gateway.existingGateway` to your externally-managed Gateway
— `<GATEWAY_NAME>` in namespace `<GATEWAY_NAMESPACE>` — and the chart creates only
HTTPRoutes that attach to it as their `parentRef`. Before install:

- confirm that Gateway exists
  (`kubectl get gateway <GATEWAY_NAME> -n <GATEWAY_NAMESPACE>`);
- confirm it exposes a listener your HTTPRoutes can bind to on `<DOMAIN>`
  (hostname match + allowed routes).
