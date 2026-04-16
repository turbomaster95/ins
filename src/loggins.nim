import std/terminal

proc loglns*(args: varargs[string, `$`]) =
  ## Drop-in replacement for echo with green [ins] prefix
  stdout.styledWrite(fgGreen, styleBright, "[ins] ", resetStyle)
  for arg in args:
    stdout.write(arg)
  stdout.write("\n")
  stdout.flushFile() # Ensures output appears immediately

proc logErr*(args: varargs[string, `$`]) =
  ## Drop-in replacement for echo with red Error prefix
  stdout.styledWrite(fgRed, styleBright, "Error: ", resetStyle)
  for arg in args:
    stdout.write(arg)
  stdout.write("\n")
  stdout.flushFile()

proc logDone*(args: varargs[string, `$`]) =
  stdout.styledWrite(fgCyan, styleBright, "[ins] ", resetStyle)
  for arg in args:
    stdout.write(arg)
  stdout.write("\n")

proc logWarn*(args: varargs[string, `$`]) =
  ## Drop-in replacement for echo with yellow Warning prefix
  stdout.styledWrite(fgYellow, styleBright, "Warning: ", resetStyle)
  for arg in args:
    stdout.write(arg)
  stdout.write("\n")
  stdout.flushFile()

