# Third-party software and models

Amapoani's source is licensed under Apache 2.0. Each dependency and model keeps its upstream license. The beta distributes source, shipped icon files and locally synthesized Kokoro audition clips. The bootstrap and app fetch the runtime libraries and model weights separately.

| Component | License and source |
| --- | --- |
| OpenAI Whisper checkpoints | MIT. [Upstream model and license](https://github.com/openai/whisper#license). The app downloads converted checkpoints from the [whisper.cpp model repository](https://huggingface.co/ggerganov/whisper.cpp). |
| whisper.cpp and ggml | MIT. [Pinned whisper.cpp license](https://github.com/ggml-org/whisper.cpp/blob/v1.9.5/LICENSE). |
| Kokoro-82M weights and voices | Apache 2.0. [Hexgrad model card and training-data credits](https://huggingface.co/hexgrad/Kokoro-82M). The app obtains its model pack from [Sherpa-ONNX](https://github.com/k2-fsa/sherpa-onnx/releases/tag/tts-models). The bundled preview clips were synthesized with Kokoro. |
| Sherpa-ONNX | Apache 2.0. [Pinned license](https://github.com/k2-fsa/sherpa-onnx/blob/v1.13.8/LICENSE). |
| ONNX Runtime | MIT. [License and third-party notices](https://github.com/microsoft/onnxruntime). |
| eSpeak NG | GPL-3.0-or-later. Sherpa-ONNX's pronunciation support and model data may include eSpeak NG components. [Upstream source and license](https://github.com/espeak-ng/espeak-ng). |
| Rust dependencies | See the exact versions in [Cargo.lock](core/Cargo.lock) and the upstream crate licenses. |

Keep third-party notices with any redistributed build. Review the licenses and corresponding-source obligations of the exact runtime and data included before distributing a compiled app bundle.
