import parse
import loggins
import state
import std/[httpclient, json, strutils, os, osproc, times, sequtils]

const RegistryUrl = "https://raw.githubusercontent.com/turbomaster95/registry/main/packages.json"

# =============================================================================
# REGISTRY  (supports "dependencies": [] field)
# =============================================================================

proc findPackage*(pkgName: string): string =
  ## Returns the URL from the registry OR the input if it looks like a repo URL.
  let isDirectUrl = pkgName.contains("://") or
                    pkgName.startsWith("git@") or
                    pkgName.endsWith(".git")
  if isDirectUrl:
    return pkgName.strip(chars = {'/'}, leading = false, trailing = true)

  let client = newHttpClient()
  try:
    loglns "Updating registry..."
    let content = client.getContent(RegistryUrl)
    let jsonNode = parseJson(content)
    for item in jsonNode:
      if item["name"].getStr() == pkgName:
        return item["url"].getStr()
    return ""
  except:
    logErr "Could not reach the registry."
    return ""
  finally:
    client.close()

proc fetchRegistryEntry(pkgName: string): JsonNode =
  ## Returns the full registry JSON object for pkgName, or nil.
  let client = newHttpClient()
  try:
    let content = client.getContent(RegistryUrl)
    let root = parseJson(content)
    for item in root:
      if item{"name"}.getStr() == pkgName:
        return item
    return nil
  except:
    return nil
  finally:
    client.close()

# =============================================================================
# BINARY EXISTENCE CHECK  (unchanged from original)
# =============================================================================

proc checkCmd(cmd: string): bool =
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

# =============================================================================
# GIT HELPERS
# =============================================================================

proc getGitHash(dir: string): string =
  ## Short HEAD commit hash for the repo at dir.
  let (outp, code) = execCmdEx("git -C " & quoteShell(dir) & " rev-parse --short HEAD")
  if code == 0: return outp.strip()
  return "unknown"

proc gitPull(dir: string): int =
  execCmd("git -C " & quoteShell(dir) & " pull --ff-only -q")

proc findGitRoot(startDir: string, stopAt: string): string =
  ## Walks up from startDir until it finds a directory containing .git,
  ## stopping if we'd go above stopAt.  Returns "" if not found.
  var cur = startDir
  while cur.len >= stopAt.len:
    if dirExists(cur / ".git"):
      return cur
    let parent = cur.parentDir()
    if parent == cur: break   # filesystem root
    cur = parent
  return ""

# =============================================================================
# BINARY DISCOVERY & GLOBAL LINKING
# =============================================================================

proc findBuiltBinaries(buildDir: string, pkgBaseName: string): seq[string] =
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
      
      # 3. Size Heuristic (Optional but powerful)
      # Most shell scripts like 'configure' are < 500KB. 
      # Real compiled binaries are usually larger, but pfetch/sl might be small.
      # Use with caution: maybe set a floor of 1KB to skip empty files.
      if getFileSize(path) < 1000: continue 

      when defined(windows):
        if ext == ".exe": result.add(path)
      else:
        try:
          let perms = getFilePermissions(path)
          if fpUserExec in perms:
            # 4. Final Sanity Check: Is it a script?
            # Read the first two bytes for a shebang #!
            let f = open(path)
            var head: array[2, char]
            let bytesRead = f.readChars(head, 0, 2)
            f.close()
            
            if bytesRead == 2 and head[0] == '#' and head[1] == '!':
              # It's a script (sh, python, etc). 
              # Only add if the filename matches the package name exactly
              if fname != pkgBaseName: continue
            
            result.add(path)
        except: discard

  result = result.deduplicate()


proc linkBinaries(binaries: seq[string], pkgName: string): seq[string] =
  ## Symlinks discovered binaries into the user bin dir.
  ## Returns list of created symlink absolute paths.
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

# =============================================================================
# CONFIG DEPLOYMENT
# =============================================================================

