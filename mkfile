build > ins-bin: src/main.nim
	nim c -o:ins-bin -d:ssl -d:release --opt:speed src/main.nim
	"Build Completed!"

install: build ins-private
	"Installed ins successfully!"

clean:
	rm -rf ins-bin
	"Cleaned!"

ins-private:
	mkdir -p ~/.ins && printf '[\n  {\n    "name": "ins",\n    "url": "https://github.com/turbomaster95/ins",\n    "hash": "%s",\n    "installedAt": "%s",\n    "sourceDir": "%s",\n    "symlinks": ["%s/bin/ins"],\n    "configsDeployed": []\n  }\n]\n' "$(git rev-parse --short HEAD)" "$(date --iso-8601=seconds)" "$HOME/.ins/src/ins" "$PREFIX" > ~/.ins/state.json
	install -Dm755 ins-bin $PREFIX/share/ins/ins-bin && printf '#!/usr/bin/env bash\nREAL_BIN="$$PREFIX/share/ins/ins-bin"\n"$$REAL_BIN" "$$@"\nexit_code=$$?\nif [ $$exit_code -eq 0 ]; then\n    case "$$1" in rm|remove|uninstall) hash -r 2>/dev/null; [ -n "$$ZSH_VERSION" ] && rehash ;; esac\nfi\nexit $$exit_code\n' > ins && install -Dm755 ins $PREFIX/bin/ins && rm ins
	sed -i 's/\\\$ \?/\$/g' $PREFIX/bin/ins
	mkdir -p ~/.ins/src/ins
	--git clone https://github.com/turbomaster95/ins ~/.ins/src/ins/

do: build
