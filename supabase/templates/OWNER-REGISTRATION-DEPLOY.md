# Owner registration live activation gates

No settings in this file have been applied. No real message has been sent.

- Keep signup enabled and email confirmation required (mailer_autoconfirm=false).
- Set Auth minimum password length12 and required lower/upper/digits/symbols policy. The new owner UI requires all four, confirmation and no spaces. UI validation alone is not protection against direct Auth calls.
- Configure a verified production SMTP sender, supported rate limits and appropriate domain authentication. Do not use the rejected test-only provider route.
- Set Confirm signup email content to owner-confirm-signup.html with the native .Token variable, not a link-only template. Native Auth verifies via verifyOtp(type=signup), so expiry, hashing, replay prevention and throttling remain the Auth service's responsibility. Validate current token length/expiry against the deployed Auth configuration.
- Do not log real codes or passwords. The demo capture is synthetic and exists only in the demo implementation, not the real client. Production code never renders the code.
- Apply reviewed owner migrations only after the required backup/restore/pre-notice gates. The owner RPC reads auth.users.email_confirmed_at; browser metadata cannot confirm an account.
- Staging acceptance: invalid/expired/replayed code and unconfirmed password login refused; real mail delivery; confirmed password login works; recover password and revoke other sessions; wrong hotel isolation; replay creates no duplicate hotel or branches. Real-device and delivery checks are pending.
- Signup draft persistence contains only owner name, hotel name, slug and branch location fields. Password/confirmation/code are not persisted there. Retrying hotel creation after confirmation or reopening the page resumes nonsecret draft data. A new owner can finish account verification separately from hotel creation.

Sources checked:
https://supabase.com/docs/guides/auth/auth-email-templates
https://supabase.com/docs/guides/auth/passwords
