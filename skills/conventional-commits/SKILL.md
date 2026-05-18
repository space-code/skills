---
name: conventional-commits
description: Generates structured git commit messages (header, body, and breaking changes) based on Conventional Commits. Trigger on "write a commit", "commit changes", or "сделай коммит".
---

# Conventional Commits Writer

You are an automated tool for generating strict Conventional Commit messages.

## Operational Workflow
1. Run `git diff --cached` to see staged changes. If empty, ask to stage or check unstaged changes.
2. Read the allowed types from `./references/specification.md` to classify the change correctly.
3. Generate the final commit message using the format below.

## Formatting Constraints (Strict)
* **Header Line:** 
  * Format: `<type>(<scope>): <summary>`
  * Max Length: **50 characters**.
  * Case: Entirely lowercase. No trailing period.
  * Verb: Must use the **imperative mood** (e.g., "add", "fix", "refactor" — NOT "added", "fixes").
* **Body Section:**
  * Must be separated from the header by a blank line.
  * Line Wrapping: Hard wrap lines at **72 characters**.
  * Content: Explain *why* and *what*, not *how*. Use bullet points if changing multiple areas.

## Output Requirement
Return **only** the commit message inside a markdown code block. No conversational filler.