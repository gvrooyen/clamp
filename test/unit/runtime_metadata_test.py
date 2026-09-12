#!/usr/bin/env python3
import hashlib
import json
import os
import pathlib
import subprocess
import tarfile
import tempfile

ROOT = pathlib.Path(os.environ["DUNE_SOURCEROOT"])
PARSER = ROOT / "runtime/templates/runtime_metadata.py"
MANIFEST = ROOT / "release/manifest"
KB = pathlib.Path(os.environ["CLAMP_TEST_KB"])
VERSION = "0.2.0"
REVISION = "0123456789abcdef0123456789abcdef01234567"
TARGETS = ("linux-x86_64", "macos-arm64")


def run(*args, ok=True):
    result = subprocess.run(args, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if (result.returncode == 0) != ok:
        raise AssertionError((args, result.returncode, result.stdout, result.stderr))
    return result


def write(path, data, mode=0o644):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(data)
    path.chmod(mode)


def package(directory, target, changed_template=False):
    root = directory / f"clamp-{VERSION}-{target}"
    write(root / "bin/kb", f"#!/bin/sh\nprintf '%s\\n' '{VERSION}'\n".encode(), 0o755)
    write(root / "VERSION", f"{VERSION}\n".encode())
    write(root / "REVISION", f"{REVISION}\n".encode())
    for name in ("LICENSE", "README.txt", "THIRD_PARTY_NOTICES"):
        write(root / name, (name + "\n").encode())
    for source in sorted((ROOT / "db/migrations").glob("*.sql")):
        write(root / "share/clamp/migrations" / source.name, source.read_bytes())
    for name in ("AGENTS.md", "README.md", "gitignore", "resume", "runtime_metadata.py", "setup", "skill.md"):
        data = (ROOT / "runtime/templates" / name).read_bytes()
        if changed_template and name == "README.md":
            data += b"changed\n"
        write(root / "share/clamp/templates" / name, data,
              0o755 if name in ("resume", "setup") else 0o644)
    archive = directory / f"clamp-{VERSION}-{target}.tar.gz"
    with tarfile.open(archive, "w:gz") as bundle:
        bundle.add(root, arcname=root.name)
    digest = hashlib.sha256(archive.read_bytes()).hexdigest()
    write(pathlib.Path(str(archive) + ".sha256"), f"{digest}  {archive.name}\n".encode())
    return archive


with tempfile.TemporaryDirectory(prefix="clamp-runtime-metadata-") as temporary:
    work = pathlib.Path(temporary)
    archives = [package(work, target) for target in TARGETS]
    result = run(str(MANIFEST), VERSION, REVISION, *map(str, archives))
    manifest_path = pathlib.Path(result.stdout.decode().strip())
    first = manifest_path.read_bytes()
    first_checksum = pathlib.Path(str(manifest_path) + ".sha256").read_bytes()
    run(str(MANIFEST), VERSION, REVISION, *reversed(tuple(map(str, archives))))
    assert manifest_path.read_bytes() == first
    assert pathlib.Path(str(manifest_path) + ".sha256").read_bytes() == first_checksum

    manifest = json.loads(first)
    assert [entry["target"] for entry in manifest["targets"]] == sorted(TARGETS)
    digest = hashlib.sha256(first).hexdigest()
    run("python3", str(PARSER), "manifest", str(manifest_path), VERSION,
        REVISION, "linux-x86_64", digest)

    lock = work / "lock.json"
    lock.write_text(json.dumps({
        "schema_version": 2, "version": VERSION, "revision": REVISION,
        "manifest_url": f"https://github.com/gvrooyen/clamp/releases/download/v{VERSION}/clamp-{VERSION}-runtime-manifest.json",
        "manifest_sha256": digest,
    }, separators=(",", ":")) + "\n")
    run("python3", str(PARSER), "lock", str(lock), "macos-arm64")
    for index, hostile in enumerate((
        first.replace(b'"schema_version":1', b'"schema_version":1,"schema_version":1', 1),
        first.replace(b'"archive_size":', b'"archive_size":1.5,"ignored":', 1),
        first.replace(b'"archive_size":', b'"archive_size":999999999999999999999999999999999999, "ignored":', 1),
        first.replace(b"https://github.com", b"http://github.com", 1),
    )):
        bad = work / f"bad-{index}.json"
        bad.write_bytes(hostile)
        bad_digest = hashlib.sha256(hostile).hexdigest()
        run("python3", str(PARSER), "manifest", str(bad), VERSION, REVISION,
            "linux-x86_64", bad_digest, ok=False)
        hostile_target = work / f"hostile-{index}"
        run(str(KB), "init", "--repo", str(hostile_target),
            "--source-repository", "example.invalid/owner/private",
            "--runtime-version", VERSION, "--runtime-target", "linux-x86_64",
            "--runtime-manifest", str(bad),
            "--runtime-manifest-sha256", bad_digest,
            "--runtime-archive", str(archives[0]), "--json", ok=False)
        assert not hostile_target.exists()

    mismatched = package(work / "mismatch", "macos-arm64", changed_template=True)
    run(str(MANIFEST), VERSION, REVISION, str(archives[0]), str(mismatched), ok=False)

    target = work / "private"
    run(str(KB), "init", "--repo", str(target),
        "--source-repository", "example.invalid/owner/private",
        "--runtime-version", VERSION, "--runtime-target", "linux-x86_64",
        "--runtime-manifest", str(manifest_path),
        "--runtime-manifest-sha256", digest,
        "--runtime-archive", str(archives[0]), "--json")
    assert (target / ".git/HEAD").is_file()
    assert not any((target / name).exists() for name in ("bin", "lib", "dune-project"))
    failed_target = work / "failed-private"
    run(str(KB), "init", "--repo", str(failed_target),
        "--source-repository", "example.invalid/owner/private",
        "--runtime-version", VERSION, "--runtime-target", "linux-x86_64",
        "--runtime-manifest", str(manifest_path),
        "--runtime-manifest-sha256", "0" * 64,
        "--runtime-archive", str(archives[0]), "--json", ok=False)
    assert not failed_target.exists()
