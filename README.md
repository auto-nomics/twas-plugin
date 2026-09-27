# twas plugin

FUSION transcriptome-wide association studies (TWAS), migrated from the
legacy `twas_fusion_container` wrapper in nodes-io. One directory = one
plugin family = one git-able unit.

## Layout

- `manifest.toml` — node kind `twas_fusion`: params, ports, the GTEx v8
  panel binding, and image provenance
- `scripts/twas_fusion.sh` — the execution script (referenced relatively
  and inlined by the loader at startup); adapted from the image-baked
  `run_fusion_twas.sh` with identical `FUSION.assoc_test.R` invocation
  tokens
- `Dockerfile` — image build provenance (moved verbatim from
  `containers/fusion/`; build + push still via the pinned registry)
- `FUSION.assoc_test.R`, `utils/plink_utils.R`, `LICENSE` — unmodified
  upstream `gusevlab/fusion_twas` source at the pinned commit
- `run_fusion_twas.sh` — the original image-baked runner (moved
  verbatim; still copied into the image, but the plugin node now drives
  the pipeline through `scripts/twas_fusion.sh`)
- `test_fusion_twas.sh` — image regression (`root=` repointed to this
  directory)

## Provenance

- Image: `ghcr.io/auto-nomics/autonomics/fusion@sha256:91d11747476967b01…9ca0bf`,
  tag `1.0.0`, from `Dockerfile` (base `rocker/r-ver:4.5.1`).
- Upstream: [gusevlab/fusion_twas](https://github.com/gusevlab/fusion_twas)
  at revision `9346c1222bffbb34499fa7a8e23c1b701b55cb05`; the official
  `FUSION.assoc_test.R` runs unmodified; license GPL-3.0-or-later.

## Reference data channel

The LD reference is **not** a node input. One catalog panel,
`wjixiang/catalog-fusion-gtex-v8`, is bound at `/panels/fusion_ref` and
carries the whole FUSION reference:

- `weights/GTexv8.ALL.<Tissue>.tar.gz` — per-tissue GTEx v8 weight
  archives (49 tissues), each extracting to a directory holding the
  `.pos` / `.nofilter.pos` weight manifests and the model files;
- `LDREF/1000G.EUR.<chr>.bim/.bed/...` — the 1000G EUR LD reference for
  chromosomes 1-22.

The only file input is the GWAS sumstats table (SNP, A1, A2, Z).

## Migration parity

The golden test (`crates/container-plugin/tests/twas_migration.rs`)
compares the compiled `ContainerCommandSpec` against the legacy Rust
wrapper (`nodes-io/src/twas_fusion_container.rs`): image, outputs,
panel bundle, resources, and timeout are byte-equal; the script differs
structurally (env-driven instead of a baked image runner) but preserves
the exact `FUSION.assoc_test.R` argument list. Deliberate deltas:

- **Kind rename**: `twas_fusion_container` → `twas_fusion`; the artifact
  prefix follows the kind (`/artifacts/twas_fusion_container` →
  `/artifacts/twas_fusion`). DAG specs referencing the old kind must be
  regenerated.
- **`timeout_secs` / `artifact_prefix` are node-level constants**
  (3600 s, `/artifacts/twas_fusion`) instead of per-instance spec
  params; the plugin DSL does not accept per-node overrides.
- **Command**: the legacy spec executed the baked
  `/opt/fusion/bin/run_fusion_twas.sh` entrypoint. The plugin compiles
  to `sh` + an inlined `scripts/twas_fusion.sh` (materialized at
  `/work/.autonomics/script`), carrying the same pipeline with the same
  tokens. The image ENTRYPOINT is overridden by the runtime
  `--entrypoint`, so the baked copy is inert; it stays in the image for
  provenance and the standalone smoke test.
- **Params travel via env** (`FUSION_*`). The tissue is composed into
  `FUSION_TISSUE_ARCHIVE` by the env template
  (`GTExv8.ALL.{{ tissue }}.tar.gz`), matching the legacy
  `format!` composition byte for byte.
- **Booleans**: the legacy env carried `1`/`0` (`shell_bool`); the
  plugin renders serde_json spellings, so `FUSION_USE_NOFILTER_WEIGHTS`
  is `true`/`false` and the script tests `= "true"`.
- **Enum**: the legacy `force_model` deserialized through a closed
  `FusionModel` enum; the v0 DSL has no enum params, so it is an
  optional string and the script enforces `blup|lasso|top1|enet` in a
  `case` guard before the flag is built. Omitted means FUSION's default
  best-cross-validation-model selection, as before.
- **Validation moved into the script**: the legacy Rust `validate()`
  checks the DSL cannot express are script guards with the legacy
  intent — the tissue charset/escape check (strip the
  `GTExv8.ALL.`/`.tar.gz` envelope, require `[A-Za-z0-9_-]` only) and
  the `force_model` enum guard. The numeric checks map onto manifest
  bounds: `chr` is `int` with `min 1`/`max 22`; `max_impute`,
  `min_r2pred`, and `perm_minp` are `number` with
  `exclusive_min 0`/`max 1` (the legacy `(0, 1]`); `perm` is `int` with
  `min 0`. The failure point moves from registry build to container
  start.
- **Numbers** render with their serde_json spelling (`0.5`, `0.7`,
  `0.05`), identical to the legacy `f64` `Display` rendering.

## Live-test dependencies

`test_fusion_twas.sh` still depends on the autonomics workspace
checkout (`cargo run -p data-catalog -- list` must show the published
`wjixiang/catalog-fusion-gtex-v8` panel), rootless Podman, and the
LDREF fixture at `/mnt/data/twas_fusion/LDREF/1000G.EUR.21.bim`
(overridable via `AUTONOMICS_FUSION_IT_LDREF`). Until the wrapper is
deleted, `crates/node-bundles/nodes-io/tests/container_file_flow.rs`
also imports the legacy `twas_fusion_container` module.
