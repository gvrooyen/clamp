#!/usr/bin/env python3
import importlib.util
from importlib.machinery import SourceFileLoader
import pathlib
import sys


path = pathlib.Path(sys.argv[1])
spec = importlib.util.spec_from_loader(
    "clamp_build_macos", SourceFileLoader("clamp_build_macos", str(path)))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

assert module.system("/usr/lib/libSystem.B.dylib")
assert module.system("/System/Library/Frameworks/Security.framework/Security")
assert not module.system("@loader_path/libpq.5.dylib")
assert not module.system("/opt/private/libexample.dylib")

for escaped in (
    "/usr/lib/../../opt/private/libexample.dylib",
    "/usr/lib//libSystem.B.dylib",
    "/System/Library/Frameworks/../private.dylib",
):
    try:
        module.system(escaped)
    except RuntimeError as error:
        assert str(error) == "noncanonical absolute dependency"
    else:
        raise AssertionError("noncanonical system dependency accepted")
