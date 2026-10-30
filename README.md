# Chain of Trust Lab

A Docker cyber range for PKI. Run your own Certificate Authority, DNS
server and HTTPS websites, enroll servers safely with one-time codes, and
browse it all as real users — then attack it, to see how a
man-in-the-middle steals traffic when there is no trusted CA, and how
certificates stop the same attack.

It runs as a single Docker Compose project. Each instance is a service
with its own folder, Dockerfile and web portal:

| Instance | Folder     | Inside the lab     | From the Mac (see below) | Lab IP        | Other ports |
|----------|------------|--------------------|--------------------------|---------------|-------------|
| `ca`     | `ca/`      | https://ca.lab     | https://ca.lab:5001      | 172.28.0.10   | —           |
| `dns`    | `dns/`     | https://dns.lab    | https://dns.lab:5002     | 172.28.0.53   | DNS on 127.0.0.1:1053 (udp+tcp) |
| `social` | `social/`  | https://social.lab | https://social.lab:5005  | 172.28.0.20   | —           |
| `alice`  | `alice/`   | —                  | http://localhost:5003    | 172.28.0.100  | —           |
| `adwaith`| `adwaith/` | —                  | http://localhost:5004    | 172.28.0.101  | —           |

Every web login is `admin` / `admin123`. All instances share the `labnet`
network (172.28.0.0/24) with the fixed IPs above, so they reach each other
by IP — and by name once a domain is registered in the DNS portal
(`ca.lab` -> 172.28.0.10 is in; `dns.lab` always resolves, because the DNS
server knows its own name).

## How the web servers answer

Every web server — CA portal, DNS portal, Social Lab — follows one rule, so
a certificate and the site behind it always mean the same thing:

| Request                                        | Answer |
|------------------------------------------------|--------|
| `http://` anything (port 80, the front door)   | redirected to `https://<its domain>` — plain HTTP never gets a page |
| `https://<its domain>`                         | the site |
| `https://<its IP>`, `localhost` or another name | refused: the certificate names only the domain, and the server itself answers `421 Misdirected Request` |

Each server's domain is its `SITE_DOMAIN` setting in `docker-compose.yml`,
and its certificate carries only that name (`DNS:ca.lab`, ...). Until a
server has its certificate, its front door says the site is closed and
nothing listens on 443.

From the Mac: Docker publishes the sites on `localhost`, one port each, but
the sites refuse `localhost`. Point the names at your Mac once (asks for
your password):

```bash
echo "127.0.0.1 ca.lab dns.lab social.lab" | sudo tee -a /etc/hosts
```

then use https://ca.lab:5001, https://dns.lab:5002 and
https://social.lab:5005 (trusted once the root CA is in the keychain — see
the ca section). Inside the lab, Alice's and Adwaith's Firefox need no setup.

## Running the project

```bash
docker compose up -d --build   # build + start every instance
docker compose ps              # list all instances of this project
docker compose logs -f dns     # follow one instance's logs
docker compose exec ca bash    # shell into an instance
docker compose down            # stop the whole project
```

Each service folder is volume-mounted into its container, so data
(demoCA, issued certs, databases) lives on the host and survives rebuilds.

## Instance: ca — Certificate Authority

OpenSSL CA (`demoCA` layout from `ca/openssl.cnf`) behind a Flask portal.
The CA certificate is public at `/ca-certificate`.

### Certificate enrollment (one-time codes)

1. **Operator** — in the CA portal, register the company: name, the domain
   the certificate is for, and its server's IP. The portal shows a message
   to send the company over a secure channel: a one-time code, the CA's
   SHA-256 fingerprint and three commands. The code is shown only then;
   the CA stores just its hash.
2. **Operator** — register the domain -> IP in the DNS portal, as usual.
3. **Company, on its server** — run the three commands: download the CA
   certificate and check its fingerprint, download `enroll.sh` over the
   now-verified connection and read it, run it and paste the code.
4. **`enroll.sh`** ([ca/enroll.sh](ca/enroll.sh), public at `/enroll.sh`)
   creates the private key on the server — it never leaves — sends only a
   CSR and the code, then checks the certificate (matches the key, chains to
   the CA, names the domain) and saves `key.pem`, `cert.pem` and
   `ca-root.pem` in `./server`.

The CA signs only when every rule holds:

| Rule | Stops |
|------|-------|
| the code works once and expires (24 h, `ENROLL_CODE_HOURS`); the operator can cancel it | a leaked or old code |
| the request must come from the registered IP, and the lab DNS must point the domain there | a code used from another machine |
| the CSR's signature must verify, RSA keys ≥ 2048 bits | forged or weak requests |
| the CA writes the certificate itself: `CN` and `subjectAltName` = the registered domain, web-server use only, `CA:FALSE` | a request asking for other names (`ca.lab`, ...) |
| the first download is checked against the fingerprint from the message | a fake `ca.lab` handing out a different script |

Each issuance lands in `demoCA/index.txt`; the working files (request,
extensions, certificate) are kept in `ca/enrollments/<id>/`. *New code* on
a company's row starts a renewal; any earlier code stops working.

Registrations made with the old flow (where the CA generated the company's
private key) are listed read-only as *Earlier registrations*.

One-time setup (already done if `ca/demoCA` exists):

