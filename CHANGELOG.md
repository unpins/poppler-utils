# Changelog

## [Unreleased]

### Changed

- Updated to Poppler 26.06.0.
- The binary is 14 MB instead of 78. Each of the 12 programs carried its own
  copy of the embedded CMap/encoding tree; there is one copy now, shared by all
  of them. Same programs, same output.

### Fixed

- **Windows:** PDFs that use a predefined CMap — the CJK encodings — extract
  their text. `pdftotext` answered `Syntax Error: Couldn't find 'UniJIS-UCS2-H'
  CMap` and produced nothing, on Windows only; Linux and macOS were fine. The
  encoding tables were inside the binary all along, but the Windows build asked
  for them under a path they could never have.
- `unpin install poppler-utils` creates the twelve commands. The released binary
  announced none of them, so the install produced a single `poppler-utils` and
  the README's `pdftotext document.pdf -` did not work; asking for a program by
  name (`--unpin-program=pdftotext`) was ignored there too.
