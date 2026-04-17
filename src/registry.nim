import std/[httpclient, json, strutils]
import loggins
import state

const RegistryUrl = "https://raw.githubusercontent.com/turbomaster95/registry/main/packages.json"

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

proc fetchRegistryEntry*(pkgName: string): JsonNode =
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
