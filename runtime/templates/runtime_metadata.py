#!/usr/bin/env python3
import hashlib
import json
import os
import re
import stat
import sys

MAX_LOCK = 8192
MAX_MANIFEST = 1024 * 1024
MAX_ARCHIVE = 64 * 1024 * 1024
MAX_TARGETS = 16
MAX_DEPTH = 8
MAX_NODES = 1024
TARGETS = {"linux-x86_64", "macos-arm64"}
MANDATORY = {
    "LICENSE", "README.txt", "REVISION", "THIRD_PARTY_NOTICES", "VERSION",
    "bin/kb", "share/clamp/migrations/0001_enable_vector.sql",
    "share/clamp/migrations/0002_application_schema.sql",
    "share/clamp/templates/AGENTS.md", "share/clamp/templates/README.md",
    "share/clamp/templates/gitignore", "share/clamp/templates/resume",
    "share/clamp/templates/runtime_metadata.py", "share/clamp/templates/setup",
    "share/clamp/templates/skill.md",
}
VERSION = re.compile(r"(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\Z")
REVISION = re.compile(r"[0-9a-f]{40}\Z")
DIGEST = re.compile(r"[0-9a-f]{64}\Z")
COMPONENT = re.compile(r"[A-Za-z0-9._+-]+\Z")


def fail(message):
    raise SystemExit(message)


def pairs(values):
    result = {}
    for key, value in values:
        if key in result:
            fail("duplicate JSON key")
        result[key] = value
    return result


def read_regular(path, maximum):
    before = os.lstat(path)
    if not stat.S_ISREG(before.st_mode) or before.st_size > maximum:
        fail("unsafe metadata file")
    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    descriptor = os.open(path, flags)
    try:
        opened = os.fstat(descriptor)
        if (opened.st_ino, opened.st_dev, opened.st_size) != (
                before.st_ino, before.st_dev, before.st_size):
            fail("metadata file changed")
        chunks = []
        remaining = opened.st_size
        while remaining:
            chunk = os.read(descriptor, min(65536, remaining))
            if chunk == b"":
                fail("metadata file changed")
            chunks.append(chunk)
            remaining -= len(chunk)
        after = os.fstat(descriptor)
        if (after.st_ino, after.st_dev, after.st_size, after.st_mtime_ns) != (
                opened.st_ino, opened.st_dev, opened.st_size, opened.st_mtime_ns):
            fail("metadata file changed")
        return b"".join(chunks)
    finally:
        os.close(descriptor)


def bounded(value, depth=1, count=None):
    if count is None:
        count = [0]
    count[0] += 1
    if count[0] > MAX_NODES or depth > MAX_DEPTH:
        fail("JSON structural limit")
    if isinstance(value, dict):
        for child in value.values():
            bounded(child, depth + 1, count)
    elif isinstance(value, list):
        for child in value:
            bounded(child, depth + 1, count)
    elif isinstance(value, (str, int)) and not isinstance(value, bool):
        pass
    else:
        fail("unsupported JSON value")


def parse_json(raw):
    try:
        text = raw.decode("utf-8", "strict")
        value = json.loads(text, object_pairs_hook=pairs,
                           parse_float=lambda _: fail("float not allowed"),
                           parse_constant=lambda _: fail("constant not allowed"))
    except (UnicodeDecodeError, json.JSONDecodeError):
        fail("invalid JSON")
    bounded(value)
    return value


def exact(value, keys):
    return isinstance(value, dict) and set(value) == set(keys)


def release_base(version):
    return f"https://github.com/gvrooyen/clamp/releases/download/v{version}/"


def valid_path(value):
    return (isinstance(value, str) and 0 < len(value.encode()) <= 4096
            and not value.startswith("/") and not value.endswith("/")
            and all(COMPONENT.fullmatch(part) for part in value.split("/")))


