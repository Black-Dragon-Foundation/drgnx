# huginn's hand corpus

One case per file. `accept/NAME.el` holds data both readers read; `accept/NAME.json` is the dump Emacs gave
(`gen.el`, README.md beside it: one JSON array of the file's top-level data). `refuse/NAME.el` starts with
`;; refuse: KIND` (the `RefusalKind` huginn names); Emacs refuses it too, except kind `CharName` (`\N{NAME}`, the
listed divergence), which Emacs reads. Both readers' tests run them: `runtime/crates/huginn/tests/differential.rs`
and `test/unit/huginn-diff-test.el`. The files are data: formatters skip this folder, and `runtime/fuzz/corpus/huginn_read/`
holds copies as the fuzz target's seeds.

Prefixes: `lread-` from GNU Emacs's `test/src/lread-tests.el`; `tsel-` from tree-sitter-elisp's `test/corpus/`;
`x-` ours.

## Attribution

The `tsel-` cases are taken from the test corpus of tree-sitter-elisp (https://github.com/Wilfred/tree-sitter-elisp),
which is under the MIT licence:

> MIT License
>
> Copyright (c) 2021 Wilfred Hughes
>
> Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated
> documentation files (the "Software"), to deal in the Software without restriction, including without limitation the
> rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to
> permit persons to whom the Software is furnished to do so, subject to the following conditions:
>
> The above copyright notice and this permission notice shall be included in all copies or substantial portions of
> the Software.
>
> THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO
> THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
> AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT,
> TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
> SOFTWARE.

The `lread-` cases are inputs of GNU Emacs's tests (GPL-3.0-or-later, like this repository).
