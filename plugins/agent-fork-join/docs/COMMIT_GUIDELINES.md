# Commit Message Guidelines

This plugin follows the [Angular Commit Message Guidelines](https://github.com/angular/angular/blob/main/contributing-docs/commit-message-guidelines.md).

## Commit Types

| Type       | Description                                                   |
| ---------- | ------------------------------------------------------------- |
| `build`    | Changes that affect the build system or external dependencies |
| `ci`       | Changes to CI configuration files and scripts                 |
| `docs`     | Documentation only changes                                    |
| `feat`     | A new feature                                                 |
| `fix`      | A bug fix                                                     |
| `perf`     | A code change that improves performance                       |
| `refactor` | A code change that neither fixes a bug nor adds a feature     |
| `test`     | Adding missing tests or correcting existing tests             |

## Branch Naming Convention

Branch names MUST start with one of the commit types followed by a forward slash:

```
<type>/<short-description>
```

**Examples:**

- `feat/add-user-authentication`
- `fix/resolve-null-pointer`
- `refactor/simplify-api-handlers`
- `docs/update-readme`
- `test/add-unit-tests-for-auth`
- `perf/optimize-database-queries`
- `build/update-dependencies`
- `ci/add-github-actions`

## Commit Message Format

```
<type>(<scope>): <short summary>

<body>

<footer>
```

### Header

- **type**: One of the types from the table above (required)
- **scope**: The area of the codebase affected (optional)
- **summary**: Brief description in imperative mood (required)

**Rules for summary:**

- Use imperative, present tense: "change" not "changed" or "changes"
- Don't capitalize the first letter
- No period at the end
- Maximum 100 characters

### Body

- Use imperative, present tense
- Explain WHY the change was made, not just what changed
- Minimum 20 characters for non-docs changes

### Footer

- **Breaking Changes**: Start with `BREAKING CHANGE:`
- **Deprecations**: Start with `DEPRECATED:`
- **Issue References**: Use `Fixes #123` or `Closes #123`

## Examples

### Feature

```
feat(auth): add OAuth2 login support

Implement OAuth2 authentication flow to support Google and GitHub
login providers. This allows users to sign in without creating
a password-based account.

Closes #456
```

### Bug Fix

```
fix(api): resolve null pointer in user handler

Check for null user object before accessing properties to prevent
crashes when handling requests for deleted users.

Fixes #789
```

### Refactor

```
refactor(db): simplify connection pooling logic

Extract connection pool configuration into a separate module
to improve testability and reduce code duplication.
```

### Performance

```
perf(search): add database index for faster queries

Add composite index on user_id and created_at columns to
improve search query performance by 10x.
```

## Type Selection Guide

Use this guide to choose the appropriate commit type:

| If you are...                                   | Use type   |
| ----------------------------------------------- | ---------- |
| Adding new functionality                        | `feat`     |
| Fixing a bug                                    | `fix`      |
| Improving performance without changing behavior | `perf`     |
| Restructuring code without changing behavior    | `refactor` |
| Adding or updating tests                        | `test`     |
| Updating documentation                          | `docs`     |
| Updating build scripts or dependencies          | `build`    |
| Updating CI/CD configuration                    | `ci`       |
