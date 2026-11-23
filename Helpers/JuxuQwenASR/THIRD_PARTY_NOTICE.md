# Third-party code in juxu-qwen-asr

- `Sources/juxu-qwen-asr/Vendor/` is derived from [soniqo/speech-swift](https://github.com/soniqo/speech-swift)
  at commit `15eda930df3d6cad07a0cd25e8d22dfdd9a040c3`, Apache License 2.0 (`LICENSE.speech-swift`).
  Changes: module imports removed, forced-aligner protocol removed, resampling removed,
  audio-encoder block attention mask removed to match the official transformers encoder.
  `build_mlx_metallib.sh` is derived from the same repository (paths and deployment target changed).
- [ml-explore/mlx-swift](https://github.com/ml-explore/mlx-swift) 0.31.6, MIT License, linked as a dependency.
- Model weights are not distributed with the app. They are downloaded on demand from
  `Qwen/Qwen3-ASR-0.6B` at revision `5eb144179a02acc5e5ba31e748d22b0cf3e303b0`, Apache License 2.0.
