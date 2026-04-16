import std/[os, strutils]

type
  Action* = enum
    actionNone, actionInstall, actionRemove, actionHelp, actionUpdate, actionList, actionListRegistry

  ParseResult* = object
    action*: Action
    target*: string
    metaArgs*: string  # Flags for generators (e.g., cmake, configure)
    makeArgs* : string  # Flags for executors (e.g., make, ninja, -j4)

proc parseArgs*(): ParseResult =
  let args = commandLineParams()

  if args.len == 0:
    return ParseResult(action: actionHelp)

  # Find the separator index for '--'
  let sepIdx = args.find("--")

  # Internal helper to join slices safely
  proc joinArgs(s: seq[string], start: int, stop: int = -1): string =
    let last = if stop == -1: s.len - 1 else: stop
    if start >= s.len or start > last: return ""
    return s[start..last].join(" ")

  var 
    action: Action = actionNone
    target = ""
    meta = ""
    make = ""

  # Determine Action and Target
  case args[0]
  of "i", "install":
    action = actionInstall
    if args.len > 1:
      target = args[1]
      # Determine where meta flags start and end
      let endMeta = if sepIdx == -1: args.len - 1 else: sepIdx - 1
      meta = args.joinArgs(2, endMeta)
  
  of "rm", "remove":
    action = actionRemove
    if args.len > 1:
      target = args[1]
      # We don't usually need flags for remove, but we can capture them
      meta = args.joinArgs(2)
  
  of "up", "update":
    action = actionUpdate
    if args.len > 1:
       target = args[1]
  
  of "l", "list":
    if args.len > 1 and args[1] == "--all" or args.len > 1 and args[1] == "-a": 
      action = actionListRegistry
    else:
      action = actionList
  
  of "h", "help", "--help":
    return ParseResult(action: actionHelp)

  else:
    # Default: 'ins prile -Doption -- -j4'
    action = actionInstall
    target = args[0]
    let endMeta = if sepIdx == -1: args.len - 1 else: sepIdx - 1
    meta = args.joinArgs(1, endMeta)

  # Capture anything after the '--'
  if sepIdx != -1 and sepIdx < args.len - 1:
    make = args.joinArgs(sepIdx + 1)

  return ParseResult(
    action: action,
    target: target,
    metaArgs: meta,
    makeArgs: make
  )

