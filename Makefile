VERSION ?= 0.0.0-dev

.PHONY: build test app release-unsigned release-signed notarize clean

build:
	swift build -c release

test:
	swift test

## app: assemble dist/Seiren.app (+ zip + sha256). Ad-hoc signed unless SIGN_ID set.
app:
	VERSION=$(VERSION) scripts/package.sh

## release-unsigned: ad-hoc .app for GitHub Releases (Gatekeeper bypass needed).
release-unsigned: app

## release-signed: Developer ID build. Requires SIGN_ID="Developer ID Application: ...".
release-signed:
	VERSION=$(VERSION) SIGN_ID="$(SIGN_ID)" scripts/package.sh

## notarize: notarize + staple the signed app (requires a paid Developer ID).
notarize: release-signed
	VERSION=$(VERSION) scripts/notarize.sh

clean:
	rm -rf .build dist
