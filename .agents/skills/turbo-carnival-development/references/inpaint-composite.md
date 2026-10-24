# The inpaint composite: masks, crops and blends

The base image comes from the pony checkpoint; **flux1-dev is loaded only to repair the face and the
hands**. Each repair is the same five-stage chain, instantiated twice -- once per region. Tuning either
one means knowing that chain, because the knobs live at four different stages and only one of them is
the obvious `denoise`.

## The chain, per pass

```
CLIPSeg (prompt: head | hand, threshold)
  -> GrowMaskWithBlur (expand, blur_radius)
    -> Bounded Image Crop with Mask (padding_*)
      -> SetLatentNoiseMask -> SamplerCustomAdvanced (steps, denoise)
        -> Bounded Image Blend (feathering, blend_factor)   -> back into the accumulated image
```

The hand pass runs **after** the face pass and composites onto its result.

## What each knob actually does

Read from the node source (`was-ns/WAS_Node_Suite.py`) -- the names are not self-explanatory:

| knob | node class | mechanism |
|---|---|---|
| `threshold` | `ApplyCLIPSeg+` | CLIPSeg score cutoff. The same node also carries `dilate` / `blur` / `smooth`, which shape the raw mask before anything else sees it. |
| `expand`, `blur_radius` | `GrowMaskWithBlur` | Grows the mask outward and softens its edge -- this moves the mask's **bounding box**, and therefore moves the crop. |
| `padding_*` | `Bounded Image Crop with Mask` | Takes the mask's own bounding box and **adds padding around it**, clamped to the image. It sets both how much surrounding context the sampler sees and how much room the blend has to feather into. |
| `denoise` | `BasicScheduler` -> `SamplerCustomAdvanced` | How far the sampler departs from the crop it was handed. |
| `feathering` | `Bounded Image Blend` | Builds a white core **inset by `feathering` from each edge**, surrounds it with a `feathering`-wide zero border, then Gaussian-blurs at radius `feathering`. The transition ramp is therefore roughly `feathering` to `2 x feathering` px wide, running inward from the crop's edge. |
| `blend_factor` | `Bounded Image Blend` | Multiplies the alpha of that ramp. Declared range 0.0-1.0. |

## Rules that follow from the mechanism

- **Read `padding` and `feathering` together, never separately.** The feather ramp eats roughly
  `2 x feathering` px inward from the crop edge, and it cannot feather outside the crop. If the padding
  is smaller than the feathering, the ramp consumes the *entire* padding, so the repaired region is
  composited at partial alpha all the way to its own boundary and never fully takes. A pass whose
  padding is well above its feathering has a fully-applied core and composites cleanly; a pass whose
  padding is at or below its feathering looks soft-edged and half-applied. **Check that ratio before
  touching anything else** -- it is the first thing to suspect when one region repairs well and the
  other does not, and it is invisible if you compare `denoise` alone.
- **`blend_factor` at its maximum is not a lever.** It is an alpha multiplier already pinned at 1.0,
  so the only available direction is *down*, which lets the un-repaired target show through more. Do not
  reach for it to sharpen a composite.
- **The two passes are one process with two instances.** The blend, the mask-grow and the crop each
  exist twice -- same node class, and by inspection the *same values*. Editing "the blend settings"
  therefore means editing two nodes; edit one and you have manufactured a face-versus-hands asymmetry
  that a later session will diagnose as a region-specific defect.
- **A face-pass change is not a one-axis change.** The hand mask is computed on the **output of the
  face composite**, and the hand blend paints onto it. Perturbing the face pass therefore moves the
  hand mask and the hand composite downstream. Treat face-pass and hand-pass edits as two axes and
  never vary both inside one comparison.
- **The hand pass is an arm pass too.** Its inpaint text is `Young female arm and hand`, so its
  scheduler denoise governs the whole region -- strengthening it for hands re-renders the arms.
- **An empty mask is a crash, not a weak render.** The crop step takes the mask bounding box with no
  empty guard, so a region the masker failed to find kills the render outright; see
  `references/render-pipeline-operations.md`.

## Reading the current values out

`scripts/inpaint_knobs.py <workflow.json>` prints the whole surface: every node in the
mask/crop/blend family, what each consumes from, what consumes each, and -- for the duplicated classes
-- how many instances exist and whether their values match. Run it before forming a hypothesis about
which region repairs badly: the asymmetry is a number, not an impression.

## Tuning order

1. Read the ratio of crop `padding` to blend `feathering`, per pass. Fix a mismatch there first -- it is
   the cheapest single lever and the likeliest explanation for "one region repairs and the other does
   not".
2. Only then the mask shape (`expand`, `blur_radius`, or the CLIPSeg `threshold` / `dilate` / `blur`),
   which moves the bounding box and so changes the crop.
3. Only then `denoise`, remembering it applies to the whole region the mask covers (hands *and* arms).
4. Ruled out: `blend_factor` (already maximal).

Change one stage at a time, and remember a face-stage change propagates into the hand stage.
