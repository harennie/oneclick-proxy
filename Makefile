.PHONY: all check

all: proxy.sh

proxy.sh: build.sh src/core.sh src/os.sh src/tune.sh src/xray.sh src/hy2.sh src/firewall.sh src/cert.sh src/cdn.sh src/link.sh src/singbox.sh src/nat.sh src/selftest.sh src/land.sh src/menu.sh src/route.sh src/cli.sh
	./build.sh

check:
	./build.sh --check
	shellcheck -s bash proxy.sh
	bash -n proxy.sh
