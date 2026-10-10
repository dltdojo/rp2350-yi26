# Work in progress: the proof, in pieces

These modules are the proof of exp228's kernel while it is being written. They
build as their own Lake package against `lean/` (see `lakefile.toml`; the
`path` there is the author's checkout and is rewritten when this is folded
into `proof/Script.lean`). `Dev/Spec.lean` is `proof/Script.lean` up to
`end Exp228`, without `import Sha256`.

Nothing here is a claim yet: modules still carry `sorry`, and this directory
goes away when the proof is merged into `proof/Script.lean`.
