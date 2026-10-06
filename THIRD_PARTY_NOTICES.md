# Third-party notices

Pitot is MIT licensed (see `LICENSE`). It uses the components below.

| Component | Version | License | Where it is used |
|---|---|---|---|
| [Sparkle](https://github.com/sparkle-project/Sparkle) | 2.10.0 | MIT with additional notices for bundled components | Shipped in the app, for updates |
| [jsonc-parser](https://github.com/microsoft/node-jsonc-parser) | 3.3.1 | MIT | Development only: the test oracle in `Tools/oracle`. Not shipped |

## Sparkle

The full license text, with the notices for the parts Sparkle bundles, is in `App/Resources/Licenses/Sparkle-LICENSE.txt`. The app shows the same text in its About window.

## jsonc-parser

jsonc-parser is installed by `npm ci` in `Tools/oracle` and its license comes with the package in `node_modules`. It generates expected outputs for the Core tests. The app does not contain it.
