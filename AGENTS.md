# Agent guidance

This is a public, brand-neutral repository. Keep code, fixtures, documentation, and examples generic; do not add private infrastructure details, customer names, credentials, or organization-specific branding.

When this repository is checked out beside the maintainer's separate memory repository, read `../memory/MEMORY.md` before making changes. A standalone clone will not contain that sibling; in that case, ignore this conditional instruction. The memory repository is independent and is never published as part of this repository.

Installer scripts must remain standalone and work from their downloaded release asset without repository-local dependencies. Preserve unrelated user configuration, back up files before mutation, keep secrets out of logs and process arguments, and use official upstream installation sources.

Use test-driven development for behavior changes. Do not create a tag or GitHub Release as part of ordinary implementation work; releases are produced only by the tag-triggered workflow.

The primary verification gate is:

```sh
bash tests/run.sh
```

Before handing off a change, also run:

```sh
bash -n ./*.sh tests/*.sh
shellcheck ./*.sh tests/*.sh
git diff --check
```
