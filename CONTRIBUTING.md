# Contributing

Keep the app small, native, and read-only. Changes to the optional tiling helpers should remain separate from the menu-bar indicator. Do not introduce network calls, analytics, automatic SIP changes, or silent configuration replacement.

Before proposing a change:

1. Run the Python suite and native build/self-test described in the README.
2. Add a regression test for changed behavior where practical.
3. Update the reference if keys, settings, installation, or file locations change.
4. Report which macOS version, architecture, and yabai/skhd versions you tested.

Do not include window titles, private app lists, home-directory paths, logs, or credentials in issues/fixtures. Sanitize snapshots before sharing. Automated tests must not rearrange a real user's windows or install into their home directory.
