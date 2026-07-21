## Empty EMAIL_PROVIDER crashes PAPI at startup

**Symptom:** PAPI (FastAPI) crash-loops at startup after an email-related change.

**Cause:** the chart renders `EMAIL_PROVIDER` from `email.provider`; an EMPTY string (`EMAIL_PROVIDER=""`) is rejected by the FastAPI email-backend factory on RW-1135+ images and aborts startup. The chart's own ConfigMap comment warns: "Never render EMAIL_PROVIDER='' — FastAPI factory rejects empty string."

**Fix / how the wizard avoids it:** the `email-smtp` option pins `email.provider: "smtp"` explicitly, so the wizard never emits an empty provider. If you hand-edit `email.*`, always set a non-empty `email.provider` (`smtp` or `mailgun`) — never leave it blank.

_Source: chart values.yaml `email.provider` doc + templates/configmap.yaml._
