# Third-party notices

## bergamot-translator 0.4.9

`src/FastShot/Translate/Engine/translator.js` and `src/FastShot/Translate/Engine/worker/*` are the unmodified files of the
npm package [@browsermt/bergamot-translator](https://www.npmjs.com/package/@browsermt/bergamot-translator) 0.4.9
(source: https://github.com/browsermt/bergamot-translator), the WebAssembly translation engine Firefox Translations is
built on. They are licensed under the Mozilla Public License 2.0: https://mozilla.org/MPL/2.0/. FastShot embeds them in
its exe and runs them in a hidden WebView2 for offline translation.

## Firefox translation models

The translation models are not part of FastShot. On first use of a language direction FastShot downloads them from
Mozilla's Remote Settings (`translations-models`, the same source Firefox uses) and checks them against their SHA-256.
They are made by the Mozilla Translations project (https://github.com/mozilla/translations) and licensed under the
Mozilla Public License 2.0.
