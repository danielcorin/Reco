# Third-party notices

This notice was audited against the dependency versions resolved on 2026-07-13. It is included in Reco's application bundle. Keep it and `LICENSE` with redistributed binaries.

## FluidAudio 0.15.5

Reco links [FluidAudio 0.15.5](https://github.com/FluidInference/FluidAudio/tree/v0.15.5) at revision `19600a485baa4998812e4654b70d2bab8f2c9949`.

FluidAudio is licensed under the Apache License, Version 2.0. A complete copy of that license is in this distribution's `LICENSE` file. FluidAudio 0.15.5 declares no external Swift Package Manager dependencies, but its source distribution includes the following third-party work.

### Fastcluster — BSD 2-Clause

Copyright:

- Until package version 1.1.23: © 2011 Daniel Müllner, <https://danifold.net>
- All changes from version 1.1.24 on: © Google Inc., <https://www.google.com>

All rights reserved.

Redistribution and use in source and binary forms, with or without modification, are permitted provided that the following conditions are met:

- Redistributions of source code must retain the above copyright notice, this list of conditions and the following disclaimer.
- Redistributions in binary form must reproduce the above copyright notice, this list of conditions and the following disclaimer in the documentation and/or other materials provided with the distribution.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

### VBx-derived code — Apache-2.0

Copyright 2021–2024 BUT Speech@FIT (original [VBx project](https://github.com/BUTSpeechFIT/VBx)).

Licensed under the Apache License, Version 2.0. A complete copy is in this distribution's `LICENSE` file.

## Parakeet TDT 0.6B v3 model

Reco asks FluidAudio to download [FluidInference/parakeet-tdt-0.6b-v3-coreml](https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v3-coreml) at runtime. The model weights are not stored in this repository or bundled with the application.

Attribution: NVIDIA Parakeet TDT 0.6B v3, converted to Core ML by the Fluid Inference Community. The converted model is based on [nvidia/parakeet-tdt-0.6b-v3](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3). Reco downloads the converted artifacts as published and does not modify the weights.

The converted repository metadata and the NVIDIA base model identify the governing license as [Creative Commons Attribution 4.0 International (CC BY 4.0)](https://creativecommons.org/licenses/by/4.0/). CC BY 4.0 permits sharing and adaptation, including commercially, provided appropriate credit and a license link are supplied and changes are indicated.

There is an upstream inconsistency: the converted repository's metadata says `cc-by-4.0`, while a sentence in its model-card License section says “Apache 2.0.” Because the NVIDIA base model is CC BY 4.0 and the converted repository metadata agrees, Reco conservatively treats the model as CC BY 4.0. Distributors who plan to bundle or mirror the weights should seek clarification from Fluid Inference and retain the CC BY attribution unless the rights holder resolves the discrepancy.

FluidAudio 0.15.5 resolves model artifacts from the Hugging Face repository's `main` branch. The model revision is therefore not locked by Reco's `Package.resolved`; distributors that require reproducible or audited artifacts should pin and verify the model separately.
