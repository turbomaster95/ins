import parse
import loggins
import std/[httpclient, json, strutils, os, osproc]

const RegistryUrl = "https://raw.githubusercontent.com/turbomaster95/registry/main/packages.json"

proc findPackage*(pkgName: string): string =
  ## Returns the URL from the registry OR the input if it looks like a repo.
  
  # 1. Detection logic for direct repository links
  # We check for protocol or git-specific patterns
  let isDirectUrl = pkgName.contains("://") or
                    pkgName.startsWith("git@") or
                    pkgName.endsWith(".git")

  if isDirectUrl:
    # Return the URL as-is, just stripping trailing slashes
    return pkgName.strip(chars = {'/'}, leading = false, trailing = true)

  # 2. Registry fallback
  let client = newHttpClient()
  try:
    loglns "Updating registry..."
    let content = client.getContent(RegistryUrl)
    let jsonNode = parseJson(content)

    for item in jsonNode:
      if item["name"].getStr() == pkgName:
        return item["url"].getStr()

    # If we reach here, it's not in the registry and not a URL
    return ""
  except:
    logErr "Could not reach the registry."
    return ""
  finally:
    client.close()

proc checkCmd(cmd: string): bool =
  if cmd == "": return true
  
  # Split by " && " to check both sides of a pipeline
  let subCmds = cmd.split(" && ")
  for sub in subCmds:
    let bin = sub.strip().split(' ')[0]
    # Skip checking if it's a local script like ./configure or ./autogen.sh
    if bin.startsWith("./"): continue
    if bin.startsWith("sh"): continue
    if bin.startsWith("bash"): continue
    
    if findExe(bin) == "":
      logErr "Required tool '", bin, "' is missing from your system."
      return false
  return true

