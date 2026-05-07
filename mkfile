build: src/loggins.nim src/main.nim src/parse.nim src/state.nim src/registry.nim src/helpers.nim
    nim c -o:ins-bin -d:ssl -d:release --opt:speed src/main.nim
    "Build Completed!" (Build=green)

install:
    ./post-install.sh
    "Installed ins successfully!" (ins=cyan)

clean:
    --rm -rf ins-bin
    "Cleaned!" (Cleaned=yellow)

do: build
