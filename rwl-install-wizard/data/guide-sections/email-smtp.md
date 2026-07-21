### Email — SMTP relay

You chose to send platform email through an SMTP relay. The kit sets
`email.provider: smtp` plus the relay coordinates, and keeps email verification
**enforced** (`papi.skipEmailVerification: "false"`).

**You must pre-create the credentials Secret `<SMTP_EXISTING_SECRET>`** in the release namespace (the wizard never handles secret material) — standard keys `EMAIL_SMTP_USERNAME` / `EMAIL_SMTP_PASSWORD`:

    kubectl -n <NAMESPACE> create secret generic <SMTP_EXISTING_SECRET> \
      --from-literal=EMAIL_SMTP_USERNAME='<user>' \
      --from-literal=EMAIL_SMTP_PASSWORD='<pass>'

- Relay `<SMTP_HOST>` on port `<SMTP_PORT>`, TLS mode `<SMTP_TLS_MODE>` — the port and TLS mode must match your relay (587=STARTTLS, 465=SSL, 25=none).
- Envelope sender `<EMAIL_FROM_ADDRESS>`.
- The Secret may also carry `EMAIL_PROVIDER=smtp` and override the host/port/tls keys; keys set in the Secret win over the ConfigMap.
