# Ubuntu Core Model Builder

A Flutter desktop GUI for creating and signing Ubuntu Core model assertions.

## Features
- Auto-detects store account via snapcraft whoami
- Searches snaps and auto-resolves snap IDs via the snapd REST API
- Create and register signing keys transparently
- Typed metadata inputs, wizard flow with step validation
- Signs models via snap sign and verifies the output

## Requirements (host tools, used via classic confinement)
- snap
- snapcraft (install with: snap install snapcraft --classic)
- A graphical pinentry (pinentry-gnome3) recommended for passphrase prompts

## Build for development
Run: flutter pub get
Then: flutter run -d linux

## Build the snap
Run: snapcraft
Then install locally: sudo snap install ./ubuntu-core-model-builder_0.1.0_amd64.snap --classic --dangerous

## Confinement
This app uses classic confinement because it orchestrates other
developer snaps (snapcraft) and the host gpg keyring; nesting
strict-confined snap invocations is not feasible.
