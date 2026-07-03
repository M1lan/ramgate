# Changelog

All notable changes to ramgate. Format follows [Keep a Changelog](https://keepachangelog.com/);
this project adheres to [Semantic Versioning](https://semver.org/).

## [0.1.0] - 2026-07-03

### Added

- Ramgate — two-binary pure-Bash macOS memory tool (v0.1.0)

### Fixed

- **test:** Write vm_stat stub to scratch, untrack generated fixture
- Make just ci pass shellcheck (suppress false positives, fix SC2155/SC2034)

### Documentation

- Compress to technical essentials, drop CONTRIBUTING + ARCHITECTURE, rumdl 190-col

### Changed

- Shfmt-canonicalize all sources; hooks scratch to $TMPDIR

### Miscellaneous

- **license:** Relicense MIT -> AGPL-3.0-or-later
- Pseudonymize PII (contact, copyright, launchd label, fixture paths)
- Strip remaining contact email and stale fixture path
- Drop copyright line, fix fixture path