proc deployDefaultConfigs(sourceDir: string, pkgName: string): seq[string] =
  ## Copies a repo's config/ (or configs/ etc.) to ~/.config/<pkgName>/
  ## Skips files that already exist (preserves user changes).
  ## Returns list of newly deployed config file paths.
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
    # walkDirRec yields everything; we only want files
    if not fileExists(path): continue 
    
    # Calculate the relative path
    # Using relativePath from std/os is cleaner than manual slicing
    let rel = path.relativePath(srcConfigDir)
    let dest = configDest / rel
    
    createDir(dest.parentDir())
    if not fileExists(dest):
      copyFile(path, dest)
      loglns "  Config: ", dest
      result.add(dest)
    else:
      logWarn "  Config exists, skipping: ", dest


# =============================================================================
# POST-INSTALL HOOK
# =============================================================================

proc runPostInstallHook(sourceDir: string) =
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

      # --- Logic Integration ---
      # Check if the required interpreter (sh, python3, etc.) exists
      if checkCmd(cmd):
        loglns "Running hook: ", hook
        discard execCmd(cmd)
      else:
        logWarn "Skipping hook due to missing dependencies."
      
      return 

# =============================================================================
# BUILD CANDIDATE TYPE
# =============================================================================

type
  BuildCandidate = object
    label:     string
    genCmd:    string
    buildCmd:  string
    instCmd:   string
    needsClean: bool

# =============================================================================
# DEPENDENCY RESOLVER
# =============================================================================

# Forward declaration so dep resolver can call doInstall recursively.
proc doInstall*(res: ParseResult)

proc resolveDependencies(pkgName: string) =
  ## Reads "dependencies": [] from the registry entry and installs each one
  ## (recursively) before building the target package.
  let entry = fetchRegistryEntry(pkgName)
  if entry == nil: return
  if not entry.hasKey("dependencies"): return
  let deps = entry["dependencies"]
  if deps.kind != JArray or deps.len == 0: return

  loglns "Resolving " & $deps.len & " dependenc(y/ies) for " & pkgName & "..."
  for dep in deps:
    let depName = dep.getStr()
    if depName == "": continue
    let (already, _) = stateLookup(depName)
    if already:
      loglns "Dependency '" & depName & "' already installed. Skipping."
      continue
    loglns "Installing dependency: " & depName
    var depRes = ParseResult()
    depRes.action = actionInstall
    depRes.target = depName
    doInstall(depRes)

# =============================================================================
# CORE INSTALLER
# =============================================================================

