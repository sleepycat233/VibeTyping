.PHONY: app app-test server-test test

app:
	cd App && ./Scripts/build_app.sh

app-test:
	cd App && swift test --disable-sandbox

server-test:
	cd Server && swift test --disable-sandbox

test: app-test server-test
