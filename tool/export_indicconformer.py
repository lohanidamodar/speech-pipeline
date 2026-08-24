#!/usr/bin/env python3
"""Export an AI4Bharat IndicConformer checkpoint to sherpa-onnx NeMo-CTC format.

AI4Bharat publishes IndicConformer only as NeMo `.nemo` checkpoints, and the
community sherpa-onnx conversions cover 11 languages — not Nepali or Sanskrit.
So those two need converting once, here.

This is the only Python in the project and it is *offline tooling*: it runs once
per language on a workstation and produces files the Dart runtime then loads on
its own. Nothing in the pipeline itself needs Python.

    pip install "nemo_toolkit[asr]" onnx onnxruntime huggingface_hub
    # NeMo's pins do not agree with a cp314-compatible onnx; realign them:
    pip install "protobuf>=6.31.1,<7" "ml_dtypes>=0.5.0" "onnx==1.19.0" \
                "numpy<2.5,>=2.0"
    python tool/export_indicconformer.py --lang ne
    python tool/export_indicconformer.py --lang sa

Output lands in models/indicconformer-<lang>/{model.onnx,tokens.txt}.

On the version pins: NeMo 2.5 asks for protobuf ~=5.29, but the only onnx with
CPython 3.14 wheels (1.19) carries protobuf 6.31 gencode, and a runtime older
than its gencode is a hard error. Protobuf allows runtime newer than gencode,
so lifting the runtime satisfies both. onnx 1.19 then needs ml_dtypes >= 0.5
for float4_e2m1fn, and that upgrade drags in numpy 2.5, which numba rejects —
hence the numpy ceiling. pip will warn about NeMo's declared pin; it imports
and exports fine regardless.
"""

import argparse
import os
import pathlib

REPOS = {
    "ne": "ai4bharat/indicconformer_stt_ne_hybrid_ctc_rnnt_large",
    "sa": "ai4bharat/indicconformer_stt_sa_hybrid_ctc_rnnt_large",
}


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--lang", choices=sorted(REPOS), required=True)
    ap.add_argument("--out", default="models")
    args = ap.parse_args()

    import nemo.collections.asr as nemo_asr
    import onnx
    from huggingface_hub import snapshot_download

    out_dir = pathlib.Path(args.out) / f"indicconformer-{args.lang}"
    out_dir.mkdir(parents=True, exist_ok=True)

    hf_token = os.environ.get("HF_TOKEN")
    try:
        local = pathlib.Path(snapshot_download(REPOS[args.lang], token=hf_token))
    except Exception as e:
        if "GatedRepo" not in type(e).__name__ and "gated" not in str(e).lower():
            raise
        # 401 and 403 mean different things here and have different fixes:
        # 401 is "no credential", 403 is "credential fine, terms not accepted".
        # A gated repo serves README.md publicly either way, so checking that
        # one file tells you nothing — it is always 200.
        accepted = "403" not in str(e)
        raise SystemExit(
            f"\n{REPOS[args.lang]} is gated.\n\n"
            + (
                "No credential was sent. Create a read token at\n"
                "https://huggingface.co/settings/tokens then\n"
                "  export HF_TOKEN=hf_...\n"
                if accepted
                else "Your token authenticated, but this account has not "
                "accepted the model terms.\n"
                f"Open https://huggingface.co/{REPOS[args.lang]}\n"
                "while signed in as that account and click "
                '"Agree and access repository".\n'
                "Approval is automatic. Do it for --lang ne and --lang sa "
                "separately.\n"
            )
            + "\nThen re-run this command.\n"
        ) from e

    _teach_nemo_ai4bharats_tokenizer_name()
    _ignore_ai4bharats_rnnt_extensions()
    _use_legacy_onnx_exporter()

    checkpoint = next(local.glob("*.nemo"))
    print(f"loading {checkpoint}")

    # Must name the concrete class: the checkpoint's `target` is
    # EncDecHybridRNNTCTCBPEModel, and ASRModel.restore_from does not dispatch
    # to it — it tries to instantiate the abstract base and dies.
    model = nemo_asr.models.EncDecHybridRNNTCTCBPEModel.restore_from(
        str(checkpoint), map_location="cpu", strict=False
    )
    model.eval()

    # Hybrid CTC-RNNT checkpoint; sherpa-onnx supports the CTC branch, which is
    # also the cheaper one to decode.
    model.set_export_config({"decoder_type": "ctc"})

    onnx_path = out_dir / "model.onnx"
    model.export(str(onnx_path))

    # Despite the per-language repo names, every checkpoint carries the full
    # multilingual model: one shared encoder over an aggregate vocabulary of
    # 22 languages x 256 BPE tokens. The CTC head therefore emits 5632 classes
    # spanning every Indic script, and the target language occupies one
    # contiguous slice of that range.
    vocab = list(model.ctc_decoder.vocabulary)
    span = _language_span(model, args.lang, len(vocab))
    if span:
        start, end = span
        print(f"{args.lang} occupies vocab span [{start}, {end}) of {len(vocab)}")

    with open(out_dir / "tokens.txt", "w", encoding="utf-8") as f:
        for i, piece in enumerate(vocab):
            f.write(f"{piece} {i}\n")
        # NeMo CTC places blank last, after the real vocabulary.
        f.write(f"<blk> {len(vocab)}\n")

    # sherpa-onnx reads these from the ONNX metadata rather than a config file.
    # Read them off the checkpoint rather than hardcoding: sherpa derives the
    # output frame count from subsampling_factor, so a wrong value silently
    # truncates the transcript instead of failing.
    meta = {
        "vocab_size": str(len(vocab) + 1),
        "subsampling_factor": str(model.cfg.encoder.subsampling_factor),
        "normalize_type": str(model.cfg.preprocessor.normalize),
        "model_type": "EncDecCTCModelBPE",
        "feat_dim": str(model.cfg.preprocessor.features),
        "model_author": "AI4Bharat",
        "language": args.lang,
        "version": "1",
    }
    print("metadata:", meta)
    _write_metadata(onnx, onnx_path, meta)

    print(f"wrote {onnx_path} and {out_dir / 'tokens.txt'}")
    print(f"vocabulary: {len(vocab)} tokens (+1 blank)")