proc doInstall*(res: ParseResult) =
  let pkg = res.target
  if pkg == "": return

  var repoName = ""
  var subPath  = ""

  # 1. Protocol-Aware Splitting
  if pkg.contains("://"):
    let urlParts     = pkg.split("://")
    let protocol     = urlParts[0]
    let rest         = urlParts[1]
    let pathSegments = rest.split('/')
    if pathSegments.len > 3:
      repoName = protocol & "://" & pathSegments[0..2].join("/")
      subPath  = pathSegments[3..^1].join("/")
    else:
      repoName = pkg
  else:
    let parts = pkg.split('/')
    repoName = parts[0]
    subPath  = if parts.len > 1: parts[1..^1].join("/") else: ""

  # 2. Dependency resolution (before building this package)
  resolveDependencies(repoName)

  # 3. URL Retrieval
  let url = findPackage(repoName)
  if url == "":
    logErr "Package '" & repoName & "' not found in registry and is not a valid URL."
    quit(1)

  # 4. Determine clone folder (inside ~/.ins/src/)
  let srcRoot = getSourceRoot()
  var folder  = repoName.lastPathPart()
  if folder.endsWith(".git"):
    folder = folder[0..^5]

  loglns "Found " & folder & " at " & url

  # 5. Clone Logic
  let cloneDir = srcRoot / folder
  let prevDir  = getCurrentDir()
  setCurrentDir(srcRoot)

  if not dirExists(cloneDir):
    loglns "Cloning " & repoName & "..."
    var exCode = execCmd("git clone -q --depth 1 " & url)
    if exCode != 0:
      logWarn "Shallow clone failed, trying full clone..."
      exCode = execCmd("git clone -q " & url)
    if exCode != 0:
      logErr "Package " & repoName & " cannot be cloned!"
      setCurrentDir(prevDir)
      quit(1)
  else:
    loglns "Folder '" & folder & "' already exists. Skipping clone."

  # 6. Enter directory (handling sub-paths)
  let targetDir = if subPath != "": cloneDir / subPath else: cloneDir
  if dirExists(targetDir):
    loglns "Entering directory: ", targetDir
    setCurrentDir(targetDir)
  else:
    logErr "Sub-directory '" & subPath & "' not found in " & folder
    setCurrentDir(prevDir)
    quit(1)

  # 7. Submodules
  if fileExists(".gitmodules"):
    loglns "Submodules found! Initializing..."
    if execCmd("git submodule update --init --recursive") != 0:
      logErr "Submodule initialization failed."
      setCurrentDir(prevDir)
      quit(1)

  # 8. Capture git hash for ledger
  let gitHash = getGitHash(cloneDir)

  # 9. Build flags
  loglns "--- Installing: ", targetDir.lastPathPart(), " ---"
  if res.metaArgs != "":
    loglns "Applying flags to metabuild: ", res.metaArgs
  if res.makeArgs != "":
    loglns "Applying flags to build: ", res.makeArgs

  let meta  = res.metaArgs
  let build = res.makeArgs

  # --- Build System Detection: collect ALL candidates in priority order ---
  var candidates: seq[BuildCandidate] = @[]

  # GENERATOR-BASED systems (highest priority)
  if fileExists("CMakeLists.txt"):
    candidates.add(BuildCandidate(
      label: "CMake", genCmd: "cmake . " & meta,
      buildCmd: "make " & build, needsClean: true))

  if fileExists("meson.build"):
    candidates.add(BuildCandidate(
      label: "Meson/Ninja", genCmd: "meson setup build " & meta,
      buildCmd: "ninja -C build " & build))

  if fileExists("premake5.lua") or fileExists("premake4.lua"):
    let pVer = if fileExists("premake5.lua"): "premake5" else: "premake4"
    candidates.add(BuildCandidate(
      label: "Premake", genCmd: pVer & " gmake2 " & meta,
      buildCmd: "make " & build, needsClean: true))

  if fileExists("configure"):
    candidates.add(BuildCandidate(
      label: "configure script", genCmd: "./configure " & meta,
      buildCmd: "make " & build, needsClean: true))

  if fileExists("configure.ac") or fileExists("configure.in") or fileExists("autogen.sh"):
    if fileExists("autogen.sh"): discard execCmd("./autogen.sh")
    candidates.add(BuildCandidate(
      label: "Autotools", genCmd: "autoreconf -if && ./configure " & meta,
      buildCmd: "make " & build, needsClean: true))

  # STANDALONE systems
  if fileExists("Cargo.toml"):
    candidates.add(BuildCandidate(
      label: "Cargo (Rust)",
      buildCmd: "cargo build --release " & meta & " " & build,
      instCmd: "cargo fetch"))

  if fileExists("nim.ble") or fileExists(folder & ".nimble"):
    candidates.add(BuildCandidate(
      label: "Nimble",
      buildCmd: "nimble build -d:release " & meta & " " & build,
      instCmd: "nimble install -y --depsOnly"))

  if fileExists("v.mod"):
    candidates.add(BuildCandidate(
      label: "V", buildCmd: "v " & meta & " " & build & " ."))

  if fileExists("build.zig"):
    candidates.add(BuildCandidate(
      label: "Zig",
      buildCmd: "zig build -Doptimize=ReleaseSafe " & meta & " " & build))

  if fileExists("go.mod"):
    candidates.add(BuildCandidate(
      label: "Go",
      buildCmd: "go build " & meta & " " & build,
      instCmd: "go mod download"))

  if fileExists("package.json"):
    let manager = if fileExists("bun.lockb"): "bun"
                  elif fileExists("yarn.lock"): "yarn"
                  else: "npm"
    candidates.add(BuildCandidate(
      label: "Node (" & manager & ")",
      buildCmd: manager & " run build " & meta & " " & build,
      instCmd: manager & " install"))

  if fileExists("pyproject.toml") or fileExists("poetry.lock"):
    candidates.add(BuildCandidate(
      label: "Poetry (Python)",
      buildCmd: "poetry build " & meta & " " & build,
      instCmd: "poetry install"))

  if fileExists("flit.ini"):
    candidates.add(BuildCandidate(
      label: "Flit (Python)",
      buildCmd: "flit build " & meta & " " & build))

  if fileExists("stack.yaml") or fileExists("cabal.project"):
    let hTask = if fileExists("stack.yaml"): "stack" else: "cabal"
    candidates.add(BuildCandidate(
      label: "Haskell (" & hTask & ")",
      buildCmd: hTask & " build " & meta & " " & build))

  if fileExists("build.gradle") or fileExists("build.gradle.kts"):
    let gradlew = if fileExists("gradlew"): "./gradlew" else: "gradle"
    candidates.add(BuildCandidate(
      label: "Gradle",
      buildCmd: gradlew & " build " & meta & " " & build))

  if fileExists("pom.xml"):
    candidates.add(BuildCandidate(
      label: "Maven", buildCmd: "mvn package " & meta & " " & build))

  if fileExists("build.xml"):
    candidates.add(BuildCandidate(
      label: "Ant", buildCmd: "ant " & meta & " " & build))

  if fileExists("WORKSPACE") or fileExists("BUILD.bazel"):
    candidates.add(BuildCandidate(
      label: "Bazel", buildCmd: "bazel build //... " & meta & " " & build))

  if fileExists("BUCK"):
    let bBinary = if findExe("buck2") != "": "buck2" else: "buck"
    candidates.add(BuildCandidate(
      label: "Buck", buildCmd: bBinary & " build //... " & meta & " " & build))

  if fileExists("pants.toml"):
    candidates.add(BuildCandidate(
      label: "Pants", buildCmd: "pants package ::"))

  if fileExists("pleasew") or fileExists(".plzconfig"):
    let plzCmd = if fileExists("pleasew"): "./pleasew" else: "plz"
    candidates.add(BuildCandidate(
      label: "Please", buildCmd: plzCmd & " build " & meta & " " & build))

  if fileExists("SConstruct"):
    candidates.add(BuildCandidate(
      label: "SCons", buildCmd: "scons " & meta & " " & build))

  if fileExists("wscript"):
    candidates.add(BuildCandidate(
      label: "Waf", buildCmd: "python waf configure build " & meta & " " & build))

  if fileExists("bitbake.conf") or dirExists("recipes-"):
    candidates.add(BuildCandidate(
      label: "BitBake", buildCmd: "bitbake " & meta & " " & build))

  if fileExists("build.ninja"):
    candidates.add(BuildCandidate(
      label: "Ninja", buildCmd: "ninja " & meta & " " & build))

  if fileExists("Tupfile"):
    candidates.add(BuildCandidate(
      label: "Tup", buildCmd: "tup " & meta & " " & build))

  if fileExists("justfile"):
    candidates.add(BuildCandidate(
      label: "Just", buildCmd: "just " & meta & " " & build))

  if fileExists("Makefile") or fileExists("makefile") or fileExists("GNUmakefile"):
    candidates.add(BuildCandidate(
      label: "Make", buildCmd: "make " & meta & " " & build, needsClean: true))

  if fileExists("mkfile"):
    candidates.add(BuildCandidate(
      label: "mk", buildCmd: "mk " & meta & " " & build))

  if fileExists("bootstrap.sh"):
    candidates.add(BuildCandidate(
      label: "bootstrap.sh", buildCmd: "sh bootstrap.sh " & meta & " " & build))

  if fileExists("setup.sh"):
    var command: string

    if pkg == "sane.tools/mk":
      command = "sh setup.sh --from-ins " & meta & " " & build
    else:
      command = "sh setup.sh " & meta & " " & build

    candidates.add(BuildCandidate(label: "setup.sh", buildCmd: command))

  # --- Execution Engine: try each candidate, fall through on failure ---

  if candidates.len == 0:
    loglns "No recognized build system found in " & folder
    setCurrentDir(prevDir)
    return

  var succeeded = false

  for i, cand in candidates:
    if i > 0:
      logWarn "Trying next build system: " & cand.label & "..."
    else:
      loglns "Detected build system: " & cand.label

    # Generator step
    if cand.genCmd != "":
      if not checkCmd(cand.genCmd):
        logWarn cand.label & " generator tools missing, skipping..."
        continue
      echo "Running generator: ", cand.genCmd
      if execCmd(cand.genCmd) != 0:
        logWarn cand.label & " generation step failed, trying next..."
        continue

    if cand.buildCmd == "":
      logWarn cand.label & " has no build command, skipping..."
      continue

    if not checkCmd(cand.buildCmd):
      logWarn cand.label & " build tools missing, skipping..."
      continue

    loglns "Executing: ", cand.buildCmd

    if cand.instCmd != "":
      loglns "Installing dependencies for: ", pkg
      if execCmd(cand.instCmd) != 0:
        logErr "Couldn't install dependencies for project!"
        setCurrentDir(prevDir)
        quit(1)

    if execCmd(cand.buildCmd) != 0:
      if cand.needsClean:
        logWarn cand.label & " build failed. Will hard-reset if no other system works."
      else:
        logWarn cand.label & " build failed, trying next build system..."
      continue

    succeeded = true
    break

  if not succeeded:
    var anyNeedsClean = false
    for cand in candidates:
      if cand.needsClean:
        anyNeedsClean = true
        break
    if anyNeedsClean:
      logErr "All build systems failed. Retrying with Hard Reset..."
      setCurrentDir(prevDir)
      removeDir(cloneDir)
      doInstall(res)
      return
    else:
      logErr "All build systems failed for " & folder
      setCurrentDir(prevDir)
      quit(1)

  # --- Post-Build: Binary Linking ---
  let binaries = findBuiltBinaries(targetDir, folder)
  let links    = linkBinaries(binaries, folder)

  # --- Post-Build: Config Deployment ---
  let configs  = deployDefaultConfigs(targetDir, folder)

  # --- Post-Build: Environment Hook ---
  runPostInstallHook(targetDir)

  # --- State Ledger ---
  let record = InstalledPkg(
    name:            repoName,
    url:             url,
    hash:            gitHash,
    installedAt:     $now(),
    sourceDir:       targetDir,
    symlinks:        links,
    configsDeployed: configs,
  )
  stateAddOrUpdate(record)

  setCurrentDir(prevDir)
  logDone "Done installing " & folder & "!"