def parse_lock(path, target):
    if target not in TARGETS:
        fail("unsupported target")
    raw = read_regular(path, MAX_LOCK)
    if raw.startswith(b"version="):
        try:
            lines = raw.decode("utf-8", "strict").splitlines()
        except UnicodeDecodeError:
            fail("invalid v1 lock")
        if len(lines) != 4 or target != "linux-x86_64":
            fail("v1 lock requires Linux x86-64 migration")
        fields = {}
        for line, key in zip(lines, ("version", "revision", "url", "sha256")):
            prefix = key + "="
            if not line.startswith(prefix):
                fail("invalid v1 lock")
            fields[key] = line[len(prefix):]
        expected = release_base(fields["version"]) + f"clamp-{fields['version']}-linux-x86_64.tar.gz"
        if (not VERSION.fullmatch(fields["version"])
                or not REVISION.fullmatch(fields["revision"])
                or fields["url"] != expected or not DIGEST.fullmatch(fields["sha256"])):
            fail("invalid v1 lock")
        print("v1", fields["version"], fields["revision"], fields["url"],
              fields["sha256"], sep="\n")
        return
    value = parse_json(raw)
    if not exact(value, ("schema_version", "version", "revision", "manifest_url",
                         "manifest_sha256")) or value["schema_version"] != 2:
        fail("invalid v2 lock")
    version = value["version"]
    expected = release_base(version) + f"clamp-{version}-runtime-manifest.json"
    if (not isinstance(version, str) or not VERSION.fullmatch(version)
            or not isinstance(value["revision"], str)
            or not REVISION.fullmatch(value["revision"])
            or value["manifest_url"] != expected
            or not isinstance(value["manifest_sha256"], str)
            or not DIGEST.fullmatch(value["manifest_sha256"])):
        fail("invalid v2 lock")
    print("v2", version, value["revision"], value["manifest_url"],
          value["manifest_sha256"], sep="\n")


def parse_manifest(path, version, revision, target, expected_digest):
    raw = read_regular(path, MAX_MANIFEST)
    if hashlib.sha256(raw).hexdigest() != expected_digest:
        fail("manifest checksum mismatch")
    value = parse_json(raw)
    if (not exact(value, ("schema_version", "version", "revision", "targets"))
            or value["schema_version"] != 1 or value["version"] != version
            or value["revision"] != revision or not isinstance(value["targets"], list)
            or not 0 < len(value["targets"]) <= MAX_TARGETS):
        fail("invalid manifest")
    names = []
    selected = None
    for entry in value["targets"]:
        if not exact(entry, ("target", "archive_url", "archive_sha256",
                             "archive_root", "archive_size", "required_files")):
            fail("invalid target record")
        name = entry["target"]
        files = entry["required_files"]
        expected_name = f"clamp-{version}-{name}.tar.gz"
        if (name not in TARGETS or entry["archive_url"] != release_base(version) + expected_name
                or not isinstance(entry["archive_sha256"], str)
                or not DIGEST.fullmatch(entry["archive_sha256"])
                or entry["archive_root"] != f"clamp-{version}-{name}"
                or isinstance(entry["archive_size"], bool)
                or not isinstance(entry["archive_size"], int)
                or not 0 < entry["archive_size"] <= MAX_ARCHIVE
                or not isinstance(files, list) or not 0 < len(files) <= 256
                or files != sorted(set(files)) or not all(valid_path(item) for item in files)
                or not MANDATORY.issubset(files)):
            fail("invalid target record")
        names.append(name)
        if name == target:
            selected = entry
    if names != sorted(set(names)):
        fail("duplicate or unsorted targets")
    if selected is None:
        fail("target missing")
    print(selected["archive_url"], selected["archive_sha256"],
          selected["archive_root"], selected["archive_size"], sep="\n")


if len(sys.argv) == 4 and sys.argv[1] == "lock":
    parse_lock(sys.argv[2], sys.argv[3])
elif len(sys.argv) == 7 and sys.argv[1] == "manifest":
    parse_manifest(*sys.argv[2:])
else:
    fail("usage error")
