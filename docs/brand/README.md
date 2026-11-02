# FishBrain logo

A fish swimming up, made of two lozenges: a wide body and a small tail below it, with the eye at the top. Each
lozenge is split down the middle into a pale half and a deep half, which reads as two brain hemispheres, or a card
mid-flip.

## Files

| File | Use |
| --- | --- |
| `fishbrain-mark.svg` | The fish alone, in Orange, on a transparent background. |
| `fishbrain-mark-mono.svg` | The fish in one color (`currentColor`), with the eye cut through. For places that need a single color. |
| `fishbrain-icon.svg` | The Counterchange tile: the app icon's design, edge to edge. |
| `fishbrain-lockup.svg` | The fish beside the word "FishBrain", for light backgrounds. |
| `fishbrain-lockup-dark.svg` | The same for dark backgrounds. |
| `*-512.png`, `*-1024.png` | PNG exports of the above (the longer side is 512 or 1024 px). |
| `social-preview.png` | The GitHub social preview, 1280 × 640. |

## Colors

| | Light | Dark |
| --- | --- | --- |
| Pale orange (left half) | `#FFA36B` | `#FFA36B` |
| Deep orange (right half) | `#C2410C` | `#C2410C` |
| "Fish" in the lockup | `#1F1A17` | `#FFFFFF` |
| "Brain" in the lockup | `#C2410C` | `#FFA36B` |
| Social preview background | `#FFF4EC` | |

In the Counterchange tile the halves swap: the deep half of the fish sits on the pale side of the tile and the
pale half on the deep side. The app icon is always Orange. Inside the app the mark follows the accent
(`FishMark`).

## Clear space and size

- Keep at least **twice the eye's diameter** clear on every side of the mark: 56 units of the mark's 320-unit
  height, so about 17.5% of its height.
- The smallest size is **16 px tall**. At that size, and anywhere under 20 px, leave the eye out and keep the
  corners sharp (`FishMark` does this by itself).

## Don't

- Don't color the two halves the same. The split is the mark. (For one color, use the mono file.)
- Don't rotate or flip it. The fish swims up.
- Don't add effects: shadows, glows, outlines or gradients.
- Don't set the word "FishBrain" in another font; use the lockup files.

## Regenerating

The SVGs and PNGs are written by `Scripts/make-brand.swift`. The word is **Outfit Bold**
([SIL Open Font License](https://openfontlicense.org)), converted to outlines so the files don't depend on an
installed font. Download `Outfit-Bold.ttf` from [Outfit-Fonts](https://github.com/Outfitio/Outfit-Fonts) and run:

```sh
swift Scripts/make-brand.swift path/to/Outfit-Bold.ttf
```

The app icon comes from `Scripts/make-icon.swift`.
