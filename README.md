# ins

run this to get the first binary:
```bash
nim c -o:ins-bin -d:ssl -d:release --opt:speed src/main.nim
```

then run this to install mk and ins fully:
```bash
./ins-bin sane.tools/mk
./ins-bin ins
```
congrats! you have a working installation of the `mk` build system and the `ins` package manager!


