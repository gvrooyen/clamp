#!/usr/bin/env python3
import hashlib
import ctypes
import errno
import json
import os
import platform
import re
import selectors
import secrets
import shlex
import stat
import subprocess
import sys
import tarfile

MAX_LOCK = 8192
MAX_MANIFEST = 1024 * 1024
MAX_ARCHIVE = 64 * 1024 * 1024
MAX_TARGETS = 16
MAX_DEPTH = 8
MAX_NODES = 1024
TARGETS = {"linux-x86_64", "macos-arm64"}
SOURCE = re.compile(r"[a-z0-9.-]+/[A-Za-z0-9._@/-]+\Z")
MANDATORY = {
    "LICENSE", "README.txt", "REVISION", "THIRD_PARTY_NOTICES", "VERSION",
    "bin/kb", "share/clamp/migrations/0001_enable_vector.sql",
    "share/clamp/migrations/0002_application_schema.sql",
    "share/clamp/templates/AGENTS.md", "share/clamp/templates/README.md",
    "share/clamp/templates/gitignore", "share/clamp/templates/kb",
    "share/clamp/templates/resume", "share/clamp/templates/setup-local",
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
            and all(part not in (".", "..") and COMPONENT.fullmatch(part)
                    for part in value.split("/")))


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
          selected["archive_root"], selected["archive_size"],
          *selected["required_files"], sep="\n")


def verify_digest(path, expected):
    if not DIGEST.fullmatch(expected):
        fail("invalid digest")
    raw = read_regular(path, MAX_ARCHIVE)
    if hashlib.sha256(raw).hexdigest() != expected:
        fail("checksum mismatch")


def source_repository(path):
    raw = read_regular(path, 8 * 1024 * 1024)
    try:
        lines = raw.decode("utf-8", "strict").splitlines()
    except UnicodeDecodeError:
        fail("invalid repository configuration")
    values = [line[len("source_repository: "):] for line in lines
              if line.startswith("source_repository: ")]
    if (len(values) != 1 or not SOURCE.fullmatch(values[0])
            or any(part in ("", ".", "..") for part in values[0].split("/"))):
        fail("invalid source repository")
    print(values[0])


def version_tuple(text):
    match = re.search(r"([0-9]+(?:\.[0-9]+)+)", text)
    return tuple(int(part) for part in match.group(1).split(".")) if match else ()


def local_preflight(target, repository):
    if target == "linux-x86_64":
        tools = (("bash", "/bin/bash", (5, 2)), ("git", "/usr/bin/git", (2, 39)),
                 ("curl", "/usr/bin/curl", (7, 88, 1)),
                 ("python3", sys.executable, (3, 11)),
                 ("tar", "/usr/bin/tar", (1, 34)),
                 ("sha256sum", "/usr/bin/sha256sum", (9, 1)))
        libc = version_tuple(" ".join(platform.libc_ver()))
        if libc < (2, 36):
            print("target", target, "package", sep="\n"); return
        stat_command = ["/usr/bin/stat", "-f", "-c", "%T", repository]
        accepted_filesystems = {"ext2/ext3", "ext4"}
        rg_candidates = ("/usr/bin/rg", "/usr/local/bin/rg")
    elif target == "macos-arm64":
        tools = (("bash", "/bin/bash", (3, 2, 57)),
                 ("git", "/usr/bin/git", (2, 50, 1)),
                 ("curl", "/usr/bin/curl", (8, 7, 1)),
                 ("python3", sys.executable, (3, 9, 6)),
                 ("tar", "/usr/bin/tar", (3, 5, 3)),
                 ("shasum", "/usr/bin/shasum", (6, 2)))
        if version_tuple(platform.mac_ver()[0]) < (26, 5, 2):
            print("target", target, "package", sep="\n"); return
        stat_command = ["/usr/bin/stat", "-f", "%T", repository]
        accepted_filesystems = {"apfs"}
        rg_candidates = ("/opt/homebrew/bin/rg", "/usr/local/bin/rg", "/usr/bin/rg")
    else:
        print("target", target, "package", sep="\n"); return
    environment = {"HOME": os.environ.get("HOME", ""), "PATH": "/usr/bin:/bin"}
    for name, executable, minimum in tools:
        if not os.path.isfile(executable) or not os.access(executable, os.X_OK):
            print("prerequisite", name, ".".join(map(str, minimum)), sep="\n"); return
        try:
            output = subprocess.run([executable, "--version"], env=environment,
                                    stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                    timeout=5, check=True, text=True).stdout
        except (OSError, subprocess.SubprocessError):
            print("prerequisite", name, ".".join(map(str, minimum)), sep="\n"); return
        if version_tuple(output) < minimum:
            print("prerequisite", name, ".".join(map(str, minimum)), sep="\n"); return
    rg = next((path for path in rg_candidates if os.path.isfile(path)
               and os.access(path, os.X_OK)), None)
    if rg is None:
        print("prerequisite", "rg", "14.1", sep="\n"); return
    output = subprocess.run([rg, "--version"], env=environment, stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT, timeout=5, check=True,
                            text=True).stdout
    if version_tuple(output) < (14, 1):
        print("prerequisite", "rg", "14.1", sep="\n"); return
    try:
        filesystem = subprocess.run(stat_command, env=environment, stdout=subprocess.PIPE,
                                    stderr=subprocess.DEVNULL, timeout=5, check=True,
                                    text=True).stdout.strip().lower()
    except (OSError, subprocess.SubprocessError):
        filesystem = "unknown"
    if filesystem not in accepted_filesystems:
        print("filesystem", target, filesystem[:64] or "unknown", sep="\n"); return
    print("ok", target, sep="\n")


