### Chart-managed Gateway

The kit sets `ingress.gateway.gatewayClassName: <GATEWAY_CLASS>` and the chart
creates the `Gateway` for you. The named GatewayClass (`<GATEWAY_CLASS>`) must
already exist and be reconciled by your Gateway API implementation
(`kubectl get gatewayclass`).
