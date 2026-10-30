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
| `forge_cert.sh` | option 2: steal the CA root key from the `ca` instance and sign a `social.lab` cert with it |
| `mode.sh` | pick which cert the fake site serves: `warn` (self-signed) or `trusted` (forged CA-signed) |

## Two options

The attacker serves the same fake login page both times; only the certificate
it presents changes (pick it with `mode.sh`):

| Option | Cert served | What a spoofed victim sees | Lesson |
|--------|-------------|----------------------------|--------|
| **1 — `warn`** (default) | self-signed `social.lab` | a certificate **warning** | the CA stops the MITM |
| **2 — `trusted`** | `social.lab` **forged with the stolen CA key** | **no warning**, green padlock | a stolen CA key defeats the CA |

Option 1 is the setup from before and is unchanged. Option 2 is the escalation
below.

## Option 1 — the certificate warning (default)

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

### Why option 1's attacker can't avoid the warning

To serve `social.lab` without a warning, the attacker would need a certificate
for `social.lab` signed by the lab Root CA. The CA only issues one to the party
that registered the domain in the CA portal and controls its DNS record, and it
writes the name into the certificate itself. The attacker can make a
certificate that *says* `social.lab`, but it can only sign it with its own key —
which no browser trusts. That is the entire value of the CA… **unless the
attacker gets the CA's own key.**

## Option 2 — a stolen CA key defeats the warning

This is the catastrophe case: what happens when the CA's **root private key**
is compromised. In this lab that key lives in the `ca` instance and has no
passphrase, so a single stolen copy is enough to sign anything.

**1. Steal the CA key and forge a certificate** (from the host):

```bash
./attacker/mode.sh trusted
```

This runs `forge_cert.sh`, which copies the CA root key out of the `ca`
instance and uses it to sign the attacker's own `social.lab` certificate — a
real leaf cert that chains to `CA Lab Root CA`. The attacker then serves that
cert instead of the self-signed one. (The exfiltration is simulated by reading
the key from the `ca` container; a real breach is the only hard part, and this
lab's unprotected key shows why that key must never leak.)

**2. Spoof the name on Alice's machine**, exactly as before:

```bash
./attacker/spoof.sh on
```

**3. Alice visits `https://social.lab`.** This time **there is no warning**.
Firefox trusts the lab Root CA; the forged certificate is validly signed by it
and names `social.lab`, so the chain checks out and the padlock is green. The
page looks genuine, Alice logs in, and the credentials land in the attacker's
terminal — with no visual cue that anything is wrong.

**4. Restore when done:**

```bash
./attacker/spoof.sh off        # stop redirecting Alice
./attacker/mode.sh warn        # go back to the self-signed cert (option 1)
```

Check which certificate is live at any time with `./attacker/mode.sh status`.

### What this teaches

A CA warning only protects users while the CA's private key stays secret. Once
that key is stolen, the attacker can mint a trusted certificate for *any* name,
and TLS gives the victim no signal at all. That is why a real CA guards its root
key offline in an HSM, and why a known key compromise forces the whole PKI to
revoke and replace the root — every client must stop trusting it. The fix for
option 1 (the CA) is only as strong as the secrecy of the CA's key, which is
what option 2 removes.
