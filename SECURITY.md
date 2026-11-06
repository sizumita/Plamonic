# Security policy

Plamonic reads the text of other apps and updates itself, so reports about either are very welcome.

## Reporting a vulnerability

Report vulnerabilities privately through GitHub: on the repository's **Security** tab, choose **Report a
vulnerability**, or go to <https://github.com/sizumita/Plamonic/security/advisories/new>. Please do not report them in
public issues or pull requests.

A useful report says what an attacker can do and what they need for it, the Plamonic version, and how to reproduce the
problem. Plamonic is a personal project: I will answer as soon as I can, and I ask you to give me reasonable time to
fix the problem before you disclose it.

## Scope

In scope, for example:

- text from other apps that leaves the Mac, or that Plamonic writes where it should not (logs, files other users can
  read);
- reading another app while a password is being typed, or reading a password field at all;
- an update that Plamonic installs although it is not signed with the update key, and anything else in the update
  mechanism or the release workflow that lets someone else ship code to users.

Out of scope: problems in macOS, Sparkle, MLX or the PLaMo 3 Translate models themselves (please report those to their
authors), and attacks that need an already compromised Mac.

## Supported versions

Fixes go to `main`, and from there to the next beta and the next release. Installed copies receive them through the
built-in updater.
