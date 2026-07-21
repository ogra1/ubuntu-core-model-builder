# Ubuntu Core Model Builder

A Flutter desktop GUI for creating and signing Ubuntu Core model assertions.

## Screenshots

<img width="2604" height="1602" alt="Screenshot from 2026-07-21 22-20-07" src="https://github.com/user-attachments/assets/dd67181f-e649-4b75-acca-e662784fbfa6" />
<img width="2604" height="1602" alt="Screenshot from 2026-07-21 22-21-04" src="https://github.com/user-attachments/assets/85db2d0c-390e-4d48-a1fb-8a2caef6f396" />
<img width="2604" height="1710" alt="Screenshot from 2026-07-21 22-23-22" src="https://github.com/user-attachments/assets/9c8891ac-0301-42a8-bac7-64accaf0ccbe" />
<img width="2604" height="1710" alt="Screenshot from 2026-07-21 22-23-43" src="https://github.com/user-attachments/assets/d14ae839-a41d-426c-8a6b-0431a46681fc" />
<img width="2604" height="1710" alt="Screenshot from 2026-07-21 22-24-09" src="https://github.com/user-attachments/assets/a91637a2-fd7e-4954-bd20-9d6106925871" />
<img width="2604" height="1710" alt="Screenshot from 2026-07-21 22-24-32" src="https://github.com/user-attachments/assets/236269ac-21f1-4469-974c-c45a8800eb23" />
<img width="2604" height="1710" alt="Screenshot from 2026-07-21 22-24-53" src="https://github.com/user-attachments/assets/6d4f99c2-e733-4014-95ec-11d9a70898a0" />
<img width="2604" height="1710" alt="Screenshot from 2026-07-21 22-25-39" src="https://github.com/user-attachments/assets/e32ea678-d347-4efb-b709-f4f2056cd242" />

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
