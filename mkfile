build > ins: src/main.nim
	nim c -o:ins -d:ssl -d:release --opt:speed src/main.nim
	"Build Complete!"

install: build
	install -Dm755 ins $PREFIX/bin/ins
	"Installed ins successfully!"

clean:
	rm -rf ins
	"Cleaned!"

do: build
