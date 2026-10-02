# <img width="48" height="48" alt="icon" align="top" src="https://github.com/user-attachments/assets/bb795853-5e5b-4ab9-ab80-78ac52501f8f" /> Ubuntu Core Model Builder

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
- Interfaces with the snapcraft user and key management
- Searches snaps and auto-resolves snap IDs via direct store calls
- Create and register signing keys transparently with snapcraft
- Typed metadata inputs, wizard flow with step validation
- Signs models via snap sign and verifies the output

## Requirements (host tools, used via classic confinement)
- snapd/snap
- snapcraft (install with: snap install snapcraft --classic)
- A graphical pinentry (pinentry-gnome3) recommended for passphrase prompts

## Build for development
Run: flutter pub get
Then: flutter run -d linux

## Build the snap
Run: snapcraft
Then install locally: sudo snap install ./model-builder_0.1.0_amd64.snap --classic --dangerous

## Confinement
This app uses classic confinement because it orchestrates snapcrafts account and keyring management and
needs to utilize model signing via snapd which is not available through the snapd REST API (would mean that
secrets get sent across REST which is not desirable)