def _write_metadata(onnx, path, meta):
    """Replace the ONNX metadata block, keeping it idempotent.

    metadata_props is an append-only list, so re-running the export without
    clearing it first leaves duplicate keys behind.
    """
    model = onnx.load(str(path), load_external_data=False)
    keep = [p for p in model.metadata_props if p.key not in meta]
    del model.metadata_props[:]
    model.metadata_props.extend(keep)
    for key, value in meta.items():
        entry = model.metadata_props.add()
        entry.key, entry.value = key, str(value)
    onnx.save(model, str(path))


def _use_legacy_onnx_exporter():
    """Keep torch on the TorchScript ONNX exporter.

    torch 2.13 defaults `torch.onnx.export` to the dynamo path, which takes
    `dynamic_shapes`. NeMo still passes `dynamic_axes`, and torch's automatic
    translation between the two gives up on this graph. The legacy exporter
    accepts `dynamic_axes` as-is and is what sherpa-onnx's own NeMo scripts
    were written against.
    """
    import torch

    original = torch.onnx.export

    def export(*args, **kwargs):
        kwargs.setdefault("dynamo", False)
        return original(*args, **kwargs)

    torch.onnx.export = export


def _ignore_ai4bharats_rnnt_extensions():
    """Let stock NeMo build the RNNT modules it is about to throw away.

    AI4Bharat's fork adds a per-language softmax to the RNNT branch —
    `multisoftmax` on RNNTDecoder, `multilingual`/`language_keys` on RNNTJoint —
    and upstream's constructors reject those kwargs outright.

    The CTC head is affected as well, so this is not confined to the branch we
    throw away. It is still safe: `multisoftmax` changes only how softmax is
    applied in forward(), not any parameter shape, so the weights load into a
    stock module unchanged and the export emits raw logits.

    Loading non-strict means NeMo will not complain if weights fail to land, so
    correctness is not taken on faith here — it is confirmed by transcribing
    real audio after the export.
    """
    from nemo.collections.asr.modules import conv_asr, rnnt

    unsupported = {
        (rnnt, "RNNTDecoder"): ("multisoftmax",),
        (rnnt, "RNNTJoint"): ("multilingual", "language_keys"),
        # The CTC head carries it too, so this is not confined to the branch we
        # discard. Shapes are untouched (feat_in -> num_classes); multisoftmax
        # only changes how softmax is applied in forward(). Dropping it leaves
        # raw logits over the full aggregate vocabulary, which is what sherpa
        # wants since it runs its own argmax.
        (conv_asr, "ConvASRDecoder"): ("multisoftmax",),
    }

    for (module, class_name), drop in unsupported.items():
        cls = getattr(module, class_name, None)
        if cls is None:
            continue

        def wrap(original, drop):
            def __init__(self, *args, **kwargs):
                for key in drop:
                    kwargs.pop(key, None)
                return original(self, *args, **kwargs)

            return __init__

        cls.__init__ = wrap(cls.__init__, drop)


def _teach_nemo_ai4bharats_tokenizer_name():
    """Let stock NeMo load AI4Bharat's aggregate tokenizer.

    AI4Bharat trained these on their own NeMo fork, which spells the aggregate
    tokenizer type `multilingual`; upstream calls the identical thing `agg` and
    dispatches on that exact string, so an unpatched load falls through to the
    monolingual path and dies on a missing `dir` key. The config layout matches
    what `_setup_aggregate_tokenizer` expects — the name is the only mismatch —
    so normalising it is enough, and avoids depending on the fork.
    """
    from omegaconf import open_dict
    from nemo.collections.asr.parts.mixins.mixins import ASRBPEMixin

    original = ASRBPEMixin._setup_tokenizer

    def patched(self, tokenizer_cfg):
        if str(tokenizer_cfg.get("type", "")).lower() == "multilingual":
            with open_dict(tokenizer_cfg):
                tokenizer_cfg.type = "agg"
        return original(self, tokenizer_cfg)

    ASRBPEMixin._setup_tokenizer = patched


def _language_span(model, lang, vocab_size):
    """Where this language's tokens sit inside the aggregate vocabulary.

    NeMo's aggregate tokenizer keeps a per-language offset; the languages are
    equal-sized slices, so the end is just the next offset up.
    """
    offsets = getattr(model.tokenizer, "token_id_offset", None)
    if not offsets or lang not in offsets:
        print("warning: no aggregate offsets found; leaving vocabulary whole")
        return None

    start = offsets[lang]
    later = sorted(o for o in offsets.values() if o > start)
    return start, (later[0] if later else vocab_size)


if __name__ == "__main__":
    main()
