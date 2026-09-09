# Getting started

Clamp separates its public implementation from your private knowledge. You
download `kb` from this public repository, then use it to create a small private
repository containing Markdown, configuration, an Amp skill, and a runtime
lock. Do not copy the Clamp source tree into the private repository.

The supported release target is x86_64 Linux with glibc 2.36 or newer. The
archive contains the non-system libraries required by `kb`; OCaml, opam, libpq,
and libcurl are not runtime prerequisites.

To compile Clamp from source or add another target such as macOS, see
[Building Clamp](./building.md).

## Download the pinned runtime

```bash
version=0.1.4
archive="clamp-${version}-linux-x86_64.tar.gz"
base="https://github.com/gvrooyen/clamp/releases/download/v${version}"

mkdir -p "$HOME/.local/share/clamp/downloads"
cd "$HOME/.local/share/clamp/downloads"
curl -fLO "$base/$archive" && \
  curl -fLO "$base/$archive.sha256" && \
  sha256sum --check "$archive.sha256" && \
  tar -xzf "$archive" && \
  ./clamp-${version}-linux-x86_64/bin/kb --version
```

Expected v0.1.4 SHA-256:
`f4b9cfbb6736def71eb5c54acae955cfe19b1e03cf519aa4616cad5dd6a53841`.
Stop if verification fails.

Set a shell variable for the extracted runtime:

```bash
runtime="$HOME/.local/share/clamp/downloads/clamp-0.1.4-linux-x86_64"
```

## Amp-hosted private repository

This is the complete Clamp workflow. The repository is private, Amp can clone
it into fresh orbs, and the generated skill can use Amp's authenticated Git
path when synchronizing and publishing.

Run the bootstrap commands below in a compatible Linux environment with
authenticated access to the Amp repository–for example, your local machine
with the Amp CLI signed in. These commands seed shared remote state, so confirm
that the new repository is empty before pushing.

### 1. Create an empty private Amp project

In Amp:

1. Open **Projects**, choose **New Project**, then **Start From Scratch**.
2. Give the project a name such as `private-clamp`.
3. Select your personal account as owner so the project is private.
4. Leave **Public Read-Only Code Access** disabled.

The CLI equivalent is:

```bash
amp projects create --amp-hosted --personal --name private-clamp
```

Copy the repository clone URL from the project page. Its normalized identity,
without `https://` or a trailing `.git`, is the value for
`source_repository`. For example, an HTTPS URL beginning
`https://ampcode.com/OWNER/private-clamp` uses
`ampcode.com/OWNER/private-clamp`. Preserve the path exactly, including any
literal `@` character.

### 2. Initialize in a separate directory

`kb init` requires a target path that does not exist. Do not run it over a
clone or any repository with files or history.

Use the latest stable release:

```bash
"$runtime/bin/kb" init \
  --repo "$HOME/private-clamp-bootstrap" \
  --source-repository ampcode.com/OWNER/private-clamp \
  --latest \
  --json
```

The shortcut downloads and verifies the latest stable public package, derives
the exact runtime pin, and uses the selected package's templates. Use
`--release 0.1.4` instead of `--latest` when you need to select that exact
release. The four explicit `--runtime-*` options remain available for offline
or controlled initialization.

Initialization creates one clean commit on `main`. It does not contact the
remote.

### 3. Set your authority identifier

The default human authority is `human:owner`. To use another stable identifier,
add it at the top level of `clamp.yaml` before the first push:

```yaml
human_authority: human:your-identifier
```

Then amend the initial commit. `human_authority` is provenance, not a Git author
name.

```bash
cd "$HOME/private-clamp-bootstrap"
git config user.name "YOUR_GIT_NAME"
git config user.email "YOUR_GIT_EMAIL"
git add clamp.yaml
git commit --amend --no-edit
```

If you keep the default and made no edit, skip the amend.

### 4. Seed the empty Amp repository

Use the exact clone URL shown by Amp:

```bash
cd "$HOME/private-clamp-bootstrap"
amp_clone_url="PASTE_THE_EXACT_AMP_CLONE_URL"
git remote add origin "$amp_clone_url"
git push -u origin main
```

This ordinary first push is appropriate only when the remote is genuinely
empty. If it already has a commit, clone it and import the generated files
without replacing `.git`, discarding history, or force-pushing.

### 5. Configure Git identity and secrets