```bash
docker compose exec ca ./setup_ca.sh           # root CA key + certificate
docker compose exec ca ./make_server_cert.sh   # HTTPS cert for the portal itself
docker compose restart ca
```

The portal serves HTTPS with a certificate issued by its own CA. To make
your browser trust it, add the root certificate to the Mac keychain:

```bash
sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain ca/demoCA/cacert.pem
```

Inspect an issued certificate (here: enrollment 1):

```bash
docker compose exec ca openssl x509 -in enrollments/1/cert.pem -noout -text
```

## Instance: dns — DNS server + registration portal

A small authoritative DNS server (pure Python, dnslib) and a Flask portal
in one process. Register a domain name -> IP with company details; the DNS
server answers A queries straight from the same SQLite database, so new
domains resolve immediately.

Its HTTPS certificate is issued by the `ca` instance — a real cross-instance
flow (key + CSR made in dns, signed by ca, recorded in demoCA/index.txt):

```bash
./make_dns_cert.sh    # from the host, project root; restarts dns itself
```

Names not in the database are forwarded to an upstream resolver (8.8.8.8,
override with `UPSTREAM_DNS`), so machines using this server as their
resolver still reach the normal internet.

Test a registered domain from your Mac:

```bash
dig @127.0.0.1 -p 1053 example.lab +short
```

## Instance: social — Social Lab (photo sharing)

A small photo-sharing site: post photos with a caption, see everyone's
posts, like and comment. Log in with `admin` / `admin123` (the same as the
CA and DNS portals) or create an account on the sign-up page. You can
delete your own posts; admin can delete any post. Photos are checked by
their content (JPEG, PNG, GIF, WebP, up to 8 MB) and only shown to people
who are logged in.

It starts uninstalled. Install it once:

```bash
docker compose exec social ./install.sh
```

The installer checks requirements, creates `uploads/` and `server/`,
creates the database and the admin account, then offers the HTTPS steps.
They are deliberately manual — the installer only prints the checklist:
private key and CSR on the server, the `social.lab -> 172.28.0.20` record
in the DNS portal, signing at the CA, checking the certificate, restart.
Print the checklist again any time:

```bash
docker compose exec social ./install.sh https
```

The automatic route does the same with the CA's enrollment: the operator
registers `social.lab -> 172.28.0.20` in the CA portal and you run the
three commands from the message in `docker compose exec social bash`
(they save into `./server`, exactly where Social Lab looks).

HTTPS is required, not optional: the site stays closed until
`server/cert.pem` and `server/key.pem` exist, and after a restart it opens
at https://social.lab only.

## Instances: alice and adwaith — user machines (Ubuntu + Firefox GUI)

Ubuntu-based Firefox containers (linuxserver/firefox). Open their screens
at http://localhost:5003 (Alice, a user) and http://localhost:5004
(Adwaith, the operator — manage the portals from here). Their resolver is
the lab DNS instance, so every domain registered in the DNS portal works
in their Firefox; everything else is forwarded to the real internet.

Each screen streams to **one viewer at a time** — if it hangs at
"Connection established. Waiting for server mode...", that screen is open
in another browser tab somewhere; close it and refresh.

The lab root CA is preinstalled in their Firefox the professional way, via
enterprise policy: each machine's policy file is mounted at
`/etc/firefox/policies/policies.json` and the root certificate at
`/usr/lib/mozilla/certificates/ca-lab-root.pem` (check about:policies in
Firefox).

| Policy file              | Used by | What it adds                                   |
|--------------------------|---------|------------------------------------------------|
| `policies/user.json`     | alice   | trust the lab root CA; `.lab` names open as sites |
| `policies/operator.json` | adwaith | the same, plus Firefox always starts with two tabs: https://ca.lab and https://dns.lab (also the Home button) |

Adwaith's startup tabs replace session restore, so every restart gives a
clean operator desktop with both portals open. Policy changes take effect
when Firefox starts: `docker compose up -d adwaith` (or `restart`).

`.lab` is not a real top-level domain, so Firefox would normally treat a
typed `ca.lab` as a web search. The same policy locks
`browser.fixup.domainsuffixwhitelist.lab` on, so typing just `ca.lab`
opens the site.

## Next: the attack lab (planned)

An attacker machine joins `labnet` and places itself between Alice and the
sites (DNS spoofing, an intercepting proxy):

- **Without a trusted CA** — a site on plain HTTP, or Alice clicking
  through a self-signed certificate: the attacker relays the connection
  and reads logins and photos in clear text.
- **With the lab CA** — Alice's Firefox trusts only certificates the lab
  CA issued for that exact name, so the attacker's forged certificate is
  rejected, the page refuses to load, and nothing leaks.

## Resetting

```bash
docker compose down
rm -rf ca/demoCA ca/server ca/clients ca/ca_portal.db dns/dns_portal.db dns/server social/social.db social/uploads social/server
```

After a reset: `setup_ca.sh` and `make_server_cert.sh` in ca, then
`./make_dns_cert.sh`, then register `ca.lab -> 172.28.0.10` at
https://dns.lab (reachable straight away, since `dns.lab` always resolves).

> Lab setup only: no key passphrases, and the CA portal hands out client
> private keys. Don't use this pattern in production.
> Note for builds: avoid `apt-get` in Dockerfiles here — this Mac routes
> container HTTP through a dead proxy (127.0.0.1:8081); HTTPS (pip) works.
