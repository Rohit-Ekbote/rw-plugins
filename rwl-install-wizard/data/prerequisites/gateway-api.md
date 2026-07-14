## Gateway API routing

You chose Gateway API routing, so the kit emits `ingress.type: gateway`. Against
chart 0.2.58+ the chart renders `Gateway` (chart-managed mode) and `HTTPRoute`
resources for the platform Services instead of `Ingress` objects. TLS certificate
source is still configured by your Cluster-environment choice — the chart shares
`ingress.tls.*` across both routing modes.

You are responsible for the cluster-side Gateway API plumbing:

- A **Gateway API implementation** installed with its CRDs (`gateway.networking.k8s.io/v1`)
  — e.g. Istio, Cilium, NGINX Gateway Fabric, or Envoy Gateway.
- A **GatewayClass** the implementation reconciles (`kubectl get gatewayclass`).
  - **Chart-managed Gateway** (`gatewayClassRouting`): the kit sets
    `ingress.gateway.gatewayClassName` to the class you named and the chart
    creates the `Gateway`. The named GatewayClass must exist.
  - **Existing Gateway** (`gatewayExistingRouting`): the kit sets
    `ingress.gateway.existingGateway.{name,namespace}` and the chart creates only
    HTTPRoutes that attach to your Gateway as their `parentRef`. That Gateway must
    already exist and expose a listener your HTTPRoutes can bind to on `<your domain>`.

### TLS caveat

The chart's `Gateway` template wires cert-manager automatically only for the
**ClusterIssuer** TLS source (it stamps `cert-manager.io/cluster-issuer` on the
Gateway, so cert-manager's Gateway-API support / `gateway-shim` must be enabled
in your cert-manager install). For the **namespace Issuer** or **bring-your-own
Secret** TLS sources under Gateway API, ensure the certificate Secret that the
Gateway's `certificateRefs` points at is provisioned in the Gateway's namespace.
