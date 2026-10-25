# Changelog

## [0.3.0](https://github.com/fbuchmeier/kubernetes-videoconverter/compare/v0.2.0...v0.3.0) (2026-10-25)


### Features

* add network-aware job start delays ([593d98d](https://github.com/fbuchmeier/kubernetes-videoconverter/commit/593d98d80c06cb5d128f07f85b6be03c7daf8fce))
* added dry-run flag ([254cdc1](https://github.com/fbuchmeier/kubernetes-videoconverter/commit/254cdc18d80aea24deb0bb68c4095579f6889862))
* expose network-aware job delay settings in Helm chart ([6bd6484](https://github.com/fbuchmeier/kubernetes-videoconverter/commit/6bd648431fa4cbc160631efc2c9cdc4d6b1c8503))
* support job resource requests and limits ([3574aca](https://github.com/fbuchmeier/kubernetes-videoconverter/commit/3574aca85c2429742645d3a18757b67a17879320))
* version bump ([4e15d49](https://github.com/fbuchmeier/kubernetes-videoconverter/commit/4e15d4936bcea2bd2ca0d45928fc73f511d06c2d))


### Bug Fixes

* derive .hb.mkv output path from the source stem ([8cd270c](https://github.com/fbuchmeier/kubernetes-videoconverter/commit/8cd270c4c78027ce2215bf5178863841bde5a0b6))
* load e2e images into kind and add stage checkpoints ([d714074](https://github.com/fbuchmeier/kubernetes-videoconverter/commit/d7140740a9b6c9786f2335449cb4f9d9259182a2))
* load e2e images into kind without the hanging stdin stream ([3fbb281](https://github.com/fbuchmeier/kubernetes-videoconverter/commit/3fbb2810f8cc90a05d724b836cff58f563f76c1a))
* make e2e/run.sh safe to run repeatedly ([fa24180](https://github.com/fbuchmeier/kubernetes-videoconverter/commit/fa24180224653f546d7e4e0a212cf82c2a120bb5))
* mark e2e/run.sh as executable ([e4edaad](https://github.com/fbuchmeier/kubernetes-videoconverter/commit/e4edaad84b76e8c8b8586f784af5957f385bf369))

## [0.2.0](https://github.com/fbuchmeier/kubernetes-videoconverter/compare/v0.1.0...v0.2.0) (2026-10-19)


### Features

* initial commit ([4baf214](https://github.com/fbuchmeier/kubernetes-videoconverter/commit/4baf21403a1fd91e17bf3037e3467594df898980))
