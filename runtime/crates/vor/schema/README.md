# The Debug Adapter Protocol's schema

`debugAdapterProtocol.json` is the protocol's JSON schema from
[microsoft/debug-adapter-protocol](https://github.com/microsoft/debug-adapter-protocol), file
`debugAdapterProtocol.json` at commit `1d5bfe022f9f5a1ddfd8973f558974ec718cf5b4` (sha256
`5dc16664b5cd7a08a769c14dc19be900dc4c3e7d227cd922583780d25480877a` upstream), with one change: the example
path in `ProcessEventBody.name`'s description reads `/srv/myproj/program.js` (upstream: a path under `/home`,
which this repository's commit check refuses). Copyright (c) Microsoft
Corporation. `../examples/gen_types.rs` turns it into `../src/types.rs`, whose doc comments are the schema's
descriptions.

The upstream repository's terms are in `License.txt` (copied unchanged): its code under the MIT License, its
documentation under Creative Commons Attribution; the descriptions carried into `types.rs` are used under the
latter, with this attribution.
