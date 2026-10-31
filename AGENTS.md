# Agent instructions

## Commit message style

Follow the [Go project's commit message conventions](https://go.dev/doc/contribute#commit_messages):

- Start with a short subject in the form `area: summary`, using the primary affected package or project area as the prefix.
- Write the summary in the imperative, starting with a lowercase word and without a trailing period. For example: `docs: clarify lint configuration`.
- Separate the subject from the body with a blank line. Explain what changed and why in complete sentences, using plain text wrapped at about 72 columns.
- Include relevant issue references, such as `Fixes: #123` or `Refs: #123`, when applicable.

## No co-author trailers

Under absolutely no condition may an agent add a `Co-Authored-By` trailer to a commit message. This rule has no exceptions and applies to all commits an agent creates or edits, including amended, rebased, and squashed commits. Do not add such trailers through templates, tooling, or automated attribution.
