# Documentation Index

This directory contains the authoritative documentation for rofihosted. Each
document below is canonical for its subject; working notes and superseded
fragments have been consolidated into these references.

## Reference set

| Document | Subject | Read this when you want to… |
|----------|---------|------------------------------|
| [ARCHITECTURE.md](ARCHITECTURE.md) | System design | Understand how the server is structured, how a request flows, the module map, and the storage and caching model. |
| [SECURITY.md](SECURITY.md) | Security model | Understand the threat model, authentication, access control, the signup anti-abuse pipeline, API keys, and secrets handling. |
| [OPERATIONS.md](OPERATIONS.md) | Operations | Deploy a change, run the web shell, take a backup, respond to an incident, or run the verification suite. |
| [API.md](API.md) | API reference | Look up an endpoint, its authentication, parameters, and response shape. |
| [RECOVERY.md](RECOVERY.md) | Disaster recovery | Rebuild the platform onto a fresh device from backups. |
| [ENGINEERING-REVIEW.md](ENGINEERING-REVIEW.md) | Improvement backlog | See the prioritized list of known gaps and recommended work. |

## Conventions

- Documentation is written in formal English and kept consistent with the
  deployed system. When behaviour changes, the relevant document is updated in
  the same change.
- Hostnames, paths, and module names are written exactly as they appear in the
  system.
- Code and configuration references use the repository-relative path.

## Related

- [`../README.md`](../README.md) — project overview and entry point.
- [`../CHANGELOG.md`](../CHANGELOG.md) — chronological release history.
- [`../cli/README.md`](../cli/README.md) — the `rh` command-line client.
