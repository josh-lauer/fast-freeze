# Changelog

## 0.2.0 (2026-11-25)

- `trust_frozen:` now defaults to `false`. A container found already frozen is walked like any other, so one that was frozen by hand with unfrozen things in it is frozen through. Pass `trust_frozen: true` for the behaviour of 0.1.0, where a frozen container is skipped.

## 0.1.0 (2026-11-25)

- `Fast::Freeze.deep_freeze(value, trust_frozen: true, recurse_into_structs: false)`.
