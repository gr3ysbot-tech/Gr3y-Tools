# Security Policy

## Supported Versions

This repository does not yet publish tagged releases; `main` is the only
actively maintained line. Security fixes land there.

## Reporting a Vulnerability

If you find a security issue in this tool (for example: a way the bootstrap's
hash verification could be bypassed, a privilege-escalation path in the worker
script, or a tweak that silently weakens a security control it shouldn't),
please report it privately rather than opening a public issue.

Email **gr3ysbot@gmail.com** with:

- A description of the issue and its impact
- Steps to reproduce, if applicable
- The commit SHA or version you tested against

You should get an acknowledgment within a few days. This is a small,
single-maintainer project, not a funded security program - there's no bug
bounty, but genuine reports are taken seriously and fixed promptly.

## What This Tool Intentionally Does and Does Not Protect Against

See the "Verify before you run" section of [`README.md`](README.md) for the
current integrity model (commit-pinned SHA256 verification, no code signing
yet) and its known limitations.

Do not report the absence of Authenticode signing as a new finding - it's a
known, already-tracked gap (see `docs/improvement-plan.md` item 4.3), not an
oversight.
