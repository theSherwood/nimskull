discard """
  targets: "cpp"
  output: "hello"
  cmd: "nim cpp --clearNimblePath --nimblePath:build/deps/pkgs $file"
"""

# bug #3299

# import jester # xxx: why the hell are we doing crap like this?
import asyncdispatch, asyncnet

# bug #5081
#import nre

echo "hello"
