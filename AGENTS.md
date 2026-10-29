# Agent and contributor rules

## Privacy

This source tree is intended for public release. Never put these in tracked files, file names, identifiers, comments, docs, CI config, tests, examples, or commit/PR text:

- private downstream product names, internal codenames, or partner project labels;
- host-platform private namespaces: proprietary global objects, partner SDK entry points, or host-app runtime APIs that identify a specific product;
- attribution comments that name comparison or inspiration projects or their private test suites;
- private network addresses and hostnames (VPN/mesh, LAN, `*.local`);
- personal data: real names, emails, local paths such as `/Users/<name>/…`;
- device serials, UDIDs, signing profiles, tokens, keys.

Describe host integration with neutral, jsbay-owned names only. Use `jsbay_*` for C symbols, `com.example.*` for package ids, and generic placeholders in docs and samples. Do not copy a host product's global object names, bridge APIs, or private package prefixes into this tree.

Run `zig build tool -- privacy` (add `--commits origin/main..HEAD` for commit messages) before every commit; CI runs it too. Fix a failure by removing the content, never by weakening the script. Do not write a forbidden word in plain text anywhere, including in "removed X" notes; describe it by category. Personal names, private product labels, lab device ids, and private network markers go in `.git/info/privacy-denylist` (not committed), or in a path named by `PRIVACY_EXTRA_FILE`. The committed scanner keeps only public-tree hygiene (local path prefixes, private IPv4 ranges) and comparison-engine product names.

Renaming a public symbol is a breaking change: say so in the PR. Rewriting git history needs owner approval.

## Comments and prose

- Apply these rules to all first-party source, SDKs, tests, build files, scripts, and comments added by vendor patches. Preserve upstream license notices, generated files, and tool directives; update generated comments at their source.
- Write all first-party prose in English: comments, docs, commit and PR text, CI messages, and user-facing strings. Do not leave non-English natural-language text in tracked first-party files. Unicode bytes in tests or fixtures are allowed when they exercise encoding; prefer non-CJK samples for those cases.
- Keep samples, tests, and docs on the public jsbay C ABI and SDK surfaces. Do not copy host-app global namespaces, host-bridge style APIs, or private product binding shapes into first-party code.
- Describe current behavior, ownership, constraints, and reasons. Do not record implementation history, review rounds, development phases, removed approaches, or machine-specific observations. Git records change history.
- Do not put dates, timestamps, personal information, local machine paths, device identifiers, or private network details in comments. Use neutral placeholders in examples. Keep version numbers only when they define a current compatibility requirement.
- Write each prose paragraph on one physical line. Do not wrap comments, Markdown, commit messages, PR/issue text, or work logs at a fixed column width. Let the editor or rendering platform wrap them visually.
- Separate independent paragraphs with a blank comment line. Preserve meaningful line breaks in lists, tables, code examples, command output, license notices, and formatter/linter directives. Keep each list item's prose together; preserve indentation in nested structures.
- Runtime log messages should describe the event and useful context. Do not embed manual line wrapping in a message; preserve line breaks only for structured or inherently multiline content such as stack traces. Do not change required log fields or protocol formats to apply this prose rule.
- Review comment edits separately from code edits. Verify that executable tokens and tool directives are unchanged, then run the privacy check and the format checks for affected languages.
