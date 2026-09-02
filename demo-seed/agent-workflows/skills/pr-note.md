---
name: pr-note
description: Your single, evolving "Dev agent" comment on the pull request (updated in place).
allowed-tools: [bash]
---
# pr note
Run (from inside the repo checkout): `pr note <pr-index> "<html body>"`
This is the PR analog of `vik status`: it maintains ONE "Dev agent" comment on the pull request and UPDATES it in place on every call (matched by a hidden marker). Use it for ALL of your own PR progress -- "opened, preview at <url>", "reworked per feedback: ...", "merged main" -- rewriting the full current picture each time and always including the preview URL so reviewers can click it. It adds the branded box automatically; pass only body content (HTML: `<p>`, `<ul><li>`, `<strong>`, `<code>`). NEVER use `pr comment` for your own progress -- that posts a separate comment and your report fragments into a pile. Prints `posted`/`updated PR note on #<n>`.
