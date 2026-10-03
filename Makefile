# Build with make, never a bare `swift build`: it strips the entitlement signature the VM needs.

BIN := .build/debug/Host
ENTITLEMENTS := sidekernel.entitlements
SIGN_IDENTITY ?= Sidekernel Local Signing
SWIFT_TEST_FLAGS ?=
AGENT_MUSL := agent/target/aarch64-unknown-linux-musl/release/sk-agent
RESOURCES := Host/Resources
# Commands on the guest PATH, then internal helpers kept off it.
GUEST_SCRIPTS := save sk-drop sk-net ramblinwreck codex internal/seed internal/bashrc internal/clip internal/harness.py
.DEFAULT_GOAL := install
.PHONY: install build stage sign identity test clean

install: build
	@"$(CURDIR)/$(BIN)" install

stage:
	@cd agent && cargo build --release --target aarch64-unknown-linux-musl >/dev/null
	@mkdir -p $(RESOURCES)
	@cp $(AGENT_MUSL) $(RESOURCES)/sk-agent
	@for s in $(GUEST_SCRIPTS); do cp "guest/$$s" "$(RESOURCES)/$${s#internal/}"; done
	@echo "✓ staged sk-agent + guest scripts into $(RESOURCES)"

build: stage identity
	swift build
	@codesign --force --sign "$(SIGN_IDENTITY)" --entitlements $(ENTITLEMENTS) $(BIN) && echo "✓ signed $(BIN) ($(SIGN_IDENTITY))"

sign: identity
	@codesign --force --sign "$(SIGN_IDENTITY)" --entitlements $(ENTITLEMENTS) $(BIN) && echo "✓ signed $(BIN)"

# Creates the self-signed identity once, proven by signing a throwaway binary.
identity:
	@if [ "$(SIGN_IDENTITY)" = "-" ]; then exit 0; fi; \
	t="$$(mktemp -d)"; cp /usr/bin/true "$$t/probe"; \
	sign() { codesign -f -s "$(SIGN_IDENTITY)" "$$t/probe" >/dev/null 2>&1; }; \
	if sign; then rm -rf "$$t"; exit 0; fi; \
	echo "→ creating self-signed code-signing identity '$(SIGN_IDENTITY)'"; \
	kc="$$HOME/Library/Keychains/login.keychain-db"; \
	{ printf '[req]\ndistinguished_name=dn\nx509_extensions=v3\nprompt=no\n[dn]\nCN=%s\n[v3]\nbasicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=critical,codeSigning\n' "$(SIGN_IDENTITY)" > "$$t/req.cnf" \
	  && openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -keyout "$$t/key.pem" -out "$$t/cert.pem" -config "$$t/req.cnf" \
	  && security import "$$t/cert.pem" -k "$$kc" -T /usr/bin/codesign \
	  && security import "$$t/key.pem"  -k "$$kc" -T /usr/bin/codesign ; \
	} > "$$t/log" 2>&1; \
	if sign; then echo "✓ created and verified '$(SIGN_IDENTITY)'"; rm -rf "$$t"; exit 0; fi; \
	echo "✗ automatic creation failed. Raw output:"; sed 's/^/    /' "$$t/log"; \
	echo "  Reliable fallback (one time, ~60s): Keychain Access ▸ Certificate Assistant ▸"; \
	echo "  Create a Certificate: Name='$(SIGN_IDENTITY)', Self Signed Root, Code Signing."; \
	echo "  Or build ad-hoc for now:  make build SIGN_IDENTITY=-"; \
	rm -rf "$$t"; exit 1

test: stage
	python3 -B -m unittest discover -s Tests/GuestTests
	cd agent && cargo test
	swift test --disable-xctest $(SWIFT_TEST_FLAGS)

clean:
	rm -rf .build agent/target $(RESOURCES)
