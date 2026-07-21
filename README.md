# Ubuntu Core Model Builder

A Flutter desktop GUI for creating and signing Ubuntu Core model assertions.

<img width="2604" height="1602" alt="Screenshot from 2026-07-21 19-26-00" src="https://github.com/user-attachments/assets/621419f5-cac1-4f79-906f-d5127fbfb0c3" />

<img width="2604" height="1602" alt="Screenshot from 2026-07-21 19-25-49" src="https://github.com/user-attachments/assets/f175f154-e782-4494-bb28-b85220471a48" />

<img width="2604" height="1602" alt="Screenshot from 2026-07-21 19-25-24" src="https://github.com/user-attachments/assets/f5a4022b-4567-45e5-906c-fa30ad9aefd0" />

<img width="2604" height="1602" alt="Screenshot from 2026-07-21 19-27-07" src="https://github.com/user-attachments/assets/79b0c06e-1513-41e6-b408-04c5c31e4d35" />

<img width="2604" height="1602" alt="Screenshot from 2026-07-21 19-27-17" src="https://github.com/user-attachments/assets/e8163303-3a57-4da0-9dda-da7c989aa2d9" />

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
