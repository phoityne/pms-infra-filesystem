# Revision history for pms-infra-filesystem

## 0.0.3.0 -- 2026-05-15

* Add `pms-file-info` to report line count and byte size.
* Add `pms-grep-file` to search files with POSIX extended regular expressions and return matching line numbers, text, and column offsets.
* Extend `pms-read-file` with optional `startLine` and `endLine` partial-read parameters.
* Add `pms-replace-file` for ordered literal text replacements.
* Fix UTF-8 handling in `pms-grep-file` responses so Japanese text is returned without mojibake.
* Add tests for file info, grep, partial read, replace, Japanese grep output, and related error cases.

## 0.0.2.0 -- 2026-01-31

* Add file system pms-make-dir tools.

## 0.0.1.0 -- 2025-12-31

* First version.
