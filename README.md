# ins

run this to get the first binary:
```bash
nim c -o:ins-bin -d:ssl -d:release --opt:speed src/main.nim
```

then run this to install mk and ins fully:
```bash
./ins-bin ins
```

the `ins` install process works as follows:
### 1. Dependency Resolution:
The tool looks up the package to see if it needs other software to run and installs those requirements first.
### 2. Target Parsing:
It figures out which URL to clone and checks if the code lives in a specific subfolder of a larger project.
### 3. Source Downloading:
It downloads the code using git, but skips this step if you already have the folder on your machine.
### 4. Build System Detection:
It looks at the files in the folder to guess how to compile the code, whether it uses Make, CMake, or a language manager like Cargo.
### 5. Compilation:
It runs the build commands one by one and tries a fresh start if something goes wrong during the process.
### 6. Final steps & Tracking it:
It links the new program to your command line and saves the details so you can update or remove it later.

congrats! you have a working installation of the `mk` build system and the `ins` package manager!


