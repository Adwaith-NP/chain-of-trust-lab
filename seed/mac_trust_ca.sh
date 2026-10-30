#!/bin/bash
# SEED Task 3, Step 3 - make the Mac's browsers trust the lab's root CA.
# Chrome and Safari on macOS use the system keychain. Asks for your Mac password.
source "$(dirname "$0")/lib.sh"
set -e

step "Trust the lab's root CA on this Mac"
note "Take the 'issuer unknown' screenshot in Chrome first - after this it is gone."
mac "openssl x509 -in ca/demoCA/cacert.pem -noout -subject -fingerprint -sha256"
mac "sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain ca/demoCA/cacert.pem"
note "Reload https://seedpkilab2020.com:4433 in Chrome: no warning now."
note "By hand instead (for screenshots): Keychain Access > File > Import Items >"
note "ca/demoCA/cacert.pem, then double-click 'CA Lab Root CA' > Trust > Always Trust."
note "Undo: sudo security remove-trusted-cert -d ca/demoCA/cacert.pem"