proc doInstall*(res: ParseResult) =
  let pkg = res.target
  if pkg == "": return

  var repoName = ""
  var subPath = ""

  # 1. Protocol-Aware Splitting
  if pkg.contains("://"):
    # Split by protocol to avoid splitting the "https://" slashes
    let urlParts = pkg.split("://")
    let protocol = urlParts[0]
    let rest = urlParts[1]
    
    let pathSegments = rest.split('/')
    
    # Git hosts usually follow: host/user/repo (3 segments)
    # e.g., github.com/turbomaster95/sane.tools/mk
    if pathSegments.len > 3:
      # We reconstruct the base repo and capture the subpath
      repoName = protocol & "://" & pathSegments[0..2].join("/")
      subPath = pathSegments[3..^1].join("/")
    else:
      repoName = pkg
  else:
    # Standard Shorthand/Registry Splitting (e.g., sane.tools/mk)
    let parts = pkg.split('/')
    repoName = parts[0]
    subPath = if parts.len > 1: parts[1..^1].join("/") else: ""

  # 2. URL Retrieval
  let url = findPackage(repoName)
  if url == "":
    logErr "Package '" & repoName & "' not found in registry and is not a valid URL."
    quit(1)

  # 3. Determine Clone Folder
  # folder should be 'sane.tools', not 'sane.tools/mk'
  var folder = repoName.lastPathPart()
  if folder.endsWith(".git"):
    folder = folder[0..^5]

  loglns "Found " & folder & " at " & url

  # 4. Clone Logic
  if not dirExists(folder):
    loglns "Cloning " & repoName & "..."
    var exCode = execCmd("git clone -q --depth 1 " & url)
    if exCode != 0:
      logWarn "Shallow Clone failed, trying full clone..."
      exCode = execCmd("git clone -q " & url)

    if exCode != 0:
      logErr "Package " & repoName & " cannot be cloned!"
      quit(1)
  else:
    loglns "Folder '" & folder & "' already exists. Skipping clone."

  # 5. Enter Directory (Handling sub-paths)
  # targetDir becomes something like "sane.tools/mk"
  let targetDir = if subPath != "": folder / subPath else: folder
  
  if dirExists(targetDir):
    loglns "Entering directory: ", targetDir
    setCurrentDir(targetDir) 
  else:
    logErr "Sub-directory '" & subPath & "' not found in " & folder
    quit(1)

  # 6. Submodules
  if fileExists(".gitmodules"):
    echo "Submodules found! Initializing..."
    if execCmd("git submodule update --init --recursive") != 0:
      logErr "Submodule initialization failed."
      quit(1)

  # 7. Build execution with flags
  echo "--- Installing: ", targetDir.lastPathPart(), " ---"
  if res.metaArgs != "":
    loglns "Applying flags to metabuild: ", res.metaArgs
  if res.makeArgs != "":
    loglns "Applying flags to build: ", res.makeArgs

  # --- Build System Detection & Execution ---
  var 
    genCmd = ""
    buildCmd = ""
    needsClean = false
    instCmd = ""
  
  let meta = res.metaArgs
  let build = res.makeArgs

  # 1. GENERATOR STEP (Meta-Builders)
  if fileExists("CMakeLists.txt"):
    genCmd = "cmake . " & meta
    buildCmd = "make " & build
    needsClean = true
  elif fileExists("meson.build"):
    genCmd = "meson setup build " & meta
    buildCmd = "ninja -C build " & build
  elif fileExists("premake5.lua") or fileExists("premake4.lua"):
    let pVer = if fileExists("premake5.lua"): "premake5" else: "premake4"
    genCmd = pVer & " gmake2 " & meta
    buildCmd = "make " & build
    needsClean = true
  elif fileExists("configure.ac") or fileExists("configure.in") or fileExists("autogen.sh"):
    if fileExists("autogen.sh"): discard execCmd("./autogen.sh")
    genCmd = "./configure " & meta
    buildCmd = "make " & build
    needsClean = true
  elif fileExists("configure"):
    genCmd = "./configure " & meta
    buildCmd = "make " & build
    needsClean = true

  # 2. STANDALONE STEP (Only runs if no Generator was found)
  if genCmd == "":
    if fileExists("Cargo.toml"):
      buildCmd = "cargo build --release " & meta & " " & build
      instCmd = "cargo fetch"
    elif fileExists("nim.ble") or fileExists(folder & ".nimble"):
      buildCmd = "nimble build -d:release " & meta & " " & build
      instCmd = "nimble install -y --depsOnly"
    elif fileExists("v.mod"):
      buildCmd = "v " & meta & " " & build & " ."
    elif fileExists("build.zig"):
      buildCmd = "zig build -Doptimize=ReleaseSafe " & meta & " " & build
    elif fileExists("go.mod"):
      buildCmd = "go build " & meta & " " & build
      instCmd = "go mod download"
    elif fileExists("package.json"):
      let manager = if fileExists("bun.lockb"): "bun" elif fileExists("yarn.lock"): "yarn" else: "npm"
      buildCmd = manager & " run build " & meta & " " & build
      instCmd =  manager & " install"
    elif fileExists("pyproject.toml") or fileExists("poetry.lock"):
      buildCmd = " poetry build " & meta & " " & build
      instCmd = "poetry install"
    elif fileExists("flit.ini"):
      buildCmd = "flit build " & meta & " " & build
    elif fileExists("stack.yaml") or fileExists("cabal.project"):
      let hTask = if fileExists("stack.yaml"): "stack" else: "cabal"
      buildCmd = hTask & " build " & meta & " " & build
    elif fileExists("build.gradle") or fileExists("build.gradle.kts"):
      let gradlew = if fileExists("gradlew"): "./gradlew" else: "gradle"
      buildCmd = gradlew & " build " & meta & " " & build
    elif fileExists("pom.xml"):
      buildCmd = "mvn package " & meta & " " & build
    elif fileExists("build.xml"):
      buildCmd = "ant " & meta & " " & build
    elif fileExists("WORKSPACE") or fileExists("BUILD.bazel"):
      buildCmd = "bazel build //... " & meta & " " & build
    elif fileExists("BUCK"):
      let bBinary = if findExe("buck2") != "": "buck2" else: "buck"
      buildCmd = bBinary & " build //... " & meta & " " & build
    elif fileExists("pants.toml"):
      buildCmd = "pants package ::"
    elif fileExists("pleasew") or fileExists(".plzconfig"):
      let plzCmd = if fileExists("pleasew"): "./pleasew" else: "plz"
      buildCmd = plzCmd & " build " & meta & " " & build
    elif fileExists("SConstruct"):
      buildCmd = "scons " & meta & " " & build
    elif fileExists("wscript"):
      buildCmd = "python waf configure build " & meta & " " & build
    elif fileExists("bitbake.conf") or dirExists("recipes-"):
      buildCmd = "bitbake " & meta & " " & build
    elif fileExists("build.ninja"):
      buildCmd = "ninja " & meta & " " & build
    elif fileExists("Tupfile"):
      buildCmd = "tup " & meta & " " & build
    elif fileExists("justfile"):
      buildCmd = "just " & meta & " " & build
    elif fileExists("Makefile") or fileExists("makefile") or fileExists("GNUmakefile"):
      buildCmd = "make " & meta & " " & build
      needsClean = true
    elif fileExists("mkfile"):
      buildCmd = "mk " & meta & " " & build
    elif fileExists("bootstrap.sh"):
      buildCmd = "sh bootstrap.sh " & meta & " " & build
    elif fileExists("setup.sh"):
      buildCmd = "sh setup.sh " & meta & " " & build

  # --- Execution Engine ---

  # First run the Generator (if any)
  if genCmd != "":
   if checkCmd(genCmd):
    echo "Running generator: ", genCmd
    if execCmd(genCmd) != 0:
      logErr "Generation step failed."
      quit(1)
   else:
      quit(1)

  # Then run the Build command
  if buildCmd != "":
   loglns "Detected system. Executing: ", buildCmd
   if checkCmd(buildCmd):
    if instCmd != "":
        loglns "Installing dependencies for: ", pkg
        if execCmd(instCmd) != 0:
          logErr "Could'nt install dependencies for project!"
          quit(1)
    if execCmd(buildCmd) != 0:
      if needsClean:
        logErr "Build failed. Retrying with Hard Reset..."
        setCurrentDir("..")
        removeDir(folder)
        doInstall(res) 
        quit(0)
      else:
        logErr "Build failed for " & folder
   else:
     quit(1) 
  else:
    loglns "No recognized build system found in " & folder

  logDone "Done building!"
  

let version = "0.0.1"

proc showHelp() =
  let templateHelp = """
ins - light package manager v$1

Usage:
  ins <package>       - Install a package
  ins i <package>     - Install a package
  ins rm <package>    - Remove a package
  """ 
  echo templateHelp % [version]

proc main() =
  let res = parseArgs()

  case res.action
  of actionInstall:
    doInstall(res)
  of actionRemove:
    echo "Removing: ", res.target
  of actionHelp, actionNone:
    showHelp()

when isMainModule:
  main()

