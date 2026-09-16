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
    for name in ("AGENTS.md", "README.md", "gitignore", "kb", "resume",
                 "runtime_metadata.py", "setup", "setup-local", "skill.md"):
        data = (ROOT / "runtime/templates" / name).read_bytes()
        if changed_template and name == "README.md":
            data += b"changed\n"
        write(root / "share/clamp/templates" / name, data,
              0o755 if name in ("kb", "resume", "setup", "setup-local") else 0o644)
    if target == "macos-arm64":
        write(root / "share/licenses/libpq.5.dylib.txt", b"fixture license\n")
    archive = directory / f"clamp-{VERSION}-{target}.tar.gz"
    with tarfile.open(archive, "w:gz") as bundle:
        bundle.add(root, arcname=root.name)
    digest = hashlib.sha256(archive.read_bytes()).hexdigest()
    write(pathlib.Path(str(archive) + ".sha256"), f"{digest}  {archive.name}\n".encode())
    return archive


with tempfile.TemporaryDirectory(prefix="clamp-runtime-metadata-") as temporary:
    work = pathlib.Path(temporary)
    supported_amp = run("python3", str(PARSER), "amp-version",
                        "amp 0.0.1789171288-gd95a61").stdout.decode().splitlines()
    assert supported_amp == ["ok", "0.0.1789171288-gd95a61"]
    stale_amp = run("python3", str(PARSER), "amp-version",
                    "0.0.1-gdeadbeef").stdout.decode().splitlines()
    assert stale_amp == ["unsupported", "0.0.1-gdeadbeef"]
    amp_home = work / "amp-home"
    amp = amp_home / ".amp/bin/amp"
    write(amp, b"#!/bin/sh\n", 0o700)
    run("python3", str(PARSER), "verify-amp", str(amp_home), str(amp))
    amp.parent.chmod(0o770)
    run("python3", str(PARSER), "verify-amp", str(amp_home), str(amp), ok=False)
    amp.parent.chmod(0o700)
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
    required = next(entry["required_files"] for entry in manifest["targets"]
                    if entry["target"] == "linux-x86_64")
    digest = hashlib.sha256(first).hexdigest()
    run("python3", str(PARSER), "manifest", str(manifest_path), VERSION,
        REVISION, "linux-x86_64", digest)
    missing = run("python3", str(PARSER), "manifest", str(manifest_path), VERSION,
                  REVISION, "unsupported-target", digest, ok=False)
    assert missing.stderr == b"target missing\n"

    # The generated local installer and Orb setup share these exact bounded
    # archive, private-directory, immutable-install, and manifest-cache helpers.
    home = work / "empty-home"
    home.mkdir(mode=0o700)
    install_base = home / ".local/share/clamp/kb"
    manifests = install_base / "manifests"
    runtimes = install_base / "runtimes/linux-x86_64"
    run("python3", str(PARSER), "private-dirs", str(home), str(install_base),
        str(manifests), str(install_base / "runtimes"), str(runtimes))
    archive_digest = hashlib.sha256(archives[0].read_bytes()).hexdigest()
    run("python3", str(PARSER), "digest", str(archives[0]), archive_digest)
    extracted = work / "extracted"
    run("python3", str(PARSER), "extract", str(archives[0]), str(extracted),
        VERSION, REVISION, f"clamp-{VERSION}-linux-x86_64",
        str(archives[0].stat().st_size), *required)
    mac_required = next(entry["required_files"] for entry in manifest["targets"]
                        if entry["target"] == "macos-arm64")
    mac_extracted = work / "mac-extracted"
    run("python3", str(PARSER), "extract", str(archives[1]), str(mac_extracted),
        VERSION, REVISION, f"clamp-{VERSION}-macos-arm64",
        str(archives[1].stat().st_size), *mac_required)
    assert (mac_extracted / f"clamp-{VERSION}-macos-arm64/share/licenses/libpq.5.dylib.txt").is_file()

    traversal = work / "traversal.tar.gz"
    with tarfile.open(traversal, "w:gz") as bundle:
        source_root = work / f"clamp-{VERSION}-linux-x86_64"
        bundle.add(source_root, arcname=source_root.name)
        directory = tarfile.TarInfo(f"{source_root.name}/../escaped")
        directory.type = tarfile.DIRTYPE
        bundle.addfile(directory)
    run("python3", str(PARSER), "extract", str(traversal),
        str(work / "must-not-extract"), VERSION, REVISION, source_root.name,
        str(traversal.stat().st_size), *required, ok=False)
    assert not (work / "escaped").exists()
    traversal_release = work / "traversal-release"
    traversal_release.mkdir()
    traversal_archive = traversal_release / f"clamp-{VERSION}-linux-x86_64.tar.gz"
    traversal_archive.write_bytes(traversal.read_bytes())
    traversal_digest = hashlib.sha256(traversal_archive.read_bytes()).hexdigest()
    write(pathlib.Path(str(traversal_archive) + ".sha256"),
          f"{traversal_digest}  {traversal_archive.name}\n".encode())
    run(str(MANIFEST), VERSION, REVISION, str(traversal_archive),
        str(archives[1]), ok=False)
    payload = extracted / f"clamp-{VERSION}-linux-x86_64"
    write(payload / ".archive-sha256", (archive_digest + "\n").encode(), 0o600)
    installation = runtimes / archive_digest
    run("python3", str(PARSER), "install", str(payload), str(installation))
    run("python3", str(PARSER), "installed", str(installation), VERSION,
        REVISION, archive_digest)
    hostile_installation = work / "hostile-installation"
    hostile_installation.mkdir()
    write(hostile_installation / "VERSION", f"{VERSION}\n".encode())
    write(hostile_installation / "REVISION", f"{REVISION}\n".encode())
    write(hostile_installation / ".archive-sha256", (archive_digest + "\n").encode())
    (hostile_installation / "bin").symlink_to(installation / "bin")
    run("python3", str(PARSER), "installed", str(hostile_installation), VERSION,
        REVISION, archive_digest, ok=False)
    cached_manifest = manifests / f"{digest}.json"
    run("python3", str(PARSER), "cache", str(manifest_path),
        str(cached_manifest), digest)
    run("python3", str(PARSER), "cache", str(manifest_path),
        str(cached_manifest), digest)
    assert cached_manifest.read_bytes() == first

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