# =============================================================================
# UPDATE COMMAND
# =============================================================================

proc doUpdate*(pkgName: string) =
  let (found, record) = stateLookup(pkgName)
  if not found:
    logErr "Package '" & pkgName & "' is not installed."
    quit(1)

  loglns "Checking for updates: " & pkgName

  let srcRoot = getSourceRoot()
  let gitRoot = findGitRoot(record.sourceDir, srcRoot)
  if gitRoot == "":
    logErr "Cannot find git repository for " & pkgName & " under " & srcRoot
    quit(1)

  let oldHash = record.hash
  loglns "Pulling latest changes..."
  if gitPull(gitRoot) != 0:
    logErr "git pull failed for " & pkgName
    quit(1)

  let newHash = getGitHash(gitRoot)
  if newHash == oldHash:
    loglns pkgName & " is already up to date (" & oldHash & ")."
    return

  loglns "Hash changed: " & oldHash & " → " & newHash & ". Rebuilding..."

  # Remove stale symlinks before rebuild
  for link in record.symlinks:
    if symlinkExists(link) or fileExists(link):
      try: removeFile(link)
      except: discard

  var updRes = ParseResult()
  updRes.action = actionInstall
  updRes.target = pkgName
  doInstall(updRes)

# =============================================================================
# UNINSTALL COMMAND
# =============================================================================