def verify_amp(home, executable):
    home = os.path.realpath(home)
    expected = os.path.join(home, ".amp", "bin", "amp")
    if executable != expected:
        fail("unexpected Amp executable")
    current = home
    for component in (".amp", "bin"):
        current = os.path.join(current, component)
        observed = os.lstat(current)
        if (not stat.S_ISDIR(observed.st_mode) or observed.st_uid != os.geteuid()
                or observed.st_mode & 0o022):
            fail("unsafe Amp parent")
    observed = os.lstat(executable)
    if (not stat.S_ISREG(observed.st_mode) or observed.st_uid != os.geteuid()
            or observed.st_mode & 0o022 or not observed.st_mode & stat.S_IXUSR):
        fail("unsafe Amp executable")


def verify_amp_version(observed):
    match = re.search(r"(?:^|\s)(0\.0\.([0-9]+)-g[0-9a-f]+)(?:\s|$)", observed)
    if match is None or len(match.group(1).encode()) > 64:
        print("invalid")
    elif int(match.group(2)) < 1789113641:
        print("unsupported", match.group(1), sep="\n")
    else:
        print("ok", match.group(1), sep="\n")


def bounded_output(arguments, environment, maximum=4096, timeout=5):
    process = subprocess.Popen(arguments, env=environment, stdin=subprocess.DEVNULL,
                               stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    selector = selectors.DefaultSelector()
    selector.register(process.stdout, selectors.EVENT_READ)
    output = bytearray()
    import time
    deadline = time.monotonic() + timeout
    try:
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                fail("command timeout")
            events = selector.select(remaining)
            if not events:
                fail("command timeout")
            chunk = os.read(process.stdout.fileno(), 4096)
            if not chunk:
                break
            output.extend(chunk)
            if len(output) > maximum:
                fail("command output too large")
        if process.wait(timeout=max(0.1, deadline - time.monotonic())) != 0:
            fail("command failed")
        return output.decode("utf-8", "strict")
    except (UnicodeDecodeError, subprocess.TimeoutExpired):
        fail("command output invalid")
    finally:
        selector.close()
        if process.poll() is None:
            process.kill()
            process.wait()


def run_amp_version(home, executable):
    verify_amp(home, executable)
    output = bounded_output([executable, "--version"],
                            {"HOME": home, "PATH": "/usr/bin:/bin"})
    verify_amp_version(output)


def check_amp_remote(home, executable, repository, origin):
    verify_amp(home, executable)
    repository = os.path.realpath(repository)
    if not origin.startswith("https://ampcode.com/git/@") or "\n" in origin:
        fail("invalid Amp origin")
    helper = "!" + shlex.quote(executable) + " git-credential-helper"
    environment = {
        "HOME": home, "PATH": "/usr/bin:/bin", "GIT_CONFIG_NOSYSTEM": "1",
        "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_TERMINAL_PROMPT": "0",
        "GIT_ASKPASS": "/bin/false", "SSH_ASKPASS": "/bin/false",
    }
    bounded_output([
        "/usr/bin/git", "-C", repository,
        "-c", "credential.helper=", "-c", "credential.helper=" + helper,
        "-c", "credential.useHttpPath=false", "-c", "core.hooksPath=/dev/null",
        "ls-remote", "--exit-code", origin, "HEAD",
    ], environment, maximum=4096, timeout=10)
    print("ok")


def archive_entries(archive, version, revision, root, maximum, *required_files):
    if not VERSION.fullmatch(version) or not REVISION.fullmatch(revision):
        fail("invalid archive identity")
    if root != f"clamp-{version}-linux-x86_64" and root != f"clamp-{version}-macos-arm64":
        fail("invalid archive root")
    try:
        maximum = int(maximum)
    except ValueError:
        fail("invalid archive size")
    if not 0 < maximum <= MAX_ARCHIVE:
        fail("invalid archive size")
    required = set(required_files)
    if (not required or len(required) != len(required_files)
            or not MANDATORY.issubset(required)
            or any(not valid_path(path) for path in required)):
        fail("invalid required runtime inventory")
    archive_stat = os.lstat(archive)
    if not stat.S_ISREG(archive_stat.st_mode):
        fail("unsafe runtime archive")
    if archive_stat.st_size > maximum:
        fail("runtime archive too large")
    prefix = root + "/"
    files = set()
    names = set()
    total = 0
    result = []
    try:
        with tarfile.open(archive, "r:gz") as value:
            for member in value.getmembers():
                if member.issym() or member.islnk() or not (member.isdir() or member.isfile()):
                    fail("unsafe runtime archive entry")
                name = member.name.rstrip("/")
                parts = name.split("/")
                if (not parts or parts[0] != root
                        or any(part in (".", "..") or not COMPONENT.fullmatch(part)
                               for part in parts)):
                    fail("unsafe runtime archive path")
                if name in names:
                    fail("duplicate runtime archive entry")
                names.add(name)
                if member.isfile():
                    relative = name[len(prefix):]
                    allowed_library = relative.startswith("lib/") and relative.count("/") == 1
                    allowed_license = relative.startswith("share/licenses/")
                    if relative not in required or (not allowed_library
                       and not allowed_license and relative not in MANDATORY):
                        fail("unexpected runtime archive file")
                    files.add(relative)
                    total += member.size
                result.append(member)
    except (OSError, tarfile.TarError):
        fail("invalid runtime archive")
    if total > MAX_ARCHIVE:
        fail("runtime archive too large")
    if files != required:
        fail("incomplete runtime archive")
    return result


def extract_archive(archive, destination, version, revision, root, maximum,
                    *required_files):
    members = archive_entries(archive, version, revision, root, maximum,
                              *required_files)
    os.mkdir(destination, 0o700)
    with tarfile.open(archive, "r:gz") as value:
        for member in members:
            output = os.path.join(destination, *member.name.rstrip("/").split("/"))
            if member.isdir():
                os.makedirs(output, mode=0o755, exist_ok=True)
                continue
            os.makedirs(os.path.dirname(output), mode=0o755, exist_ok=True)
            source = value.extractfile(member)
            if source is None:
                fail("unreadable runtime archive entry")
            mode = 0o755 if member.name.endswith("/bin/kb") else 0o644
            descriptor = os.open(output, os.O_WRONLY | os.O_CREAT | os.O_EXCL, mode)
            try:
                with os.fdopen(descriptor, "wb", closefd=False) as target:
                    remaining = member.size
                    while remaining:
                        chunk = source.read(min(65536, remaining))
                        if not chunk:
                            fail("short runtime archive entry")
                        target.write(chunk)
                        remaining -= len(chunk)
                    if source.read(1):
                        fail("long runtime archive entry")
                    target.flush()
                os.fchmod(descriptor, mode)
                os.fsync(descriptor)
            finally:
                os.close(descriptor)
    version_path = os.path.join(destination, root, "VERSION")
    revision_path = os.path.join(destination, root, "REVISION")
    if read_regular(version_path, 128) != (version + "\n").encode():
        fail("runtime version marker mismatch")
    if read_regular(revision_path, 128) != (revision + "\n").encode():
        fail("runtime revision marker mismatch")
    for current, directories, _ in os.walk(os.path.join(destination, root), topdown=False):
        for directory in directories:
            descriptor = os.open(os.path.join(current, directory), os.O_RDONLY)
            try:
                os.fsync(descriptor)
            finally:
                os.close(descriptor)
        descriptor = os.open(current, os.O_RDONLY)
        try:
            os.fsync(descriptor)
        finally:
            os.close(descriptor)


def private_directories(home, *paths, create=True):
    home = os.path.realpath(home)
    home_stat = os.lstat(home)
    if (not stat.S_ISDIR(home_stat.st_mode) or home_stat.st_uid != os.geteuid()
            or home_stat.st_mode & 0o022):
        fail("unsafe home directory")
    for path in paths:
        absolute = os.path.abspath(path)
        if os.path.commonpath((home, absolute)) != home:
            fail("private directory escapes home")
        relative = os.path.relpath(absolute, home)
        current = home
        for component in relative.split(os.sep):
            current = os.path.join(current, component)
            try:
                observed = os.lstat(current)
            except FileNotFoundError:
                if not create:
                    fail("private directory missing")
                os.mkdir(current, 0o700)
                observed = os.lstat(current)
            if (not stat.S_ISDIR(observed.st_mode) or observed.st_uid != os.geteuid()
                    or observed.st_mode & 0o022):
                fail("unsafe private directory")


def installed(path, version, revision, digest):
    expected = (("VERSION", version + "\n"), ("REVISION", revision + "\n"),
                (".archive-sha256", digest + "\n"))
    observed = os.lstat(path)
    if (not stat.S_ISDIR(observed.st_mode) or observed.st_uid != os.geteuid()
            or observed.st_mode & 0o022):
        fail("unsafe installation")
    bin_path = os.path.join(path, "bin")
    bin_directory = os.lstat(bin_path)
    if (not stat.S_ISDIR(bin_directory.st_mode)
            or bin_directory.st_uid != os.geteuid()
            or bin_directory.st_mode & 0o022):
        fail("unsafe runtime bin directory")
    for name, value in expected:
        if read_regular(os.path.join(path, name), 128) != value.encode():
            fail("installation marker mismatch")
    executable = os.lstat(os.path.join(path, "bin", "kb"))
    if (not stat.S_ISREG(executable.st_mode) or executable.st_uid != os.geteuid()
            or not executable.st_mode & stat.S_IXUSR or executable.st_mode & 0o022):
        fail("unsafe runtime executable")


def rename_noreplace(source, destination):
    libc = ctypes.CDLL(None, use_errno=True)
    source_bytes = os.fsencode(source)
    destination_bytes = os.fsencode(destination)
    if sys.platform == "linux":
        result = libc.renameat2(-100, source_bytes, -100, destination_bytes, 1)
    elif sys.platform == "darwin":
        result = libc.renamex_np(source_bytes, destination_bytes, 0x00000004)
    else:
        fail("atomic no-replace rename unavailable")
    if result != 0:
        error = ctypes.get_errno()
        if error == errno.EEXIST:
            raise FileExistsError(destination)
        raise OSError(error, os.strerror(error))


def install(payload, destination):
    parent = os.path.dirname(destination)
    version = read_regular(os.path.join(payload, "VERSION"), 128).decode().strip()
    revision = read_regular(os.path.join(payload, "REVISION"), 128).decode().strip()
    digest = read_regular(os.path.join(payload, ".archive-sha256"), 128).decode().strip()
    try:
        rename_noreplace(payload, destination)
    except FileExistsError:
        installed(destination, version, revision, digest)
        return
    descriptor = os.open(parent, os.O_RDONLY)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def cache(source, destination, expected):
    verify_digest(source, expected)
    if os.path.lexists(destination):
        verify_digest(destination, expected)
        return
    parent = os.path.dirname(destination)
    temporary = os.path.join(parent, ".manifest-" + secrets.token_hex(16))
    descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        raw = read_regular(source, MAX_MANIFEST)
        os.write(descriptor, raw)
        os.fsync(descriptor)
    finally:
        os.close(descriptor)
    try:
        os.link(temporary, destination, follow_symlinks=False)
        directory = os.open(parent, os.O_RDONLY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
    finally:
        os.unlink(temporary)


if len(sys.argv) == 4 and sys.argv[1] == "lock":
    parse_lock(sys.argv[2], sys.argv[3])
elif len(sys.argv) == 7 and sys.argv[1] == "manifest":
    parse_manifest(*sys.argv[2:])
elif len(sys.argv) == 4 and sys.argv[1] == "digest":
    verify_digest(sys.argv[2], sys.argv[3])
elif len(sys.argv) == 3 and sys.argv[1] == "source":
    source_repository(sys.argv[2])
elif len(sys.argv) == 4 and sys.argv[1] == "preflight":
    local_preflight(sys.argv[2], sys.argv[3])
elif len(sys.argv) == 4 and sys.argv[1] == "verify-amp":
    verify_amp(sys.argv[2], sys.argv[3])
elif len(sys.argv) == 3 and sys.argv[1] == "amp-version":
    verify_amp_version(sys.argv[2])
elif len(sys.argv) == 4 and sys.argv[1] == "amp-version-exec":
    run_amp_version(sys.argv[2], sys.argv[3])
elif len(sys.argv) == 6 and sys.argv[1] == "amp-ready":
    check_amp_remote(*sys.argv[2:])
elif len(sys.argv) >= 9 and sys.argv[1] == "extract":
    extract_archive(*sys.argv[2:])
elif len(sys.argv) >= 4 and sys.argv[1] == "private-dirs":
    private_directories(*sys.argv[2:])
elif len(sys.argv) >= 4 and sys.argv[1] == "verify-dirs":
    private_directories(*sys.argv[2:], create=False)
elif len(sys.argv) == 6 and sys.argv[1] == "installed":
    installed(*sys.argv[2:])
elif len(sys.argv) == 4 and sys.argv[1] == "install":
    install(*sys.argv[2:])
elif len(sys.argv) == 5 and sys.argv[1] == "cache":
    cache(*sys.argv[2:])
else:
    fail("usage error")
