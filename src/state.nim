import std/[json, os, strutils]

proc getBinDir*(): string =
  ## Returns the best writable bin directory for the current environment.
  ## Prefers Termux $PREFIX/bin, then ~/.local/bin.
  let termuxPrefix = getEnv("PREFIX")
  if termuxPrefix != "" and termuxPrefix.contains("com.termux"):
    return termuxPrefix / "bin"
  result = getHomeDir() / ".local" / "bin"
  createDir(result)

proc getInsHome*(): string =
  ## Returns (and creates if needed) the ins state directory ~/.ins/
  result = getHomeDir() / ".ins"
  createDir(result)

proc getSourceRoot*(): string =
  ## All cloned repos live under ~/.ins/src/
  result = getInsHome() / "src"
  createDir(result)

proc getStatePath*(): string =
  return getInsHome() / "state.json"

type
  InstalledPkg* = object
    name*:            string
    url*:             string
    hash*:            string
    installedAt*:     string
    sourceDir*:       string
    symlinks*:        seq[string]
    configsDeployed*: seq[string]

proc loadState*(): JsonNode =
  let path = getStatePath()
  if not fileExists(path):
    return newJArray()
  try:
    return parseJson(readFile(path))
  except:
    return newJArray()

proc saveState*(state: JsonNode) =
  writeFile(getStatePath(), state.pretty())

proc pkgToJson*(p: InstalledPkg): JsonNode =
  result = newJObject()
  result["name"]            = %p.name
  result["url"]             = %p.url
  result["hash"]            = %p.hash
  result["installedAt"]     = %p.installedAt
  result["sourceDir"]       = %p.sourceDir
  result["symlinks"]        = %p.symlinks
  result["configsDeployed"] = %p.configsDeployed

proc jsonToPkg*(j: JsonNode): InstalledPkg =
  result.name        = j{"name"}.getStr()
  result.url         = j{"url"}.getStr()
  result.hash        = j{"hash"}.getStr()
  result.installedAt = j{"installedAt"}.getStr()
  result.sourceDir   = j{"sourceDir"}.getStr()
  if j{"symlinks"} != nil:
    for s in j{"symlinks"}: result.symlinks.add(s.getStr())
  if j{"configsDeployed"} != nil:
    for c in j{"configsDeployed"}: result.configsDeployed.add(c.getStr())

proc stateAddOrUpdate*(pkg: InstalledPkg) =
  var state = loadState()
  var replaced = false

  # Ensure we are dealing with an array
  if state.kind == JArray:
    for i in 0 ..< state.len:
      # Access the name for comparison
      if state[i]{"name"}.getStr() == pkg.name:
        # Assign directly to the underlying sequence
        state.elems[i] = pkgToJson(pkg)
        replaced = true
        break

    if not replaced:
      state.add(pkgToJson(pkg))

  saveState(state)

proc stateRemove*(pkgName: string) =
  var state = loadState()
  var newState = newJArray()
  for item in state:
    if item{"name"}.getStr() != pkgName:
      newState.add(item)
  saveState(newState)

proc stateLookup*(pkgName: string): (bool, InstalledPkg) =
  let state = loadState()
  for item in state:
    if item{"name"}.getStr() == pkgName:
      return (true, jsonToPkg(item))
  return (false, InstalledPkg())

