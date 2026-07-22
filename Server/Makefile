.PHONY: debug release test verify-upstream

SPEECH_SWIFT := ../Vendor/speech-swift
EXPECTED_SPEECH_SWIFT_REV := 79c3a25d8446f2b5afc8f8e14100363c6810e229

verify-upstream:
	@test "$$(git -C "$(SPEECH_SWIFT)" rev-parse HEAD)" = "$(EXPECTED_SPEECH_SWIFT_REV)" || \
		(echo "error: speech-swift must be at $(EXPECTED_SPEECH_SWIFT_REV)" >&2; exit 1)

debug: verify-upstream
	swift build --disable-sandbox
	LC_ALL=C LANG=C BUILD_DIR="$(CURDIR)/.build" "$(SPEECH_SWIFT)/scripts/build_mlx_metallib.sh" debug

release: verify-upstream
	swift build -c release --disable-sandbox
	LC_ALL=C LANG=C BUILD_DIR="$(CURDIR)/.build" "$(SPEECH_SWIFT)/scripts/build_mlx_metallib.sh" release

test: verify-upstream
	swift test --disable-sandbox
