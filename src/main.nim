import parse
import loggins
import state
import registry
import std/[json, strutils, os, osproc, times]
import helpers 

type
  BuildCandidate = object
    label:     string
    genCmd:    string
    buildCmd:  string
    instCmd:   string
    needsClean: bool

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

proc doInstall*(res: ParseResult) =
  let pkg = res.target
  if pkg == "": return

  var repoName = ""
  var subPath  = ""

  # Splitting the url
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

  # dependency resolution (before building this package)
  resolveDependencies(repoName)

  # Get the URL
  let url = findPackage(repoName)
  if url == "":
    logErr "Package '" & repoName & "' not found in registry and is not a valid URL."
    quit(1)

  # Find the clone folder (inside ~/.ins/src/)
  let srcRoot = getSourceRoot()
  var folder  = repoName.lastPathPart()
  if folder.endsWith(".git"):
    folder = folder[0..^5]

  loglns "Found " & folder & " at " & url

  # Cloning done here
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

  let targetDir = if subPath != "": cloneDir / subPath else: cloneDir
  if dirExists(targetDir):
    loglns "Entering directory: ", targetDir
    setCurrentDir(targetDir)
  else:
    logErr "Sub-directory '" & subPath & "' not found in " & folder
    setCurrentDir(prevDir)
    quit(1)

  # Submodules initing
  if fileExists(".gitmodules"):
    loglns "Submodules found! Initializing..."
    if execCmd("git submodule update --init --recursive") != 0:
      logErr "Submodule initialization failed."
      setCurrentDir(prevDir)
      quit(1)

  # Capture git hash for state json file
  let gitHash = getGitHash(cloneDir)

  # Build flags
  loglns "--- Installing: ", targetDir.lastPathPart(), " ---"
  if res.metaArgs != "":
    loglns "Applying flags to metabuild: ", res.metaArgs
  if res.makeArgs != "":
    loglns "Applying flags to build: ", res.makeArgs

  let meta  = res.metaArgs
  let build = res.makeArgs

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

proc doUpdate*(pkgName: string) =
  let baseName = if pkgName.contains('/'): pkgName.split('/')[0] 
                 else: pkgName

  let (found, record) = stateLookup(baseName)
  if not found:
    logErr "Package '" & pkgName & "' is not installed."
    quit(1)

  loglns "Checking for updates: " & baseName

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

proc doUninstall*(pkgName: string) =
  let baseName = if pkgName.contains('/'): pkgName.split('/')[0] 
                 else: pkgName

  let (found, record) = stateLookup(baseName)
  if not found:
    logErr "Package '" & pkgName & "' is not tracked in the ledger."
    quit(1)

  loglns "Uninstalling: " & baseName

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

  if record.configsDeployed.len > 0:
    loglns "Config files left in place to preserve your edits:"
    for c in record.configsDeployed:
      loglns "  ", c

  stateRemove(baseName)
  logDone "Uninstalled " & pkgName & "."

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

let version = "0.2.6"

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

  let lookupName = if res.target.contains('/'): res.target.split('/')[0] 
                   else: res.target  

  case res.action
  of actionInstall:
    let (alreadyInstalled, _) = stateLookup(lookupName)
    if alreadyInstalled:
      loglns "Package '" & lookupName & "' is already installed. Switching to update..."
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
