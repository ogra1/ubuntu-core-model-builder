# Ubuntu Core Model Builder

A Flutter desktop GUI for creating and signing Ubuntu Core model assertions.

<img width="2773" height="1674" alt="image" src="https://github.com/user-attachments/assets/8da7c134-723f-4269-ba75-9ce78342d95c" />

<img width="2773" height="1674" alt="image" src="https://github.com/user-attachments/assets/dac91233-c568-4945-a644-99745775bfd0" />

<img width="2773" height="1674" alt="image" src="https://github.com/user-attachments/assets/7897e5cd-24cf-44b1-acd9-1b478b89fdf0" />

<img width="2773" height="1674" alt="image" src="https://github.com/user-attachments/assets/b1df51a1-f79e-4a4b-87f1-894ff40256b9" />

<img width="2773" height="1674" alt="image" src="https://github.com/user-attachments/assets/25adcb0e-faa4-44da-beb2-459af9c959a8" />

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
