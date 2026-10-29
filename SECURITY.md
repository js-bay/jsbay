# Security Policy

## Supported versions

Security fixes target the latest published release of JS Bay (`jsbay`) on the default branch. Older tags may not receive backports unless maintainers explicitly say so for a given advisory.

## Reporting a vulnerability

Please **do not** open a public issue for security vulnerabilities.

Prefer [GitHub Security Advisories](https://docs.github.com/en/code-security/security-advisories/guidance-on-reporting-and-writing/privately-reporting-a-security-vulnerability) on this repository (or the public `js-bay` organization repository once it is published). That path keeps the report private until a fix or coordinated disclosure is ready.

If private advisories are not yet enabled on the public repository, contact the maintainers through GitHub (maintainer profiles / organization contact on `js-bay`) and clearly mark the message as a security report. Do not include exploit proof-of-concept details in public channels.

When you report, include:

- Affected version, commit, or release artifact when known
- Backend involved (`quickjs`, `quickjs_ng`, or `jsc`) if relevant
- Steps to reproduce or a minimal test case
- Impact you expect (crash, memory safety, sandbox escape, information disclosure, and so on)

We will acknowledge reports as soon as maintainers can review them and will coordinate disclosure after a fix is available or the risk is otherwise addressed.
