# Security policy

## Supported versions

Only the latest release gets security fixes. Please update to the latest version before you report a problem.

## How to report a vulnerability

Use GitHub's private reporting form:
**https://github.com/voiceflow-gallagan/pitot/security/advisories/new**

Please do not open a public issue or discussion for a security problem. There is no email address for reports. The private form is the only channel.

Please include:
- the Pitot version (shown in About) and your macOS version,
- the steps that show the problem, as short as you can make them,
- what you expected, and what happened instead,
- whether any of your files were changed or exposed.

## What to expect

The maintainers aim to reply within 7 days. Pitot is a small project, so a fix date depends on how serious the problem is. We will tell you what we decide and credit you in the advisory if you want. There is no bug bounty.

## What is in scope

- Pitot writing to a file it should not write to, including a symbolic link in a project folder that points outside the project.
- Pitot damaging a settings file, for example by writing a value that makes Claude Code ignore the whole file.
- Anything that reads, shows, logs or stores API keys or tokens. Pitot must never do this.
- Weaknesses in the update feed, the update signatures or the release files.
- Mistakes in the release scripts that could ship an unsigned or wrongly signed build.

## What is out of scope

- Problems in Claude Code itself. Please report those to Anthropic.
- Problems in the Sparkle updater itself. Please report those to the Sparkle project. We would still like to hear about them.
- Attacks that need someone who already controls your macOS user account.
- Social engineering, and issues in a fork or a build you made yourself.

## Check your download

Each release page shows the SHA-256 of the DMG. Compare it with the file you downloaded:

```bash
shasum -a 256 Pitot-X.Y.Z.dmg
```

After you copy Pitot to Applications, check the signature and Apple's notarization:

```bash
codesign --verify --deep --strict --verbose=2 /Applications/Pitot.app
spctl --assess --type execute -vv /Applications/Pitot.app
```

`spctl` must say `source=Notarized Developer ID`. The Developer ID team is `3442G4TNXR`. Updates are signed with an Ed25519 key. Its public half is in the app's `Info.plist` as `SUPublicEDKey`:

```
1UnHf4Lh+cfgwsecEV42lt7DnlZIy//dVNYvX6YrkJM=
```

## What Pitot promises

- Every change shows a diff first, is backed up before it is written, and can be undone.
- Files are written in one step, so a crash cannot leave half a file.
- A project file that is a link pointing outside its project is refused, and nothing is written.
- A `null` is never written to a settings file, because one `null` can make Claude Code skip the whole file.
- Files larger than 8 MiB are refused.
- Pitot does not read your API keys, and tests never touch your real files.
- Updates are only checked after you turn that on in About. A tampered or unsigned update is rejected.

## If the update key is ever exposed

We will say so in a security advisory on this repository. We will then ship a release signed with the same Developer ID and a new update key. Install that release by hand from the releases page.

## Safe harbor

If you act in good faith and follow this policy, we will not take legal action against you for your research.
