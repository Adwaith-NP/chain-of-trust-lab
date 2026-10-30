# Attacker instance — defeating a MITM with the CA

This instance is the "attack" half of the Chain of Trust lab. It shows that
**spoofing the name alone is not enough to impersonate an HTTPS site**: the
attacker redirects `social.lab` by poisoning the victim's `/etc/hosts`, but
still cannot present a *certificate* for it that the lab Root CA signed, so the
victim's browser raises a warning before any password is typed.

- **IP on the lab network:** `172.28.0.66`
- **What it serves:** a pixel copy of the `social.lab` login page, over HTTPS,
  with a **self-signed** certificate for `CN=social.lab` (made by
  `make_cert.sh`). It does **not** chain to the lab Root CA.
- **What it does with a login:** prints the username and password to the
  operator's terminal and appends them to `harvested.log`, then redirects the
  victim to the real `https://social.lab/login` so the next (real, padlocked)
  attempt succeeds and nothing looks wrong.

Nothing here is a new attack technique — it's the standard SEED PKI exercise.
Everything stays on the isolated `labnet` Docker network against the seeded
demo accounts (`alice` / `alice123`, …).

## Files

| File | What it is |
|------|------------|
| `app.py` | the credential harvester (Flask, on `127.0.0.1:8000`) |
| `templates/` | the cloned login page (copied from `social/templates`) |
| `make_cert.sh` | mints the self-signed `social.lab` certificate |
| `apache/attacker.conf` | Apache vhost: HTTPS as `social.lab`, proxy to the app |
| `apache/start.sh` | container start-up (cert → app → Apache → tail logs) |
| `attack.sh` | operator console: shows status, tails captured logins |
| `spoof.sh` | host switch: poison Alice's `/etc/hosts` so `social.lab` points at the attacker, or undo it |

## Running the demo

Start the lab (the attacker builds with everything else):

```bash
docker compose up -d --build
```

**1. Watch the attacker's terminal.** In one shell, tail the captures:

```bash
docker compose logs -f attacker          # or: docker compose exec attacker ./attack.sh
```

**2. Baseline — no attack.** In Alice's Firefox (`http://localhost:5003`) open
`https://social.lab`. It loads with a padlock: her Firefox trusts the lab Root
CA, and the real server's certificate was signed by it.

**3. Spoof the name on Alice's machine.** This adds `172.28.0.66 social.lab`
to Alice's `/etc/hosts`, which her resolver checks before the lab DNS
(`hosts: files dns`), so on her machine the name now points at the attacker:

```bash
./attacker/spoof.sh on        # alice's /etc/hosts: 172.28.0.66 social.lab
```

**4. Alice visits `https://social.lab` again.** Now her request goes to the
attacker. Firefox shows a full-page certificate warning
(`SEC_ERROR_UNKNOWN_ISSUER` / "Warning: Potential Security Risk Ahead") —
because the attacker's certificate is self-signed, not signed by the lab CA.
**This is the defence working.** A careful user stops here and no password is
sent.

**5. Where does the attack actually stop?** Only if the victim clicks
*Advanced → Accept the Risk and Continue* does the fake page open. A login typed
there is captured and shown in the attacker's terminal:

```
======================================================================
[2026-10-31 12:00:00 UTC] CAPTURED social.lab login  username='alice'  password='alice123'  victim=172.28.0.100
======================================================================
```

…and Alice is bounced to the real site. So the attack is stopped **at TLS
certificate validation**, before the application ever sees the request — the
browser warning is the last line of defence, and heeding it stops it fully.

**6. Restore when done:**

```bash
./attacker/spoof.sh off       # removes the /etc/hosts line - lab DNS again
```

> Firefox caches DNS for about a minute. After flipping `spoof.sh`, give it a
> moment or restart Firefox if the old destination sticks.

## Why the attacker can't avoid the warning

To serve `social.lab` without a warning, the attacker would need a certificate
for `social.lab` signed by the lab Root CA. The CA only issues one to the party
that registered the domain in the CA portal and controls its DNS record, and it
writes the name into the certificate itself. The attacker can make a
certificate that *says* `social.lab`, but it can only sign it with its own key —
which no browser trusts. That is the entire value of the CA.
