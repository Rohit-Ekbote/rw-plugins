### Email — disabled (verification skipped)

You chose NOT to configure email. The kit sets `papi.skipEmailVerification: "true"` (PAPI `SKIP_EMAIL_VERIFICATION=true`), so accounts can sign up and log in without a verified email address — necessary because the platform defaults to ENFORCING verification, which would otherwise lock users out when no email provider is wired.

> **Security note.** The chart labels this a dev convenience — it weakens account security (anyone can register any email without proving they control it). Use it only where unverified-email login is acceptable. To harden later, configure an SMTP relay (re-run the wizard, choose the SMTP option) and drop the skip.
