# Contributing to Ultron

The rules below are binding for every contribution.

## Core rules

1. **GUI only, no CLI.** New capabilities go into the GUI and the module behind it.
   PRs adding command-line entry points will be closed.
2. **Modular or nothing.** Protocol work lives in `src/protocol/<vendor>/` behind the
   `Protocol` vtable; transports in `src/transport/`; GTK in `src/ui/` only; `src/core/`
   stays GTK-free. No cross-layer shortcuts.
3. **Port, don't invent.** Protocol behavior must trace to a working reference
   (`refs/qdl`, `refs/edl` for Qualcomm; see `docs/ROADMAP.md` for each vendor's
   references). Cite the reference file/line in a comment when behavior is subtle.
4. **Atomic commits.** One fix or feature per commit, message style
   `fix(scope): … / feat(scope): … / chore: … / docs: …`. No mixed PRs.
5. **Tests green, always.** `zig build test` must pass before every commit; parser/protocol
   changes come with a test (sim-transport harness preferred over hardware).
6. **No bloat.** No new dependencies, abstractions "for later", config knobs, or CLI flags
   without a demonstrated need. Prefer deleting code over maintaining dead code.
7. **Docs move with code.** Wire-protocol changes update `docs/PROTOCOL.md`; new modules
   follow `docs/ROADMAP.md`; Zig 0.16, `zig fmt` clean.

## Process

- Small PRs against `main`. State clearly what was tested (sim only vs real hardware).
- Only the maintainer (jade) runs hardware validation; say so in the PR rather than
  claiming device-tested behavior you didn't run.
- Anything that could brick a device (erase, partition writes, OTP/UFS commit, unlock)
  must require explicit GUI confirmation and must fail loudly on error — never silently
  truncate or continue past a refused operation.
- License: GPL-3.0-or-later; by contributing you agree your work is licensed under it.