Check the Amp project's **Git Identity** setting. In the orb clone, `kb publish`
also requires repository-local `user.name` and `user.email`; initialization's
generic commit identity does not configure them permanently.

In the Amp project's **Secrets & Env Vars**, add:

| Name | Purpose |
| --- | --- |
| `KB_DATABASE_URL` | Neon pooled URL for retrieval |
| `KB_DATABASE_DIRECT_URL` | Neon direct URL for migrations and sync |
| `OPENROUTER_API_KEY` | Credit-limited embedding key |

See [Operations](./operations.md) for TLS requirements and service setup.

### 6. Start an orb

Start a new thread in the project. Amp runs the generated `.agents/setup` when
building the project snapshot and `.agents/resume` after a wake. Setup verifies
the four-field runtime lock, installs that exact public release outside the
repository, restores empty taxonomy directories, and prepares disposable local
Postgres. It does not migrate or synchronize production services.

Ask the agent to run:

```bash
kb validate --repo /home/user/workspace/repo --json
```

Production migration, synchronization, or publication remains a separate,
explicitly authorized operation.

## Private Git repository on local Linux

This path supports local knowledge editing, task management, and validation
with Amp on your own x86_64 Linux machine. It does not provide the complete v1
publication path: `kb publish` accepts the validated Amp HTTPS credential flow,
not arbitrary private GitHub HTTPS or SSH origins. The `local.test/` remote
form in the test suite is a fixture convention, not production support.

### 1. Install Amp and `kb`

Install Amp using its current Linux instructions:

```bash
curl -fsSL https://ampcode.com/install.sh | bash
```

Keep the extracted Clamp release directory intact and link its executable:

```bash
mkdir -p "$HOME/.local/share/clamp/kb" "$HOME/.local/bin"
mv "$runtime" \
  "$HOME/.local/share/clamp/kb/75b5c6a9ec63374b5953b8035768388055448738"
ln -sfn \
  "$HOME/.local/share/clamp/kb/75b5c6a9ec63374b5953b8035768388055448738/bin/kb" \
  "$HOME/.local/bin/kb"
export PATH="$HOME/.local/bin:$PATH"
kb --version
```

Keep the release's `bin/` and `lib/` directories together. The binary resolves
its bundled libraries relative to its own location.

### 2. Create and seed the private repository

Create an empty private repository on your Git host, then initialize Clamp in a
new local directory. For a private GitHub repository:

```bash
kb init \
  --repo "$HOME/private-clamp" \
  --source-repository github.com/OWNER/private-clamp \
  --release 0.1.4 \
  --json

cd "$HOME/private-clamp"
git remote add origin git@github.com:OWNER/private-clamp.git
git push -u origin main
```

Use your normal Git credentials for that first push and later manual pushes.
Never force-push. If the remote is not empty, import the generated files into a
normal clone instead of replacing its history.

### 3. Adapt the generated instructions and run Amp

The generated instructions target Amp orbs. Before starting Amp locally:

1. Update `AGENTS.md` and
   `.agents/skills/managing-clamp-knowledge/SKILL.md` to use the absolute path
   of your local repository instead of `/home/user/workspace/repo`.
2. Replace their orb setup and automatic sync/publication instructions with
   local validation, knowledge/task commands, and reviewed manual Git commits
   and pushes.
3. Keep the assertion, confirmation, task-closure, and verification rules
   unchanged.

Review, commit, and push those local-workflow adaptations before storing
knowledge so every checkout receives the same instructions.

Do not use the generated `.agents/setup` and `.agents/resume` as
general-purpose local installers; they target Amp orbs and Debian's managed
PostgreSQL layout.

Now start Amp:

```bash
cd "$HOME/private-clamp"
amp
```

Without Neon and OpenRouter, use the local commands:

```bash
kb validate --json
kb task list --json
kb todo --json
rg -n "search terms" knowledge
```

Use `kb add`, `kb edit`, and the task commands to mutate knowledge. Review and
commit the resulting managed files with ordinary Git, then push them manually.
Do not run `kb database migrate`, `kb sync`, or `kb publish` unless you have
separately configured and verified a supported environment.

## Next steps

- Read [Using Clamp with Amp](./amp.md) before asking an agent to write or
  publish knowledge.
- Read [Knowledge format and configuration](./knowledge-format.md) before
  changing `clamp.yaml` by hand.
- Read [Operations](./operations.md) before connecting Neon or OpenRouter.
