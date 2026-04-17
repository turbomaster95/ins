import std/[json, strutils, sequtils, osproc, os]
import loggins
import state

proc checkCmd*(cmd: string): bool =
  if cmd == "": return true
  let subCmds = cmd.split(" && ")
  for sub in subCmds:
    let bin = sub.strip().split(' ')[0]
    if bin.startsWith("./"): continue
    if bin.startsWith("sh"): continue
    if bin.startsWith("bash"): continue
    if findExe(bin) == "":
      logErr "Required tool '", bin, "' is missing from your system."
      return false
  return true

proc getGitHash*(dir: string): string = 
  # Short HEAD commit hash for the repo at dir.
  let (outp, code) = execCmdEx("git -C " & quoteShell(dir) & " rev-parse --short HEAD")
  if code == 0: return outp.strip()
  return "unknown"

proc gitPull*(dir: string): int =
  execCmd("git -C " & quoteShell(dir) & " pull --ff-only -q")

proc findGitRoot*(startDir: string, stopAt: string): string =
  var cur = startDir
  while cur.len >= stopAt.len:
    if dirExists(cur / ".git"):
      return cur
    let parent = cur.parentDir()
    if parent == cur: break   # filesystem root
    cur = parent
  return ""

proc findBuiltBinaries*(buildDir: string, pkgBaseName: string): seq[string] =
  result = @[]
  let searchDirs = @[
    buildDir,
    buildDir / "bin",
    buildDir / "target" / "release",
    buildDir / "build",
    buildDir / "dist",
    buildDir / ".build" / "release",
    buildDir / "out",
    buildDir / "output",
  ]

  # 1. Broad extension blacklist
  let skipExts = [".c", ".h", ".cpp", ".hpp", ".rs", ".go", ".nim",
                  ".py", ".js", ".ts", ".md", ".txt", ".json", ".toml",
                  ".yaml", ".yml", ".lock", ".sum", ".mod", ".sh",
                  ".bat", ".ps1", ".rb", ".lua", ".cmake", ".mk",
                  ".o", ".a", ".so", ".dylib", ".d", ".S", ".status", ".la", ".lo"]

  # 2. Specific filename blacklist (Common build-system artifacts)
  let skipNames = [
  # --- Autotools & Shell Bootstraps ---
  "configure", "config.status", "config.guess", "config.sub", "config.log",
  "libtool", "install-sh", "missing", "depcomp", "compile", "ylwrap",
  "ltmain.sh", "mdate-sh", "test-driver", "am__last_run", "stamp-h1",
  "bootstrap.sh", "setup.sh", "autogen.sh",

  # --- CMake, Meson & Ninja ---
  "CMakeCache.txt", "cmake_install.cmake", "CTestTestfile.cmake",
  "CPackConfig.cmake", "CPackSourceConfig.cmake",
  "build.ninja", "rules.ninja", "compile_commands.json",
  "meson-log.txt", "meson-info", "meson-private",

  # --- Bazel, Buck, Pants & Please ---
  "WORKSPACE", "MODULE.bazel", "BUILD.bazel", "BUILD", "BUCK",
  "pants.toml", ".plzconfig", "pleasew",
  "bazel-bin", "bazel-out", "bazel-testlogs", "bazel-external",

  # --- Rust, Go, Nim & V ---
  "Cargo.toml", "Cargo.lock", "go.mod", "go.sum", "v.mod",
  "nimcache", "nimble.lock",

  # --- Python (Poetry, Flit, Waf) ---
  "pyproject.toml", "poetry.lock", "flit.ini", "wscript", ".lock-wscript",
  "waf", "setup.py", "requirements.txt",

  # --- Node.js & Web ---
  "package.json", "package-lock.json", "yarn.lock", "bun.lockb",
  "node_modules", "bower.json",

  # --- JVM (Gradle, Maven, Ant) ---
  "build.gradle", "build.gradle.kts", "gradlew", "gradlew.bat",
  "pom.xml", "build.xml", "settings.gradle",

  # --- Haskell (Stack, Cabal) ---
  "stack.yaml", "stack.yaml.lock", "cabal.project", "cabal.project.local",

  # --- Alternative Systems (Tup, Just, SCons, BitBake) ---
  ".tup", "Tupfile", "tup.config", "justfile", "SConstruct",
  "SConscript", ".sconsign.dblite", "bitbake.conf",

  # --- Generic Build Noise & Make ---
  "Makefile", "makefile", "GNUmakefile", "mkfile", "config.mk",
  "conftest", "a.out", "core", "TAGS", "ID", "GTAGS", "GRTAGS"
  ]

  for dir in searchDirs:
    if not dirExists(dir): continue
    for kind, path in walkDir(dir):
      if kind != pcFile: continue
      let (_, fname, ext) = splitFile(path)

      # Filtering Logic
      if ext in skipExts: continue
      if fname in skipNames: continue
      if fname.startsWith("CMake") or fname.startsWith("_"): continue

      # Most shell scripts like 'configure' are < 500KB.
      # Real compiled binaries are usually larger, but pfetch/sl might be small.
      if getFileSize(path) < 1000: continue

      when defined(windows):
        if ext == ".exe": result.add(path)
      else:
        try:
          let perms = getFilePermissions(path)
          if fpUserExec in perms:
            # Check if it a script?
            # Read the first two bytes for a shebang #!
            let f = open(path)
            var head: array[2, char]
            # some warning here, dont understand lol
            let bytesRead = f.readChars(head, 0, 2)
            f.close()

            if bytesRead == 2 and head[0] == '#' and head[1] == '!':
              # It's a script (sh, python, etc).
              # Only add if the filename matches the package name exactly
              if fname != pkgBaseName: continue

            result.add(path)
        except: discard

  result = result.deduplicate()


