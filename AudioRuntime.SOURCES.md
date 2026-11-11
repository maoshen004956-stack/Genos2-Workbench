# Bundled audio runtime

This runtime is built locally from the unmodified official FluidSynth 2.6.2
source release. It dynamically links only to macOS system libraries. Homebrew,
an internet connection, and separately installed synthesizer applications are
not required on a user's Mac.

## Components

| Component | Version/source | License |
| --- | --- | --- |
| FluidSynth | `v2.6.2`, https://github.com/FluidSynth/fluidsynth | LGPL 2.1 or later |
| GCEM (compile-time math tables) | commit `012ae73c6d0a2cb09ffe86475f5c6fba3926e200`, https://github.com/kthohr/gcem | Apache 2.0 |
| GeneralUser GS | `2.0.3`, repository commit `684543d5e5efaef08d02be50dcda8d552478fa60`, https://github.com/mrbumpy409/GeneralUser-GS | GeneralUser GS License 2.0 |

GeneralUser GS was created by S. Christian Collins. Its homepage is
https://schristiancollins.com/generaluser.php . The complete original license
and compatibility documentation are included in `Licenses/`; the original
sample provenance statement remains included in that license. The SoundFont
is unmodified. It may be used to create private or commercial music recordings
under the included license.

FluidSynth and GCEM source archives are included in `Sources/`, together with
the build script. No source code changes were made. The script changes only
the output dylib's install ID to `@loader_path/libfluidsynth.3.dylib` and applies
an ad-hoc signature. It builds the C++11 platform abstraction with network,
audio/MIDI drivers, external effects, native DLS and compressed SF3 support
disabled. The application renders standard SF2 audio through the synth API.

## Rebuilding or replacing the dynamic library

Run `prepare-sound-runtime OUTPUT_DIRECTORY` with Xcode command line tools,
CMake and Python 3 installed. If the included source archives and SoundFont
already exist at their expected paths, they are reused and verified against
pinned SHA-256 hashes. The default architecture is the current machine;
`GENOS_AUDIO_ARCH=arm64` selects Apple Silicon explicitly. Deployment target is
macOS 14.0. The app loads FluidSynth dynamically, and its library can be
replaced with an ABI-compatible build. A modified app bundle must be signed
again before macOS will accept its changed contents.

## Download checksums (SHA-256)

- `fluidsynth-2.6.2.tar.gz`: `ca376b42a3c1b186a4c8c248931789a455ac94a89b777394969d678010c2f91f`
- `gcem-012ae73c6d0a2cb09ffe86475f5c6fba3926e200.zip`: `28159274c54e9640354852e172d10d88eb159f4e7f2fea42edbcd20105ed3526`
- `GeneralUser-GS.sf2`: `9575028c7a1f589f5770fccc8cff2734566af40cd26ed836944e9a5152688cfe`

These files belong to their respective authors. Yamaha Genos2 style files are
separate from this runtime and do not contain the keyboard's sampled sounds.