proc doUninstall*(pkgName: string) =
  let (found, record) = stateLookup(pkgName)
  if not found:
    logErr "Package '" & pkgName & "' is not tracked in the ledger."
    quit(1)

  loglns "Uninstalling: " & pkgName

  # Remove symlinks
  for link in record.symlinks:
    if symlinkExists(link) or fileExists(link):
      try:
        removeFile(link)
        loglns "Removed symlink: ", link
      except CatchableError as e:
        logWarn "Could not remove symlink " & link & ": " & e.msg

  # Remove source directory (find git root so we delete the whole clone)
  let srcRoot = getSourceRoot()
  let gitRoot = findGitRoot(record.sourceDir, srcRoot)
  if gitRoot != "" and gitRoot.startsWith(srcRoot):
    try:
      removeDir(gitRoot)
      loglns "Removed source: ", gitRoot
    except CatchableError as e:
      logWarn "Could not remove source directory: " & e.msg
  else:
    logWarn "Source directory not found or outside ins root; skipping removal."

  # Configs are intentionally left to preserve user changes
  if record.configsDeployed.len > 0:
    loglns "Config files left in place to preserve your edits:"
    for c in record.configsDeployed:
      loglns "  ", c

  stateRemove(pkgName)
  logDone "Uninstalled " & pkgName & "."

