#!/bin/sh
set -eu
cd /opt/fusion

# Adapted from the image-baked run_fusion_twas.sh: same pipeline, same
# tokens, but every parameter arrives through the FUSION_* env channel
# and the legacy Rust validate() checks live here as fail-closed guards.
weights_root=/panels/fusion_ref/weights
ldref_root=/panels/fusion_ref/LDREF
archive_name=${FUSION_TISSUE_ARCHIVE:?FUSION_TISSUE_ARCHIVE is required}
weights_archive="${weights_root}/${archive_name}"

# The legacy wrapper rejected tissue values that could escape the weights
# directory (empty, control characters, whitespace, slash, backslash, dot).
# The plugin DSL has no string-pattern validation, so the same check runs
# here: strip the known archive prefix and suffix and require a plain
# catalog tissue directory name such as Whole_Blood.
tissue=${archive_name#GTExv8.ALL.}
tissue=${tissue%.tar.gz}
case ${tissue} in
    "" | *[!A-Za-z0-9_-]*)
        echo "tissue must be a catalog tissue directory name such as Whole_Blood, got archive: ${archive_name}" >&2
        exit 1
        ;;
esac

# Legacy shell_bool rendered 1/0; the plugin env channel renders the
# serde_json spellings, so the test is against "true".
pos_suffix=$([ "${FUSION_USE_NOFILTER_WEIGHTS:-false}" = "true" ] && printf nofilter.pos || printf pos)

[ -f "${AUTONOMICS_INPUT0:?AUTONOMICS_INPUT0 is required}" ]
[ -f "${weights_archive}" ] || {
    echo "FUSION GTEx weight archive is missing: ${archive_name}" >&2
    exit 1
}
[ -f "${ldref_root}/1000G.EUR.${FUSION_CHR}.bim" ] || {
    echo "FUSION LDREF chromosome ${FUSION_CHR} is missing" >&2
    exit 1
}

mkdir -p /work/weights
tar --no-same-owner -xzf "${weights_archive}" -C /work/weights
tissue_dir=$(tar -tzf "${weights_archive}" | sed -n '/\/$/s/\/$//p' | head -1)
weights_pos="/work/weights/${tissue_dir}.${pos_suffix}"
[ -f "${weights_pos}" ] || {
    echo "FUSION weight manifest is missing: ${tissue_dir}.${pos_suffix}" >&2
    exit 1
}

model_args=
if [ -n "${FUSION_FORCE_MODEL:-}" ]; then
    # The legacy spec deserialized force_model through a closed enum; the
    # manifest types it as a plain optional string, so the same values are
    # enforced here before the flag is ever built.
    case ${FUSION_FORCE_MODEL} in
        blup | lasso | top1 | enet) ;;
        *)
            echo "force_model must be one of blup, lasso, top1, enet, got: ${FUSION_FORCE_MODEL}" >&2
            exit 1
            ;;
    esac
    model_args="--force_model ${FUSION_FORCE_MODEL}"
fi
perm_args=
if [ "${FUSION_PERM:-0}" -gt 0 ]; then
    perm_args="--perm ${FUSION_PERM} --perm_minp ${FUSION_PERM_MINP}"
fi

out_prefix=/work/twas_fusion
: > "${AUTONOMICS_OUTPUT2}"
Rscript /opt/fusion/FUSION.assoc_test.R \
    --sumstats "${AUTONOMICS_INPUT0}" \
    --weights "${weights_pos}" \
    --weights_dir /work/weights \
    --ref_ld_chr "${ldref_root}/1000G.EUR." \
    --chr "${FUSION_CHR}" \
    --max_impute "${FUSION_MAX_IMPUTE}" \
    --min_r2pred "${FUSION_MIN_R2PRED}" \
    ${model_args} \
    ${perm_args} \
    --out "${out_prefix}" \
    > "${AUTONOMICS_OUTPUT1}" 2>&1

cp "${out_prefix}" "${AUTONOMICS_OUTPUT0}"
if [ -f "${out_prefix}.MHC" ]; then
    cp "${out_prefix}.MHC" "${AUTONOMICS_OUTPUT2}"
fi

{
    echo "FUSION TWAS completed."
    echo "tissue_archive: ${archive_name}"
    echo "weight_manifest: ${tissue_dir}.${pos_suffix}"
    echo "chromosome: ${FUSION_CHR}"
} >> "${AUTONOMICS_OUTPUT1}"
