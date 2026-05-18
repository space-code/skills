# Conventional Commits Specification Reference

## 1. Allowed Types
* `feat`: A new feature for the user (not for build scripts/tools).
* `fix`: A bug fix for the user (not for build scripts/tools).
* `docs`: Documentation only changes.
* `style`: Changes that do not affect the meaning of the code (white-space, formatting, missing semi-colons, etc.).
* `refactor`: A code change that neither fixes a bug nor adds a feature.
* `perf`: A code change that improves performance.
* `test`: Adding missing tests or correcting existing tests.
* `build`: Changes that affect the build system or external dependencies (e.g., CocoaPods, Swift Package Manager, Gradle).
* `ci`: Changes to CI configuration files and scripts (e.g., GitHub Actions, GitLab CI).
* `chore`: Other changes that don't modify src or test files.

## 2. Breaking Changes
If a change breaks backward compatibility, it must be marked:
1. Append `!` after the type/scope in the header.
2. Include `BREAKING CHANGE:` at the very beginning of the footer section, followed by a space and the description of what was broken and how to migrate.