# =============================================================================
# LIST COMMAND
# =============================================================================

proc doList*() =
  let state = loadState()
  if state.len == 0:
    loglns "No packages installed."
    return

  echo ""
  echo "Installed packages  (" & $state.len & " total)"
  echo "═══════════════════════════════════════════════════"
  for item in state:
    let name   = item{"name"}.getStr("?")
    let hash   = item{"hash"}.getStr("?")
    let date   = item{"installedAt"}.getStr("?")
    let nLinks = if item{"symlinks"} != nil: item{"symlinks"}.len else: 0
    echo "  • " & name
    echo "    hash:      " & hash
    echo "    installed: " & date
    echo "    binaries:  " & $nLinks & " linked"
    echo ""
  echo "═══════════════════════════════════════════════════"

proc listRegistry*() =
  ## Pulls the full registry and highlights packages already installed locally.
  let client = newHttpClient()
  defer: client.close()

  # 1. Load local state to check for installed packages
  let state = loadState() 
  
  try:
    loglns "Updating registry..."
    let content = client.getContent(RegistryUrl)
    let jsonNode = parseJson(content)

    if jsonNode.len == 0:
      loglns "Registry is empty."
      return

    echo ""
    echo "Available packages  (" & $jsonNode.len & " total)"
    echo "═══════════════════════════════════════════════════"

    for item in jsonNode:
      let name = item{"name"}.getStr("?")
      
      # 2. Check if this package exists in our local state
      var isInstalled = false
      for localPkg in state:
        if localPkg{"name"}.getStr() == name:
          isInstalled = true
          break

      # 3. Format the name line with a green [installed] tag if found
      let statusTag = if isInstalled: " \e[32m[installed]\e[0m" else: ""
      
      let version = item{"version"}.getStr("?")
      let desc    = item{"description"}.getStr("No description.")
      let url     = item{"url"}.getStr("?")
      let license = item{"license"}.getStr("?")

      echo "  • " & name & statusTag
      echo "    version:     " & version
      echo "    description: " & desc
      echo "    url:         " & url
      echo "    license:     " & license
      echo "" 

    echo "═══════════════════════════════════════════════════"

  except Exception as e:
    logErr "Could not reach the registry: " & e.msg

# =============================================================================
# HELP & MAIN
# =============================================================================

let version = "0.2.0"

proc showHelp() =
  let templateHelp = """
ins - build-system agnostic package manager v$1

Usage:
  ins <package>              Install a package
  ins i <package>            Install a package (explicit)
  ins update <package>       Pull latest and rebuild if hash changed
  ins rm <package>           Uninstall and remove binaries
  ins list [--all or -a]     Show installed packages
  ins help                   Show this help

Package formats:
  ins mypackage              Registry name lookup
  ins https://github.com/u/r Direct URL
  ins github.com/u/r/subdir  Monorepo sub-path
  ins git@github.com:u/r.git SSH clone URL

Example Usage:
   ~ $$ ins jq (compiles and installs jq)
"""
  echo templateHelp % [version]

proc main() =
  let res = parseArgs()

  case res.action
  of actionInstall:
    let (alreadyInstalled, _) = stateLookup(res.target)
    if alreadyInstalled:
      loglns "Package '" & res.target & "' is already installed. Switching to update..."
      doUpdate(res.target)
    else:
      doInstall(res)
  of actionRemove:
    doUninstall(res.target)
  of actionUpdate:
    doUpdate(res.target)
  of actionList:
    doList()
  of actionListRegistry:
    listRegistry()
  of actionHelp, actionNone:
    showHelp()

when isMainModule:
  main()