proc linkBinaries*(binaries: seq[string], pkgName: string): seq[string] =
  # Symlinks discovered binaries into the user bin dir.
  result = @[]
  if binaries.len == 0:
    logWarn "No executable binaries found to link for " & pkgName
    return

  let binDir = getBinDir()
  for binPath in binaries:
    let (_, fname, ext) = splitFile(binPath)
    if fname.len == 0: continue
    let linkName = if ext == ".exe": fname else: fname
    let linkPath = binDir / linkName
    try:
      if symlinkExists(linkPath) or fileExists(linkPath):
        removeFile(linkPath)
      createSymlink(binPath, linkPath)
      loglns "Linked: ", binPath, " → ", linkPath
      result.add(linkPath)
    except CatchableError as e:
      logWarn "Could not link " & fname & ": " & e.msg

proc deployDefaultConfigs*(sourceDir: string, pkgName: string): seq[string] =
  # Copies a repo's config/ (or configs/ etc.) to ~/.config/<pkgName>/
  result = @[]
  let configDest = getHomeDir() / ".config" / pkgName.lastPathPart()
  let candidates = @[
    sourceDir / "config",
    sourceDir / "configs",
    sourceDir / ".config",
    sourceDir / "examples" / "config",
    sourceDir / "doc" / "config",
  ]

  var srcConfigDir = ""
  for c in candidates:
    if dirExists(c):
      srcConfigDir = c
      break
  if srcConfigDir == "": return   # nothing to deploy

  loglns "Deploying default configs → ", configDest
  createDir(configDest)

  for path in walkDirRec(srcConfigDir):
    if not fileExists(path): continue

    let rel = path.relativePath(srcConfigDir)
    let dest = configDest / rel

    createDir(dest.parentDir())
    if not fileExists(dest):
      copyFile(path, dest)
      loglns "  Config: ", dest
      result.add(dest)
    else:
      logWarn "  Config exists, skipping: ", dest


proc runPostInstallHook*(sourceDir: string) =
  let hooks = @[
    sourceDir / "post-install.sh",
    sourceDir / "post_install.sh",
    sourceDir / "postinstall.sh",
    sourceDir / "install.sh",
    sourceDir / ".hooks" / "post-install.sh",
    sourceDir / "hooks" / "post-install.sh",
    sourceDir / "post-install.py",
    sourceDir / "post-install.pl",
    sourceDir / "post-install.rb"
  ]

  for hook in hooks:
    if fileExists(hook):
      let ext = splitFile(hook).ext
      var cmd = ""

      # Mapping extensions to their required binaries
      case ext
      of ".sh": cmd = "sh " & quoteShell(hook)
      of ".py": cmd = "python3 " & quoteShell(hook)
      of ".pl": cmd = "perl " & quoteShell(hook)
      of ".rb": cmd = "ruby " & quoteShell(hook)
      else: cmd = "sh " & quoteShell(hook)

      if checkCmd(cmd):
        loglns "Running hook: ", hook
        discard execCmd(cmd)
      else:
        logWarn "Skipping hook due to missing dependencies."

      return

